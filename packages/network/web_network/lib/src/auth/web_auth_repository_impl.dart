import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
// `decodeJsonBody` only — shared rather than copied so dio's 50 KB
// isolate threshold lives in one place (#352 D2).
import 'package:dio_network/dio_network.dart' show decodeJsonBody;
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:observability/observability.dart';
import 'package:http_status/http_status.dart';

/// Web implementation of [AuthRepository].
///
/// Relies entirely on httpOnly session cookies managed by the browser.
/// The client never reads or stores the token — Dio's `withCredentials`
/// flag (configured on the injected [Dio] by `WebDioFactory`) ensures cookies
/// are sent automatically on every cross-origin request.
///
/// Differences from the mobile/desktop [AuthRepositoryImpl]:
/// - No `TokenStorageService` — the browser keychain is the cookie jar
/// - No Authorization header interceptor
/// - [getCachedSession] serves the in-memory session only: httpOnly cookies
///   are opaque to Dart, so there is no *persisted* material to read (#284).
/// - Single server only — no orchestrator or context switching
///
/// The [Dio] instance is built and owned by the per-server `WebDioFactory` and
/// injected here. This repository does not close it: it is a shared per-server
/// resource owned by the container. [onDispose] tears down only the auth-state
/// stream.
class WebAuthRepositoryImpl implements AuthRepository, Disposable {
  WebAuthRepositoryImpl({
    required this._identity,
    required this._dio,
    this._decodeJson = decodeJsonBody,
  }) : _stateController = StreamController<AuthState>.broadcast(sync: true);

  final ServerIdentity _identity;
  final Dio _dio;
  final StreamController<AuthState> _stateController;

  /// The JSON decode behind [_decodeBody]. Always `decodeJsonBody` in
  /// production; injectable for the same reason as the native twin's — the
  /// decode's second failure mode is the one no response body can produce
  /// (#364).
  final Future<Object?> Function(String) _decodeJson;
  final BgeLogger _log = BgeLogger('bge.web.auth.repository');

  AuthState _currentState = const AuthStateUnknown();

  /// Monotonic sign-out counter, mirroring `AuthRepositoryImpl._sessionEpoch`
  /// (#146). Bumped as the first statement of [signOut], before any await;
  /// every method that can be suspended while a session is being decided
  /// captures it in its synchronous prologue and re-compares afterwards.
  ///
  /// Without it, a [getSession] still in flight when the user signs out
  /// resolves afterwards and re-asserts [AuthStateAuthenticated] for a
  /// session whose cookie the server has already revoked — the newer intent
  /// must win.
  ///
  /// Both halves must sit ahead of every suspension point: a capture taken
  /// after an await samples a value the racing sign-out may already have
  /// bumped, which makes the later comparison match and the guard silently
  /// inert.
  ///
  /// Web needs TWO checkpoints in [_getSessionUnlatched], as native does.
  /// #352 moved body decoding below the first guard, and `decodeJsonBody`
  /// suspends, so that window now sits between the guard and the state
  /// emission it protects.
  ///
  /// How wide it is depends on the platform, and the honest answer for THIS
  /// class is: not very. `decodeJsonBody`'s 50 KB isolate offload is a no-op
  /// in a browser — Flutter's web `compute` is `await null; return
  /// callback(message);` (`foundation/_isolates_web.dart`), so the body is
  /// parsed on the main thread either way and the suspension is a single
  /// microtask. A user-initiated sign-out is an event-loop task, and
  /// microtasks drain before the next one, so in a browser this checkpoint is
  /// defence in depth rather than a live race.
  ///
  /// It is kept because it is load-bearing off the browser — this suite runs
  /// on the VM, where the offload is real and the window is milliseconds —
  /// and because the alternative is a guard whose correctness depends on a
  /// platform detail of `compute` that no reader of this class would think to
  /// check.
  ///
  /// ## What the epoch does NOT bound (#285)
  ///
  /// It bounds responses, not requests. A [getSession] **started after** the
  /// bump captures the new epoch, so the re-comparison matches and no guard
  /// fires. That gap is [_pendingSignOuts]'s job, not this counter's.
  int _sessionEpoch = 0;

  /// True from the first statement of [signOut] until its revocation POST
  /// resolves — the window in which a session request must not be made
  /// (#285).
  ///
  /// [_sessionEpoch] cannot cover this. It answers "did this response
  /// outlive its intent?"; the question here is "should this request have
  /// been made at all?", and a call starting inside the window captures the
  /// already-bumped epoch, so the guard is inert for it.
  ///
  /// The window is reachable on web and not on native, for the reason web
  /// has no local credential to clear: the session cookie stays live until
  /// the server's `Set-Cookie: Max-Age=0` comes back, so a [getSession]
  /// inside it gets a **real** session and would re-assert
  /// [AuthStateAuthenticated] behind a gate that has already shown the
  /// sign-in form. Native's `_tokenStorage.clear()` runs first, so
  /// `retrieve()` returns null and its `getSession` early-returns without
  /// asking. Window size is the POST's full duration — up to the 10s
  /// `receiveTimeout` against an unreachable server.
  ///
  /// No dispatcher reached this window when #285 was filed. That was a
  /// property of *other* components rather than of this class, and #144 is
  /// about to remove it: an optimistic offline entry that revalidates is
  /// `unverifiedOffline`, which arms `AuthBloc`'s periodic revalidation
  /// timer — a wall-clock dispatcher needing no user action to land inside
  /// the window. Fixed ahead of that rather than after it.
  ///
  /// ## What #348 changed
  ///
  /// This counter still comes down whenever the POST resolves, on every
  /// outcome. What used to travel with it — the assumption that a resolved
  /// POST means the window is closed — does not hold when the revocation
  /// FAILED: the cookie is then still live, and [signOut] raises
  /// [_unrevokedSignOut] instead, which has its own release condition. The
  /// two are separate state on purpose; the reasoning is on that field.
  ///
  /// A count rather than a flag, because the release condition is "no
  /// revocation is outstanding" and a flag cannot express it: with two
  /// [signOut] calls overlapping, the first to complete would clear a flag
  /// while the second's POST was still in flight, reopening the window this
  /// exists to close. Raised in review on #347.
  ///
  /// Not reachable through today's only caller — `AuthBloc._onSignOut` is a
  /// `droppable()` handler, so a second `AuthSignOutRequested` is dropped
  /// while one is being handled. That is a property of the caller, though,
  /// and this class cannot see it: [signOut] is a public interface method,
  /// and a latch whose correctness rests on "no caller happens to overlap"
  /// is the same shape of latent bug this field was added to fix.
  int _pendingSignOuts = 0;

  /// True when a sign-out's revocation was **not observed to succeed**, so
  /// the browser is still holding a cookie the server never invalidated
  /// (#348).
  ///
  /// Separate state from [_pendingSignOuts], and deliberately NOT that
  /// counter held up. The two answer different questions and are released by
  /// different things: the counter means "a revocation is in flight" and
  /// comes down when the POST resolves; this means "a revocation resolved
  /// badly and the cookie outlived it" and comes down only when a credential
  /// grant issues a new one. Keeping the counter raised instead would break
  /// the arithmetic it exists for — an overlapping [signOut]'s decrement
  /// would take down a latch this one meant to keep up — and would leave the
  /// class unable to say which of the two situations it is in.
  ///
  /// Released in [_reconcileCredentialGrant]: the server has just issued a
  /// fresh session cookie, which replaces the stale one by NAME, so nothing
  /// addressable by this client is left to adopt. That is the same reason a
  /// grant landing INSIDE the sign-out window means this is never set at all
  /// — see [signOut].
  ///
  /// What it does not do is get the old session **revoked**. That session
  /// stays valid server-side until it expires; #390 is the bounded retry
  /// that would end it, and this latch explicitly does not answer that
  /// half.
  ///
  /// ## What counts as a replacement, and why a 2xx does not
  ///
  /// An httpOnly cookie is invisible to Dart, so "a credential grant issued
  /// a new cookie" cannot be read directly — and a **2xx on the credential
  /// POST** is not a stand-in for it. `_assertSuccess` rejects only 401,
  /// 403, a duplicate-email envelope and non-2xx, so a 2xx that sets NO
  /// session cookie (BetterAuth sign-up with verification required, or
  /// `autoSignIn` off) once released this latch without replacing anything.
  /// The reconcile that followed read the STALE cookie and adopted the
  /// previous user's session — on a shared browser, a different person's.
  ///
  /// What this class CAN prove is whether the grant came back carrying a
  /// session, and that is the gate: [_reconcileCredentialGrant] releases the
  /// latch only for a grant that did, and refuses the unlatched read
  /// entirely for a grant that did not, because it cannot tell the stale
  /// cookie from one it set. Raised in review on the #348 PR as an adoption
  /// rule rather than a latch rule, which it still is — the two are gated
  /// together because either one alone leaves the other reachable.
  bool _unrevokedSignOut = false;

  /// Monotonic count of credential POSTs the server ACCEPTED (#348).
  ///
  /// Bumped in [_reconcileCredentialGrant] for a grant that came back
  /// CARRYING a session — the moment the server issued a fresh cookie and
  /// the browser overwrote the old one by name. A 2xx that carries no
  /// session proves no such thing and is not counted (see
  /// [_unrevokedSignOut]).
  ///
  /// [signOut] compares it rather than reading [_currentState], and the
  /// difference is a full session round trip wide. The cookie is replaced
  /// when the credential POST resolves; `AuthStateAuthenticated` is not
  /// emitted until the reconcile's GET comes back. A sign-out resolving
  /// inside that gap sees a state still reading unauthenticated, and would
  /// latch [_unrevokedSignOut] over the session the user just created — with
  /// no release path left, because the release already ran before the await.
  int _credentialGrants = 0;

  /// Monotonic count of revocations that COMPLETED successfully (#346).
  ///
  /// Distinct from [_sessionEpoch], which counts sign-outs as they START.
  /// The question here is the other one: has a `Set-Cookie: Max-Age=0`
  /// actually come back and deleted the cookie by name? Only a 2xx says so.
  ///
  /// [_reconcileCredentialGrant] captures it and re-compares after its
  /// session read, because a revocation completing in that window deletes
  /// the very cookie the grant just received — the #346 failure, one round
  /// trip earlier than the one [signOut] can see for itself.
  int _revocationEpoch = 0;

  @override
  AuthState get currentAuthState => _currentState;

  @override
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    final strategy = _requireEmailPasswordStrategy();

    late final Response<String> response;
    try {
      response = await _dio.post<String>(
        strategy.signInEndpoint,
        data: {'email': email, 'password': password},
        options: _plainBody,
      );
    } on DioException catch (e) {
      throw _mapDioException(e, credentialGrant: true);
    }

    final body = await _requireGrantBody(response, context: 'sign-in');

    // BetterAuth set the session cookie in this response and the browser
    // stored it automatically. The reconcile that follows is for the full
    // user object and the canonical expiry — not for the credential.
    return _reconcileCredentialGrant(
      _readGrant(body, status: response.statusCode, context: 'sign-in'),
      context: 'sign-in',
    );
  }

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String username,
    String? firstName,
    String? lastName,
  }) async {
    final strategy = _requireEmailPasswordStrategy();

    if (strategy.signUpDisabled || strategy.signUpEndpoint == null) {
      throw const AuthRegistrationDisabledException();
    }

    late final Response<String> response;
    try {
      response = await _dio.post<String>(
        strategy.signUpEndpoint!,
        data: {
          'email': email,
          'password': password,
          // BetterAuth's email-register validator requires `name`. The
          // server maps name → username at the model layer, but that
          // mapping does not rewrite the inbound validator, so the wire
          // key must be `name`. This is purely the HTTP boundary — the
          // field is "username" everywhere user-facing (UI label, form,
          // AuthRegisterRequested.username).
          'name': username,
          'firstName': ?firstName,
          'lastName': ?lastName,
        },
        options: _plainBody,
      );
    } on DioException catch (e) {
      throw _mapDioException(e, credentialGrant: true);
    }

    final body = await _requireGrantBody(response, context: 'sign-up');

    return _reconcileCredentialGrant(
      _readGrant(body, status: response.statusCode, context: 'sign-up'),
      context: 'sign-up',
    );
  }

  @override
  Future<AuthResponse?> getSession() async {
    // Refuse rather than ask (#285). A sign-out is outstanding, so the
    // user's intent is already "no session" — and the cookie backing this
    // request is one the server is in the middle of revoking, so a success
    // here would re-assert authenticated behind a gate that has already
    // shown the sign-in form. Null is the honest answer and the one the
    // epoch guard gives for the same situation one step later.
    //
    // Ahead of the epoch capture because it is a statement about the
    // request, not the response: there is nothing to compare afterwards.
    //
    // On the PUBLIC entry point only. `_reconcileCredentialGrant` calls
    // [_getSessionUnlatched] instead: its session read serves a credential
    // grant the server has just accepted, which is the user's *newer*
    // intent than the sign-out and must be allowed to win. Refusing it
    // turned a successful sign-in inside the window into an
    // `AuthServerException` — the reconcile's `confirmed == null` branch
    // reads a latched null as "the server reported no session", and its
    // epoch was captured after the bump so the supersession branch does not
    // fire. Ordering between a sign-out and a sign-in is #146's job, via
    // the epoch and `AuthSupersededException`; this latch is only about not
    // *asking* on behalf of a caller polling for a session.
    if (_pendingSignOuts > 0) {
      _log.warn('Refusing a session request while a sign-out is in flight');
      return null;
    }

    // #348. The revocation resolved, badly: the cookie this request would
    // carry is one the server never invalidated and the user has already
    // ended. Same answer as above, for a window that does not close on its
    // own — see [_unrevokedSignOut] for what does close it.
    if (_unrevokedSignOut) {
      _log.warn(
        'Refusing a session request: the last sign-out was not accepted, so '
        'the session cookie was never revoked',
      );
      return null;
    }

    return _getSessionUnlatched();
  }

  /// [getSession] without the #285 sign-out latch.
  ///
  /// Only for `_reconcileCredentialGrant` and [_settleAfterLateRevocation] —
  /// see the latch's rationale in [getSession]. The [_sessionEpoch] guards
  /// below still apply, so a sign-out that lands *during* this read is still
  /// honoured.
  ///
  /// [grantsAtEntry] adds the other half of that rule, for callers whose read
  /// a credential grant can outrun. [_sessionEpoch] counts sign-outs, so it
  /// cannot see a grant at all — and this method EMITS state. A settle read
  /// describing the cookie a revocation deleted would otherwise overwrite the
  /// authenticated state a newer grant has already reached, which is #346's
  /// own failure turned around: the sign-out clobbering the sign-in instead.
  /// `_reconcileCredentialGrant` passes nothing, deliberately — it bumps
  /// [_credentialGrants] itself before reading, and would trip its own guard.
  Future<AuthResponse?> _getSessionUnlatched({int? grantsAtEntry}) async {
    // Captured in the synchronous prologue, before ANY await — see
    // [_sessionEpoch].
    final epoch = _sessionEpoch;

    // Whether something newer than this read has happened since it began.
    // Evaluated ahead of every state emission below and never after one, so
    // the three checkpoints stay the only places this question is asked.
    bool superseded() =>
        epoch != _sessionEpoch ||
        (grantsAtEntry != null && _credentialGrants != grantsAtEntry);

    late final Response<String> response;
    try {
      response = await _dio.get<String>(
        _identity.sessionEndpoint,
        options: _plainBody,
      );
    } on DioException catch (e) {
      // A rejected session (401, 403) normally arrives as a Response, not a
      // thrown DioException — `WebDioFactory` sets validateStatus:(_)=>true,
      // so any HTTP status resolves and is classified on the response path
      // below. Reaching here therefore usually means a transport-level
      // failure (no connection, timeout, CORS), which is INDETERMINATE.
      //
      // Usually, not always: this repository takes ANY injected [Dio] and
      // `WebDioFactory` honours caller-supplied interceptors, so a rejection
      // can still surface thrown — from an interceptor, or a Dio whose
      // validateStatus is not the factory's. When it does it is the same
      // DEFINITIVE negative the response path settles, and it has to settle
      // the same way. Throwing it instead (as this did before) left
      // `_currentState` at [AuthStateUnknown] while `AuthBloc` had already
      // routed to the sign-in form, so `watchAuthState` went on replaying
      // "unknown" to every later subscriber — and, reaching
      // [_reconcileCredentialGrant] as an exception, it was bucketed as
      // indeterminate and kept a session the server had just disowned.
      //
      // A second, narrower door to the same catch: before this request
      // pinned `responseType` (see `_plainBody`, #360), an injected [Dio]
      // already set to `bytes` or `stream` let Dio's own cast throw here
      // instead of ever resolving a Response — the #352 mechanism, closed by
      // the pin rather than by asking for `Response<String>` alone.
      final mapped = _mapDioException(e, credentialGrant: false);

      if (superseded()) {
        _log.warn(
          'Discarding a failed session request that was superseded while in '
          'flight',
          error: e,
        );
        return null;
      }

      if (mapped is AuthInvalidCredentialsException) {
        _setState(const AuthStateUnauthenticated());
        return null;
      }

      throw mapped;
    }

    // The user signed out — or signed back in — while this request was in
    // flight. Either way, what happened since is newer than this response:
    // discard it without touching state, so sign-out stays final (see
    // [_sessionEpoch]) and a newer grant is not clobbered (see
    // [grantsAtEntry]).
    if (superseded()) {
      _log.warn(
        'Discarding a session response that was superseded while in flight',
        context: {'status': response.statusCode},
      );
      return null;
    }

    final status = response.statusCode;

    // Three shapes of "definitively no session": an explicit 401, a 403, and
    // BetterAuth's 200-with-null-body — which is how it reports an absent or
    // expired session rather than using a status code. All three mean the
    // browser's cookie is dead: settle on unauthenticated.
    //
    // 403 belongs here, not in the indeterminate bucket below. Because
    // validateStatus is permissive it resolves as a Response and never
    // reaches `_mapDioException` — the path that maps 403 to
    // `AuthInvalidCredentialsException`. Classifying it as indeterminate
    // stranded a genuinely revoked session on the retry-forever view with no
    // way out. A false positive from an intermediary costs one re-sign-in,
    // which is the cheaper failure. Native locked the same call (#180).
    // Two of the three are decidable from the status alone and are taken
    // here. The third needs the body and waits until after the decode below —
    // a reordering #352 forced, not a change of rule: the body no longer
    // arrives pre-decoded, and reading "no session" off an undecoded string
    // would call a captive portal's HTML page a rejected session.
    if (status == HttpStatusCode.unauthorized ||
        status == HttpStatusCode.forbidden) {
      _setState(const AuthStateUnauthenticated());
      return null;
    }

    // Anything else is INDETERMINATE and must throw, not return null (#98).
    // This check MUST come after the definitive cases and before any body
    // inspection: an earlier `response.data == null` test that ignored the
    // status turned a bodiless 502 — a proxy fault — into a definitive "no
    // session", signing the user out for a server hiccup and implying their
    // session had been rejected (#180). A 2xx that is not the documented 200
    // shape lands here too: it carries no session and no rejection.
    if (status != HttpStatusCode.ok) {
      throw AuthServerException(
        message: 'Unexpected $status from the session endpoint.',
        statusCode: status,
      );
    }

    final decoded = await _decodeBody(
      response.data,
      context: 'the session check',
      status: status,
    );

    // A 2xx the transport answered but this client cannot read. Definitive
    // when the body is not JSON, INDETERMINATE when the decode itself could
    // not be performed — and only the first is a statement about the server
    // (#352).
    // Second checkpoint. The decode above is a suspension point, so a
    // sign-out can land between the guard at the top of this method and the
    // state emission below — and that emission would re-assert a session the
    // user has already ended, which is the whole failure #146 exists to
    // prevent. Ahead of the throw as well as the emission: a superseded
    // response is discarded, not reported.
    if (superseded()) {
      _log.warn(
        'Discarding a session response decoded after it was superseded',
        context: {'status': status},
      );
      return null;
    }

    final failure = decoded.failure;
    if (failure != null) throw failure;

    // The third "definitively no session" shape, now that the body is
    // readable: BetterAuth answers 200 with no session payload. An empty body
    // and a literal JSON `null` both land here as null, which is exactly what
    // `Response<Map<String, dynamic>>` used to hand over as `data == null`.
    final body = decoded.value;
    if (body == null) {
      _setState(const AuthStateUnauthenticated());
      return null;
    }

    // A 200 whose body is not the documented shape is a server fault, and it
    // has to leave here as one: `AuthRepository` admits only AuthException
    // subtypes out of getSession, and AuthBloc's sign-in / register handlers
    // catch nothing wider — a bare parse error would slip past every clause
    // and strand the form on AuthLoading with no way back. Native upholds the
    // same rule now (#181).
    if (body is! Map<String, dynamic>) {
      throw AuthServerException(
        message:
            'The session endpoint returned a body that is not a JSON object.',
        statusCode: status,
      );
    }

    final BgeSessionResponse sessionResponse;
    try {
      sessionResponse = BgeSessionResponse.fromJson(body);
    } on Object catch (error) {
      throw AuthServerException(
        message: 'The session endpoint returned an unreadable response.',
        statusCode: status,
        cause: error,
      );
    }
    final auth = AuthResponse(
      // Dropped, deliberately (#291). `sessionResponse.session.token` IS
      // the real bearer credential — the same opaque string BetterAuth
      // issues to native — and web authenticates with the browser's
      // httpOnly cookie instead, so nothing here ever reads it. Carrying
      // it for shape parity put a live credential in the long-lived
      // authenticated state below, which is what a log line, a breadcrumb
      // or a feedback report could then take off the device. That partly
      // undid the point of the cookie being httpOnly at all.
      //
      // Note the bound this does NOT reach: the token still arrives in the
      // response body and is parsed into `sessionResponse` above. What is
      // removed is its RETENTION, not its presence in memory — the server
      // would have to stop vending it to cookie clients for that
      // (backend#407).
      token: null,
      user: sessionResponse.user,
      expiresAt: sessionResponse.session.expiresAt,
    );

    _setState(AuthStateAuthenticated(session: auth));
    return auth;
  }

  /// Signs out, **awaiting** the server POST — deliberately unlike native's
  /// fire-and-forget (`AuthRepositoryImpl.signOut`, #37 review #9).
  ///
  /// The native decision rests on a step web does not have. There, the POST
  /// is genuinely best-effort because `TokenStorageService.clear()` destroys
  /// the credential locally: sign-out is final the moment that returns,
  /// whatever the network does. Web holds no session material of its own —
  /// the httpOnly cookie is the session, Dart cannot touch it, and the
  /// server's `Set-Cookie: Max-Age=0` on THIS response is the only thing
  /// that ends it. Returning before it lands leaves the cookie live: a page
  /// reload in that window sends it again, the session endpoint honours it,
  /// and the user is silently signed back in. In-memory state is not a
  /// teardown when the credential outlives the process.
  ///
  /// Awaiting costs the user nothing. The local transition to
  /// [AuthStateUnauthenticated] happens synchronously below, before the POST
  /// is even sent, so `AuthBloc`'s mirror subscription flips the gate at
  /// once — the await governs when this future resolves, not when the app
  /// stops presenting a signed-in session. That is what makes awaiting cheap
  /// here where native judged it too expensive (#37 review #9): what native
  /// rejected was a spinner, and there is no spinner left to pay for.
  ///
  /// Residual risk, unavoidable on either posture: if the POST never lands
  /// the cookie is never cleared, and the session survives until it expires
  /// server-side. Awaiting cannot fix that — but it does mean the failure is
  /// observed, and #348 is what makes it *acted on*: a revocation that was
  /// not seen to succeed raises [_unrevokedSignOut], so no later session read
  /// in this process is handed the cookie it left behind. Ending that session
  /// server-side needs a retry, which is #390.
  ///
  /// ## What this does when the POST resolves (#348, #346)
  ///
  /// One rule, three outcomes — and the first two are the same `await`
  /// resolving in the two ways it can, which is why #348 and #346 are one
  /// change:
  ///
  /// - **Succeeded, and the state is no longer unauthenticated.** A sign-in
  ///   landed inside the window, and this response's
  ///   `Set-Cookie: Max-Age=0` deletes by NAME — so it just deleted that
  ///   sign-in's cookie. Re-validate (#346).
  /// - **Not observed to succeed.** The cookie is live: hold the latch,
  ///   unless a grant already replaced it.
  /// - **Otherwise.** Release, which is the ordinary path.
  @override
  Future<void> signOut() async {
    // Both statements run before any await, and both make the user's intent
    // locally true at once. The epoch invalidates a session response still
    // in flight (see [_sessionEpoch]); the transition means nothing
    // observing this repository waits on the network to learn the session is
    // over. Leaving the transition in a `finally` after the awaited POST
    // held `currentAuthState` at authenticated for the full 10s
    // receiveTimeout against an unreachable server, with the caller — and
    // the gate — sitting on AuthLoading for all of it.
    _sessionEpoch += 1;
    _pendingSignOuts += 1;
    _setState(const AuthStateUnauthenticated());

    // Captured before any await, like the epoch above. A grant is "inside
    // this window" when the server accepted its credentials after this
    // point — see [_credentialGrants] for why the state cannot answer that.
    final grantsAtStart = _credentialGrants;

    // Whether the server is known to have cleared the cookie. Only a 2xx
    // says so: it is the response that carries `Set-Cookie: Max-Age=0`.
    var revoked = false;

    try {
      // `String` plus the pin, for the same reason as every other request
      // here — see `_plainBody`. Without it a revocation answered with an
      // HTML error page throws from inside the call and is logged as a
      // transport fault rather than the non-2xx it is.
      final response = await _dio.post<String>(
        _identity.signOutEndpoint,
        options: _plainBody,
      );

      final status = response.statusCode;
      if (_isSuccessStatus(status)) {
        revoked = true;
        // This response carried `Set-Cookie: Max-Age=0`. Anything holding a
        // cookie of that name has just lost it — see [_revocationEpoch].
        _revocationEpoch += 1;
      } else {
        // `validateStatus: (_) => true` (`WebDioFactory`) resolves a 5xx as
        // an ordinary Response, so the catch below only ever sees transport
        // faults. Without this branch the failure that actually matters —
        // the server declining to revoke, hence no `Set-Cookie: Max-Age=0`
        // — is the one failure logged nowhere, and the doc's promise that
        // awaiting makes it observable would hold for nothing.
        _log.warn(
          'Sign-out was not accepted; the session cookie is still live '
          'until it expires server-side',
          context: {'status': status},
        );
      }
    } on Object catch (error, stackTrace) {
      // Best-effort in the sense that it cannot fail the sign-out — the
      // user's intent stands either way. It is not best-effort in the sense
      // of being skippable; see the doc above.
      _log.warn(
        'Sign-out POST did not complete; the session cookie is still live '
        'until it expires server-side',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      // A grant that landed inside the window has already replaced the
      // cookie — same name, so the browser overwrote it — which means a
      // failed revocation left nothing THIS client can still address, and
      // raising the latch would refuse session reads for a session the user
      // just created. The old session does survive server-side either way;
      // ending it is #390's job, not a latch's.
      final supersededByGrant = _credentialGrants != grantsAtStart;
      if (!revoked && !supersededByGrant) {
        // #348. Held here rather than released with the counter below,
        // because the cookie is still live and no later `getSession` in this
        // process should be handed it. Released by a credential grant, not
        // by time — see [_unrevokedSignOut].
        _unrevokedSignOut = true;
      }

      // The COUNTER always comes down: a thrown POST must not leave it
      // raised for the life of the process, which would turn a transient
      // network fault into "this client can never read a session again"
      // (#285). What #348 changed is that the failure case now leaves
      // [_unrevokedSignOut] up instead, which has its own exit. Decrement
      // rather than reset, so an overlapping sign-out's own protection
      // survives this one completing.
      _pendingSignOuts -= 1;
    }

    // #346. The revocation succeeded, late, and its
    // `Set-Cookie: Max-Age=0` deletes by cookie NAME — so if a sign-in
    // landed inside the window, what this response just deleted is the
    // cookie that sign-in received. In-memory state would otherwise keep
    // asserting a session over a cookie that no longer exists, and the next
    // request 401s.
    //
    // Only reachable when a grant moved the state: on the ordinary path the
    // state is still unauthenticated and there is nothing to settle.
    if (revoked && _credentialGrants != grantsAtStart) {
      await _settleAfterLateRevocation(_credentialGrants);
    }
  }

  /// Re-reads the session after a late revocation may have deleted a cookie
  /// a sign-in issued inside the sign-out window (#346).
  ///
  /// [_getSessionUnlatched] rather than [getSession] for the same reason
  /// `_reconcileCredentialGrant` uses it: the latch is about not *asking* on
  /// behalf of a caller polling for a session, and this is the class settling
  /// its own state against a change it caused. Its [_sessionEpoch] guards
  /// still apply, so a newer sign-out landing during this read wins.
  ///
  /// [grantsAtSettle] is why this read passes a grant checkpoint and the
  /// reconcile does not. This one is issued AFTER the revocation completed,
  /// so a credential POST starting now gets a cookie the revocation cannot
  /// delete — and this read, sent before that cookie existed, comes back
  /// describing no session. Emitting that would sign the user out of the
  /// session they just created, one round trip after the fact.
  ///
  /// Never throws, and the catch is `Object` rather than [AuthException] for
  /// that reason alone. [signOut] is contractually best-effort — it cannot
  /// fail on the network, and a test pins that — so a settle-up added AFTER
  /// the revocation already succeeded must not become the first thing able
  /// to throw out of it. The sign-out is done by the time this runs; the
  /// user's intent is served whatever this returns.
  Future<void> _settleAfterLateRevocation(int grantsAtSettle) async {
    try {
      await _getSessionUnlatched(grantsAtEntry: grantsAtSettle);
    } on Object catch (error, stackTrace) {
      _log.warn(
        'Could not settle the session after a late sign-out revocation; the '
        'in-memory state may name a session whose cookie it deleted',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// The in-memory session if there is one, otherwise `null` — never a
  /// network call (#284).
  ///
  /// This used to delegate to [getSession], which broke both halves of the
  /// contract's "pure read, no network call" clause: [getSession] takes a
  /// round trip and calls `_setState` on every outcome, so the documented
  /// pure read emitted on [watchAuthState] and could adopt a session before
  /// the caller had decided anything. It also cost a second full round trip
  /// on every cold-start session check, because `AuthBloc` calls this first
  /// as a cheap local *probe* — only to decide whether a restore budget
  /// applies — and then makes the real call. Paying a network request to
  /// decide whether to bound a network request is self-defeating.
  ///
  /// What remains is the contract's own in-memory clause: *"an in-memory
  /// authenticated session takes precedence and is returned as-is, so a
  /// signed-in caller is never told 'not authenticated' merely because the
  /// persisted expiry was never confirmed."* `AuthRepositoryImpl` has always
  /// implemented that; web's delegation obscured it. So this is the same
  /// rule, with web's persisted half simply empty.
  ///
  /// Empty is permanent for now, and that is the platform, not a gap:
  /// httpOnly cookies are opaque to Dart, so there is no *persisted* session
  /// material to read without asking the server. At cold start — before any
  /// [getSession] — this therefore returns null, which is the honest answer
  /// and the same one [restoreCachedSession] gives. The probe reads that as
  /// "no budget applies" and waits out the full attempt, which is the
  /// documented cost.
  ///
  /// If #144 lands a readable, non-httpOnly expiry-hint cookie, web gains a
  /// persisted signal too — though the better shape then is a narrowed
  /// interface method asking what the probe actually wants ("is a bounded
  /// check worthwhile?") rather than asking for a session.
  @override
  Future<AuthResponse?> getCachedSession() async => switch (_currentState) {
    AuthStateAuthenticated(:final session) => session,
    _ => null,
  };

  /// Always null: web never restores optimistically (#98, decision D10).
  ///
  /// Not a stub awaiting an implementation — a statement about what the
  /// platform can know. Optimistic restore requires inspecting the session
  /// material offline to check it has a server-confirmed expiry that has
  /// not passed. The browser's httpOnly cookie is unreadable from Dart, so
  /// there is nothing to inspect: the only alternative would be trusting a
  /// separately persisted expiry as a proxy for a credential we cannot
  /// confirm still exists, which would let a cleared cookie present as a
  /// live session.
  ///
  /// The degenerate nature of the case makes this cheap to accept: web is
  /// same-origin with its BGE server, so a server unreachable enough to
  /// need offline restore is usually one that could not have served the app
  /// either. Web therefore keeps #37's retryable "can't reach the server"
  /// view at cold start. Revisiting this needs a readable non-httpOnly
  /// expiry hint from the server — tracked separately.
  @override
  Future<AuthResponse?> restoreCachedSession() async => null;

  @override
  Stream<AuthState> watchAuthState() {
    return Stream.multi((controller) {
      controller.add(_currentState);
      final sub = _stateController.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = sub.cancel;
    });
  }

  void _setState(AuthState next) {
    _currentState = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  /// Parses the grant envelope BetterAuth returns from sign-in / sign-up, or
  /// null when it cannot be read.
  ///
  /// The returned response never carries a token (#291). The browser holds
  /// the httpOnly cookie that actually authorises requests, so the
  /// credential in this envelope is one web has no use for. What the
  /// envelope is wanted for is the **user identity**: an authenticated state
  /// without a real `user.id` cannot activate the per-(server, user) scope
  /// (#135).
  ///
  /// Nullable on purpose, and this is where web has to diverge from native.
  /// Native needs the token — it persists it and every later request carries
  /// it — so an unreadable grant is genuinely fatal there. Here the grant is
  /// only ever a FALLBACK for an indeterminate reconcile: on the happy path
  /// [_reconcileCredentialGrant] adopts the confirmed session and discards
  /// this one untouched. Failing here would therefore reject sign-ins the
  /// session endpoint was about to confirm. Whether the sign-in stands is
  /// the reconcile's call, and the reconcile is the authority regardless.
  ///
  /// Nothing is adoptable for three shapes: no body, a body that will not
  /// parse, and BetterAuth's documented `token: null` envelope — a server
  /// that granted no session, which is not something to adopt on a reconcile
  /// that cannot reach the server to disagree.
  ///
  /// The third is a [_DeclinedGrant] and the other two an [_UnreadableGrant],
  /// because they mean different things. The envelope is the server's own
  /// statement that it declined to grant a session; a missing or unreadable
  /// body says nothing about why, so where no session follows it stays a
  /// server fault (#331).
  _Grant _readGrant(
    Map<String, dynamic>? data, {
    required int? status,
    required String context,
  }) {
    // Not logged here: [_requireGrantBody] is the only source of a null on
    // this path and has already said why, with more detail than this branch
    // could. A second record would double-count one event.
    if (data == null) return const _UnreadableGrant();

    final AuthResponse granted;
    try {
      granted = AuthResponse.fromJson(data);
    } on Object catch (error, stackTrace) {
      // Native reaches straight for `response.data!` and lets a malformed
      // body escape as a raw parse error, which slips past every
      // `on AuthException` clause in AuthBloc and strands the form on
      // AuthLoading. Nothing raw leaves here.
      _log.warn(
        'Unreadable $context envelope; the session endpoint has to confirm '
        'this $context unaided',
        error: error,
        stackTrace: stackTrace,
        context: {'status': status},
      );
      return const _UnreadableGrant();
    }

    // BetterAuth's documented no-session envelope: `token: null`, returned
    // when email verification is required or `autoSignIn` is off. The
    // server accepted the credentials and deliberately granted no session,
    // so there is nothing here to adopt — decline it and let the reconcile
    // be the authority.
    //
    // Checked explicitly, and it has to be. This used to hold by accident:
    // `AuthResponse.token` was `required String`, so the envelope failed
    // inside `fromJson` and fell into the catch above. #291 made the field
    // nullable — the parse now SUCCEEDS, and without this check the
    // envelope would become an adoptable grant, signing in a user the
    // server had just declined to grant a session to on any reconcile that
    // could not reach the server to say otherwise.
    //
    // Checked AFTER the parse, not before it. A guard reading
    // `data['token']` directly cannot tell "the server granted no session"
    // from "this body is broken and happens to have no token key" — it
    // would file the second as the first and discard the parse error and
    // its stack trace, which is the only diagnostic either branch has.
    //
    // Forward hazard, tracked on backend#407: if the server stops vending
    // `token` to cookie clients, an absent token stops meaning "no session
    // granted" and this branch would decline every successful web sign-in
    // — losing the fallback that keeps a sign-in alive through an
    // indeterminate reconcile. The pre-emptive client release named there
    // has to give this check a different discriminator, not just make
    // `BgeSession.token` nullable.
    if (granted.token == null) {
      _log.warn(
        'No session granted on a successful $context; the session endpoint '
        'has to confirm this $context unaided',
        context: {'status': status},
      );
      return const _DeclinedGrant();
    }

    // The token in this envelope is the same live credential the session
    // endpoint vends, and web has no use for it either (#291) — keep the
    // user identity, which is the only part that makes a granted session
    // adoptable, and leave the credential behind.
    return _AdoptableGrant(
      AuthResponse(
        token: null,
        user: granted.user,
        expiresAt: granted.expiresAt,
      ),
    );
  }

  /// The failure for a 2xx credential grant that ends with no session: the
  /// server's own answer when it declined to grant one, and a server fault
  /// otherwise (#331).
  static AuthException _noSessionAfter(String context, _Grant grant) =>
      switch (grant) {
        _DeclinedGrant() => AuthSessionNotGrantedException(
          message: 'The server accepted the $context but granted no session.',
        ),
        _AdoptableGrant() || _UnreadableGrant() => AuthServerException(
          message:
              'Authentication succeeded but the server reported no session '
              'during $context.',
        ),
      };

  /// Reconciles a freshly granted credential against the session endpoint.
  ///
  /// Native parity with `AuthRepositoryImpl._finalizeCredentialGrant`, minus
  /// its persistence half — web stores nothing, so there is no write to undo
  /// and no second epoch checkpoint.
  ///
  /// Three outcomes, and the distinction matters:
  ///
  /// - reconcile succeeds → adopt the confirmed session, which carries the
  ///   server's canonical expiry;
  /// - reconcile is **INDETERMINATE** (transport failure, 5xx) → keep the
  ///   granted session, or rethrow if the grant carried none.
  ///   Authentication genuinely happened and the browser already
  ///   holds the cookie proving it; failing here would report
  ///   "connection failed" for a sign-in that worked. The cost is an
  ///   unconfirmed expiry, which on web forfeits nothing — web never
  ///   restores optimistically ([restoreCachedSession] is unconditionally
  ///   null, #98 D10), so there is no offline path that needed it;
  /// - reconcile returns a **DEFINITIVE** "no session" → the server accepted
  ///   the credential and then disowned the session. That is a server
  ///   contract violation, not a network condition, and it must not be
  ///   reported as success — unless the grant itself had declined a session,
  ///   in which case the reconcile only confirmed what the server said.
  Future<AuthResponse> _reconcileCredentialGrant(
    _Grant grant, {
    required String context,
  }) async {
    final granted = switch (grant) {
      _AdoptableGrant(:final session) => session,
      _DeclinedGrant() || _UnreadableGrant() => null,
    };

    // #348's release condition. Reaching here means the credential POST
    // returned a 2xx — `_requireGrantBody` never returns for anything else —
    // so the server has issued a fresh session cookie and the browser has
    // overwritten the stale one by name. A latch raised over a cookie that
    // is no longer in the jar would refuse session reads for the session the
    // user just created.
    //
    // The single funnel point: both `signIn` and `signUp` arrive here, and
    // neither can reach it without a grant the server accepted.
    // Gated on the grant actually CARRYING a session, because a 2xx alone
    // does not prove a replacement cookie. BetterAuth answers a
    // verification-required sign-up with 200, a null token and no
    // `Set-Cookie`, and an unreadable body says nothing either way. Counting
    // those as grants released the latch over the cookie a failed revocation
    // left live — and on a shared browser that cookie is the previous user's
    // session, handed to whoever signed up next.
    final replacedCookie = granted != null;
    if (replacedCookie) {
      _unrevokedSignOut = false;
      _credentialGrants += 1;
    }

    // #346's checkpoint, and a different question from [_sessionEpoch]
    // below: not "did a sign-out START after this?" but "did a revocation
    // COMPLETE while this reconcile was in flight?". If one did, its
    // `Set-Cookie: Max-Age=0` deleted the cookie this grant received —
    // deletion is by NAME — so the session read below describes a session
    // the browser can no longer authenticate.
    final revocationEpoch = _revocationEpoch;

    // Captured before the reconcile await, mirroring native's capture in
    // `_finalizeCredentialGrant`. Like native, it does not cover the
    // credential POST that preceded it — a deliberate bound, not an
    // oversight: every dispatcher of `AuthSignOutRequested` is either
    // unreachable while that POST is in flight or causally downstream of
    // it. The two UI dispatchers are home-menu entries
    // (`home_placeholder_screen.dart:93`, `bge_app.dart:552`), reachable
    // only from an authenticated shell — and `AuthBloc._onSignIn` holds the
    // form on `AuthLoading` for the whole call, including the body decode
    // #352 added. The one programmatic dispatcher
    // (`bge_app.dart:1561`) fires when `UserSessionScope.activate` fails,
    // which cannot run until this reconcile has already emitted. (Web has
    // registered a `UserSessionScope` since #137; the bound above is what
    // holds, not its absence.)
    //
    // Widening the capture would therefore guard a race no caller can
    // produce, and it would guard it incompletely: the late credential
    // response sets a fresh cookie that Dart cannot clear, so honouring a
    // supersession there needs a second revocation POST, not an earlier
    // capture. Revisit if any screen ever offers sign-out over
    // `AuthLoading` — that, not this line, is what holds the bound.
    final epoch = _sessionEpoch;

    // Nothing proved a replacement cookie AND a revocation was left
    // unobserved, so the jar may still hold the session the user ended. The
    // read below is deliberately unlatched, and it cannot tell that cookie
    // from one this grant set — so here it must not run at all. Adopting its
    // answer would hand this caller the PREVIOUS session (#348, the adoption
    // half rather than the latch half).
    //
    // Only this combination is refused. A no-session grant with no latch
    // raised still reads, and still ends at the `confirmed == null` throw
    // below, so nothing changes for an ordinary verification-required
    // sign-up. With no read to run, the envelope is the only answer there
    // is, so a grant the server declined surfaces as not granted — the same
    // answer native gives from the envelope alone (#331).
    if (!replacedCookie && _unrevokedSignOut) {
      _log.warn(
        'A 2xx $context carried no session while a revocation was left '
        'unobserved; refusing to reconcile against a cookie it did not '
        'replace',
      );
      throw _noSessionAfter(context, grant);
    }

    final AuthResponse? confirmed;
    try {
      confirmed = await _getSessionUnlatched();
    } on AuthException catch (error, stackTrace) {
      if (epoch != _sessionEpoch || _revocationEpoch != revocationEpoch) {
        // The reconcile failed AND the sign-out won meanwhile: do not adopt
        // the granted session over the sign-out's teardown. Either half is
        // enough, and they cover different sign-outs — one that STARTED
        // after the capture above, or one already in flight when this grant
        // landed, whose revocation COMPLETED during the read.
        //
        // The second is the half [_sessionEpoch] structurally cannot see
        // here: that sign-out bumped it before this reconcile captured it,
        // so the capture reads equal for the whole window. It is also the
        // more damaging of the two, because keeping `granted` below would
        // assert an authenticated session over a cookie the revocation's
        // `Set-Cookie` has already deleted by name — #346 reached through
        // the indeterminate exit instead of the confirmed one.
        throw const AuthSupersededException();
      }

      // The catch is deliberately broad and is NOT missing a classification
      // branch. Every definitive negative returns null rather than throwing
      // — #180 D11 fixed that at the source in `_getSessionUnlatched` and
      // explicitly rejected adding a rethrow here — so anything arriving as
      // an exception is indeterminate by construction. That includes a 2xx
      // whose body cannot be read: "the response is definitively broken" is
      // not "the session is definitively absent", and only the second would
      // license failing a sign-in the server just accepted. #180 D9/D10 and
      // the test named for it in `web_auth_repository_impl_test.dart` pin
      // that outcome. The native twin's `_finalizeCredentialGrant` carries
      // the full reasoning and the conditions that would change it.
      //
      // Indeterminate reconcile and no adoptable grant ([_readGrant]):
      // nothing adoptable exists on either side. Surface the reconcile's own
      // failure rather than dressing it up as a server fault — it is what
      // actually went wrong, and its retryable copy is the honest thing to
      // show for a sign-in whose credentials the server accepted. A
      // synthesised stand-in would carry no real `user.id` and so could not
      // activate the per-(server, user) scope anyway (#135).
      //
      // A declined grant rethrows too, where native would call it not
      // granted. Here the reconcile, not the envelope, is the authority on
      // whether a session exists — backend#407's hazard is an envelope with
      // no token over a live cookie — so while it cannot answer, its own
      // retryable failure is the honest report (#331).
      if (granted == null) rethrow;

      _log.warn(
        'Session reconcile after $context could not complete; keeping the '
        'granted session with an unconfirmed expiry',
        error: error,
        stackTrace: stackTrace,
      );
      _setState(AuthStateAuthenticated(session: granted));
      return granted;
    }

    if (confirmed == null) {
      // Null has two meanings and only one is the server's fault: the
      // reconcile's own epoch guard discards a response that resolved after
      // a sign-out and returns null. Blaming the server for the user's own
      // sign-out surfaced AuthFailureServer on the form (#146).
      //
      // The revocation half answers the same question for the sign-out that
      // was already in flight when this grant landed — the one
      // [_sessionEpoch] reads as equal here (see the catch above). The read
      // raced that revocation and lost, so an empty body is the user's own
      // sign-out too, not a server disowning the session it just issued.
      if (epoch != _sessionEpoch || _revocationEpoch != revocationEpoch) {
        throw const AuthSupersededException();
      }
      throw _noSessionAfter(context, grant);
    }

    // #346. A revocation completed while the read above was in
    // flight, so the cookie that read authenticated with has since been
    // deleted by name. Adopting `confirmed` would leave in-memory state
    // asserting a session over a cookie that no longer exists, and the next
    // request 401s — which is exactly #346, reached one round trip earlier
    // than the window [signOut] can settle for itself.
    //
    // The sign-out wins, as it does for every other supersession here
    // (#146). The successful read has already emitted authenticated, so the
    // state is corrected before the throw rather than left standing.
    if (_revocationEpoch != revocationEpoch) {
      _log.warn(
        'A sign-out revocation completed during the $context reconcile; its '
        'Set-Cookie deleted the cookie this grant received',
      );
      _setState(const AuthStateUnauthenticated());
      throw const AuthSupersededException();
    }

    // No epoch recheck here, unlike both failure branches above, and the
    // asymmetry is deliberate. Their window is a network round trip wide;
    // this one spans two adjacent microtasks — `getSession` emitted the
    // authenticated state synchronously and then returned, so the only way
    // to move the epoch in between is to observe that emission and call
    // [signOut] before this continuation resumes. Nothing can:
    // [watchAuthState] wraps the `sync: true` controller in a `Stream.multi`
    // whose delivery is asynchronous, so subscribers are notified strictly
    // AFTER an awaiting caller resumes. The controller's synchrony never
    // leaves this class, and it is pinned by a test.
    //
    // A guard here would therefore be unreachable — the same reason the
    // dead `on DioException` 401 branch was removed rather than repaired
    // (#180). If [watchAuthState] ever delivers synchronously, that test
    // fails and this becomes a real window; fix it there, not by adding an
    // untestable check here.
    //
    // No _setState either: the successful getSession above already emitted
    // the authenticated state. Native repeats the emission; on web the
    // stream is broadcast, so repeating it would publish an observable
    // duplicate for no gain.
    return confirmed;
  }

  EmailAndPasswordStrategy _requireEmailPasswordStrategy() {
    final strategy = _identity.emailAndPasswordStrategy;
    if (strategy == null) {
      throw const AuthServerException(
        message: 'This server does not support email/password authentication.',
      );
    }
    return strategy;
  }

  /// Decodes a body the transport was told not to touch, **deferring** the
  /// failure so the status can speak first.
  ///
  /// Every request here asks Dio for `Response<String>` **and pins
  /// `responseType` per request** — together, not either alone.
  /// `DioMixin.fetch` forces `responseType` from `T`, so `String` gives
  /// `plain` and anything else gives `json`
  /// (`dio-5.11.0/lib/src/dio_mixin.dart:417-427`) — but it skips that forcing
  /// entirely for an instance already set to `bytes` or `stream` (`:419-421`),
  /// and this class takes an arbitrary `Dio` by constructor. The pin is what
  /// makes the rule true here rather than only for the Dio the factories build
  /// (see `_plainBody`). Either half of Dio's own handling — the cast, or a
  /// `jsonDecode` driven by a content type that merely *claims* JSON — throws
  /// from inside the call as `DioException(type: unknown)` with **no response
  /// attached**, so the status was gone before anything could classify it
  /// (#352).
  ///
  /// Mirrors `AuthRepositoryImpl._decodeBody` on native, deliberately: the two
  /// repositories drive the same Dio and the same server, and a rule that held
  /// on one platform only is how #352 arose in the first place. The helper
  /// itself is `decodeJsonBody` from `dio_network`, shared rather than copied
  /// so its 50 KB isolate threshold lives in one place.
  ///
  /// The failure is **returned, not thrown**, because the two callers disagree
  /// about what it means. A rejected response whose body will not parse is
  /// still a rejection and its status is the honest answer. Only a 2xx has to
  /// answer for an unreadable body — and which failure it was decides the
  /// bucket: a body that is not JSON is a statement about the response and is
  /// definitive, while a failure to **perform** the decode is local, momentary
  /// and must stay retryable.
  Future<({Object? value, AuthException? failure})> _decodeBody(
    String? raw, {
    required String context,
    required int? status,
  }) async {
    if (raw == null || raw.isEmpty) return (value: null, failure: null);

    try {
      return (value: await _decodeJson(raw), failure: null);
    } on FormatException catch (error) {
      return (
        value: null,
        failure: AuthServerException(
          message:
              'The server returned a body that is not JSON during '
              '$context.',
          statusCode: status,
          cause: error,
        ),
      );
    } on Object catch (error) {
      return (
        value: null,
        failure: AuthLocalDecodeException(
          message: 'This device could not decode the response during $context.',
          cause: error,
        ),
      );
    }
  }

  /// Status-first validation of a credential grant, returning its decoded
  /// body — or **null** whenever that body cannot be read.
  ///
  /// The status still decides, and a rejection still throws. What an
  /// unreadable 2xx body does NOT do here is fail the sign-in, and that is the
  /// one place this deliberately diverges from the native twin (which throws)
  /// and from [_getSessionUnlatched] below (which also throws).
  ///
  /// The reason is web's, and [_readGrant] and [_reconcileCredentialGrant]
  /// are both already built on it: BetterAuth set the session cookie in **this
  /// response** and the browser has already stored it, so the grant envelope
  /// is a convenience and the reconcile is the authority. Declining an
  /// unreadable one costs an unconfirmed expiry; throwing on it would veto a
  /// sign-in that genuinely succeeded and whose credential is live — and the
  /// reconcile is about to settle the question either way. `_readGrant`
  /// already declines a body whose FIELDS are wrong; a body that is not JSON
  /// at all is the same situation reached one step earlier, and the two must
  /// not disagree.
  ///
  /// When the reconcile cannot settle it either, nothing is silently
  /// swallowed: [_reconcileCredentialGrant] rethrows the reconcile's own
  /// failure for exactly this `granted == null` case.
  Future<Map<String, dynamic>?> _requireGrantBody(
    Response<String> response, {
    required String context,
  }) async {
    final status = response.statusCode;

    // A REJECTION is settled from the status plus a bounded read of the raw
    // body, and never a full decode — see the native twin for the reasoning.
    // `_assertSuccess` never returns for a non-2xx.
    if (!_isSuccessStatus(status)) {
      _assertSuccess(status, response.data, context: context);
    }

    // A 2xx: the body IS the payload, so it earns a real decode.
    final decoded = await _decodeBody(
      response.data,
      context: context,
      status: status,
    );

    // Re-run on the decoded body: the duplicate-email envelope is not
    // status-gated, and here the decode has already happened.
    _assertSuccess(status, decoded.value, context: context);

    final failure = decoded.failure;
    if (failure != null) {
      _log.warn(
        'Unreadable $context body; the session endpoint has to confirm this '
        '$context unaided',
        error: failure,
        context: {'status': status},
      );
      return null;
    }

    // Every "nothing adoptable here" outcome is logged in THIS method, with
    // the reason that distinguishes it, and `_readGrant` no longer logs its
    // own null branch. It used to, and since its only callers hand it this
    // method's result, an unreadable body produced two warn records — the
    // second of them saying "No body on a successful $context" about a body
    // that was present and simply would not parse.
    final body = decoded.value;
    if (body == null) {
      _log.warn(
        'No body on a successful $context; the session endpoint has to '
        'confirm this $context unaided',
        context: {'status': status},
      );
      return null;
    }
    if (body is! Map<String, dynamic>) {
      _log.warn(
        'The $context body is not a JSON object; the session endpoint has to '
        'confirm this $context unaided',
        context: {'status': status},
      );
      return null;
    }
    return body;
  }

  void _assertSuccess(int? status, Object? body, {required String context}) {
    if (status == HttpStatusCode.unauthorized ||
        status == HttpStatusCode.forbidden) {
      throw const AuthInvalidCredentialsException();
    }

    if (_isEmailAlreadyExists(status, body)) {
      throw const AuthEmailAlreadyExistsException();
    }

    if (!_isSuccessStatus(status)) {
      throw AuthServerException(
        message: 'Unexpected $status during $context.',
        statusCode: status,
      );
    }
  }

  /// Whether [status] is a 2xx.
  ///
  /// One definition, used by both the credential paths ([_assertSuccess])
  /// and [signOut]. They had the range test written out separately, so a
  /// change to what counts as success — treating 3xx as its own case, say —
  /// could have landed on one and missed the other, leaving sign-out
  /// logging "not accepted" for a status sign-in treats as fine.
  ///
  /// A null status means Dio resolved a response without one, which is not
  /// a success this repository will act on.
  static bool _isSuccessStatus(int? status) =>
      status != null &&
      status >= HttpStatusCode.ok &&
      status < HttpStatusCode.multipleChoices;

  /// Pins `responseType` so an **injected** Dio cannot put a non-`String` in
  /// the body.
  ///
  /// `DioMixin.fetch` forces `responseType` from `T`, but skips that entirely
  /// when the instance is already `bytes` or `stream`
  /// (`dio-5.11.0/lib/src/dio_mixin.dart:419-421`). `assureResponse` then
  /// casts a `Uint8List` to `String` and the `TypeError` escapes as
  /// `DioException(type: unknown)` with no response attached — the status gone
  /// before anything can classify it, which is #352's bug by another door.
  /// This class takes an arbitrary `Dio` by constructor, so the type argument
  /// alone is not enough (#360).
  ///
  /// A fresh instance per call: `Options` is mutable, and one shared across
  /// four call sites is a shared mutable default waiting to be edited.
  ///
  /// Deliberately a twin of `AuthRepositoryImpl._plainBody` rather than a
  /// shared helper: #278 owns what gets extracted out of these two classes,
  /// and #360 rejected a shared request-shaping seam.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  /// Whether a rejected auth response means "this email is already
  /// registered".
  ///
  /// BetterAuth signals a duplicate sign-up as **422 Unprocessable Entity**
  /// with a `USER_ALREADY_EXISTS*` body code — it never uses 409. The exact
  /// code varies by version (`USER_ALREADY_EXISTS` per the docs;
  /// `USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL` observed live on the BGE dev
  /// server), so match the stable prefix rather than one literal. The 409
  /// Conflict mapping is kept for BGE's own route conventions. Deliberately
  /// NOT a bare status-422 match: other validation failures could share the
  /// status, and showing "account already exists" for those would be worse
  /// than the generic server-error copy.
  /// Ceiling on the synchronous probe below. A rejection envelope is a few
  /// hundred bytes, so anything past this is not the envelope being looked
  /// for, and reading it would be paying main-thread parse time for a body
  /// that cannot answer the question.
  static const int _probeMaxChars = 4 * 1024;

  bool _isEmailAlreadyExists(int? status, Object? body) {
    if (status == HttpStatusCode.conflict) return true;
    final decoded = body is String ? _probeJson(body) : body;
    final code = decoded is Map ? decoded['code'] : null;
    return code is String && code.startsWith('USER_ALREADY_EXISTS');
  }

  /// Best-effort synchronous decode, for the duplicate-email probe alone.
  ///
  /// [_mapDioException] reads the body off a **thrown** `DioException`, where
  /// it now arrives as the raw `String` the request asked for rather than the
  /// decoded map the probe used to get for free. Without this, a duplicate
  /// sign-up rejected by a `Dio` whose `validateStatus` is not
  /// `WebDioFactory`'s would report "unexpected 422" instead of "that account
  /// already exists".
  ///
  /// Deliberately not routed through `decodeJsonBody`: this reads a rejection
  /// envelope, which is small, and the probe is best-effort — a body that will
  /// not parse simply is not this envelope.
  ///
  /// Bounded by [_probeMaxChars], because this runs SYNCHRONOUSLY on the main
  /// thread.
  Object? _probeJson(String raw) {
    if (raw.isEmpty || raw.length > _probeMaxChars) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  /// [credentialGrant] gates the duplicate-email probe, which is meaningful
  /// only where an account is being created or a credential presented.
  ///
  /// `_isEmailAlreadyExists` treats **any** 409 as a duplicate, so without
  /// this a 409 from the session endpoint — a route that cannot mean
  /// "that email is taken" — reached the caller as
  /// `AuthEmailAlreadyExistsException` instead of the server fault it is.
  /// The response path never had the bug: it classifies a 409 by status
  /// before any envelope is consulted. Only the thrown path, reachable with
  /// an injected `Dio` whose `validateStatus` is not this factory's, routed
  /// a session 409 through the grant vocabulary.
  AuthException _mapDioException(
    DioException e, {
    required bool credentialGrant,
  }) {
    final status = e.response?.statusCode;
    if (status == HttpStatusCode.unauthorized ||
        status == HttpStatusCode.forbidden) {
      return const AuthInvalidCredentialsException();
    }

    if (credentialGrant && _isEmailAlreadyExists(status, e.response?.data)) {
      return const AuthEmailAlreadyExistsException();
    }

    if (status != null && status >= HttpStatusCode.internalServerError) {
      return AuthServerException(
        message: 'Server error $status.',
        statusCode: status,
        cause: e,
      );
    }

    // Genuine transport: the request was never answered, so there is no
    // status to classify by and INDETERMINATE is the honest bucket.
    // `sendTimeout` joins the list it was missing from — it fell to the
    // catch-all below, which used to reach the same answer by accident and
    // no longer does.
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError) {
      return AuthNetworkException(
        message: 'Connection failed. Check your network.',
        cause: e,
      );
    }

    // The server answered, with something the branches above did not claim.
    // The fallthrough used to call that a transport problem, which
    // contradicted the guard a few hundred lines above it — "a 200 whose body
    // is not the documented shape is a server fault, and it has to leave here
    // as one" — and showed "Connection failed. Check your network." for a
    // misrouted or rejected endpoint (#283).
    //
    // Reachable because this class accepts ANY injected `Dio`, which is the
    // same premise the session catch reasons from: `WebDioFactory`'s
    // permissive `validateStatus` resolves these as responses, but an
    // interceptor or a differently-configured Dio throws them.
    if (status != null) {
      return AuthServerException(
        message: 'Unexpected $status from the server.',
        statusCode: status,
        cause: e,
      );
    }

    // No status and no transport type: a cancellation, a bad certificate, or
    // a fault Dio could not attribute. Nothing answered, so INDETERMINATE.
    return AuthNetworkException(
      message: e.message ?? 'Network error.',
      cause: e,
    );
  }

  /// Tears down auth-state streaming. Does not close the injected [Dio] — that
  /// is a shared per-server resource owned and disposed by the container.
  @override
  Future<void> onDispose() async {
    await _stateController.close();
  }
}

/// A credential grant as [WebAuthRepositoryImpl._readGrant] read it (#331).
sealed class _Grant {
  const _Grant();
}

/// A grant carrying a session to adopt should the reconcile not settle.
final class _AdoptableGrant extends _Grant {
  const _AdoptableGrant(this.session);

  final AuthResponse session;
}

/// BetterAuth's `token: null` envelope: the server's own statement that it
/// declined to grant a session.
final class _DeclinedGrant extends _Grant {
  const _DeclinedGrant();
}

/// No body, a body that would not parse, or one whose fields are wrong:
/// nothing adoptable, and nothing said about why.
final class _UnreadableGrant extends _Grant {
  const _UnreadableGrant();
}
