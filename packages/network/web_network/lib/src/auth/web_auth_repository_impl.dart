import 'dart:async';

import 'package:dio/dio.dart';
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
/// - [getCachedSession] delegates to [getSession] since httpOnly cookies
///   are opaque to Dart code
/// - Single server only — no orchestrator or context switching
///
/// The [Dio] instance is built and owned by the per-server `WebDioFactory` and
/// injected here. This repository does not close it: it is a shared per-server
/// resource owned by the container. [onDispose] tears down only the auth-state
/// stream.
class WebAuthRepositoryImpl implements AuthRepository, Disposable {
  WebAuthRepositoryImpl({required this._identity, required this._dio})
    : _stateController = StreamController<AuthState>.broadcast(sync: true);

  final ServerIdentity _identity;
  final Dio _dio;
  final StreamController<AuthState> _stateController;
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
  /// Web needs only ONE checkpoint per method, where native has two. Native's
  /// second exists to unwind its own `TokenStorageService.store`; web
  /// persists nothing, and no await separates its guard from the state
  /// emission it protects.
  int _sessionEpoch = 0;

  @override
  AuthState get currentAuthState => _currentState;

  @override
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    final strategy = _requireEmailPasswordStrategy();

    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
        strategy.signInEndpoint,
        data: {'email': email, 'password': password},
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }

    _assertSuccess(response, context: 'sign-in');

    // BetterAuth set the session cookie in this response and the browser
    // stored it automatically. The reconcile that follows is for the full
    // user object and the canonical expiry — not for the credential.
    return _reconcileCredentialGrant(
      _grantOrNull(response, context: 'sign-in'),
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

    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.post<Map<String, dynamic>>(
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
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }

    _assertSuccess(response, context: 'sign-up');

    return _reconcileCredentialGrant(
      _grantOrNull(response, context: 'sign-up'),
      context: 'sign-up',
    );
  }

  @override
  Future<AuthResponse?> getSession() async {
    // Captured in the synchronous prologue, before ANY await — see
    // [_sessionEpoch].
    final epoch = _sessionEpoch;

    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.get<Map<String, dynamic>>(
        _identity.sessionEndpoint,
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
      final mapped = _mapDioException(e);

      if (epoch != _sessionEpoch) {
        _log.warn(
          'Discarding a failed session request that resolved after sign-out',
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

    // The user signed out while this request was in flight. Their intent is
    // newer than this response: discard it without touching state, so
    // sign-out stays final (see [_sessionEpoch]).
    if (epoch != _sessionEpoch) {
      _log.warn(
        'Discarding a session response that resolved after sign-out',
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
    final isDefinitiveNoSession =
        status == HttpStatusCode.unauthorized ||
        status == HttpStatusCode.forbidden ||
        (status == HttpStatusCode.ok && response.data == null);

    if (isDefinitiveNoSession) {
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

    // A 200 whose body is not the documented shape is a server fault, and it
    // has to leave here as one: `AuthRepository` admits only AuthException
    // subtypes out of getSession, and AuthBloc's sign-in / register handlers
    // catch nothing wider — a bare parse error would slip past every clause
    // and strand the form on AuthLoading with no way back. Native still
    // reaches straight for `fromJson` here and has the same gap.
    final BgeSessionResponse sessionResponse;
    try {
      sessionResponse = BgeSessionResponse.fromJson(response.data!);
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
  /// observed and logged rather than silently discarded.
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
    _setState(const AuthStateUnauthenticated());

    try {
      final response = await _dio.post<void>(_identity.signOutEndpoint);

      final status = response.statusCode;
      if (!_isSuccessStatus(status)) {
        // `validateStatus: (_) => true` (`WebDioFactory`) resolves a 5xx as
        // an ordinary Response, so the catch below only ever sees transport
        // faults. Without this branch the failure that actually matters —
        // the server declining to revoke, hence no `Set-Cookie: Max-Age=0`
        // — is the one failure logged nowhere, and the doc's promise that
        // awaiting makes it observable would hold for nothing.
        _log.warn(
          'Sign-out was not accepted; the session cookie may still be live '
          'until it expires server-side',
          context: {'status': status},
        );
      }
    } on Object catch (error, stackTrace) {
      // Best-effort in the sense that it cannot fail the sign-out — the
      // user's intent stands either way. It is not best-effort in the sense
      // of being skippable; see the doc above.
      _log.warn(
        'Sign-out POST did not complete; the session cookie may still be '
        'live until it expires server-side',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// On web, httpOnly cookies are opaque to Dart — we cannot inspect them
  /// without a network round-trip. Delegates to [getSession].
  @override
  Future<AuthResponse?> getCachedSession() => getSession();

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
  /// Returns null for three shapes: no body, a body that will not parse,
  /// and BetterAuth's documented `token: null` envelope — a server that
  /// granted no session, which is not something to adopt on a reconcile
  /// that cannot reach the server to disagree.
  AuthResponse? _grantOrNull(
    Response<Map<String, dynamic>> response, {
    required String context,
  }) {
    final data = response.data;
    if (data == null) {
      _log.warn(
        'No body on a successful $context; the session endpoint has to '
        'confirm this $context unaided',
        context: {'status': response.statusCode},
      );
      return null;
    }

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
        context: {'status': response.statusCode},
      );
      return null;
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
        context: {'status': response.statusCode},
      );
      return null;
    }

    // The token in this envelope is the same live credential the session
    // endpoint vends, and web has no use for it either (#291) — keep the
    // user identity, which is the only part that makes a granted session
    // adoptable, and leave the credential behind.
    return AuthResponse(
      token: null,
      user: granted.user,
      expiresAt: granted.expiresAt,
    );
  }

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
  ///   granted session, or rethrow if [granted] is null. Authentication genuinely happened and the browser
  ///   already holds the cookie proving it; failing here would report
  ///   "connection failed" for a sign-in that worked. The cost is an
  ///   unconfirmed expiry, which on web forfeits nothing — web never
  ///   restores optimistically ([restoreCachedSession] is unconditionally
  ///   null, #98 D10), so there is no offline path that needed it;
  /// - reconcile returns a **DEFINITIVE** "no session" → the server accepted
  ///   the credential and then disowned the session. That is a server
  ///   contract violation, not a network condition, and it must not be
  ///   reported as success.
  Future<AuthResponse> _reconcileCredentialGrant(
    AuthResponse? granted, {
    required String context,
  }) async {
    // Captured before the reconcile await, mirroring native's capture in
    // `_finalizeCredentialGrant`. Like native, it does not cover the
    // credential POST that preceded it — a deliberate bound, not an
    // oversight: every dispatcher of `AuthSignOutRequested` is either
    // unreachable while that POST is in flight or causally downstream of
    // it. The two UI dispatchers are home-menu entries
    // (`home_placeholder_screen.dart:93`, `bge_app.dart:522`), reachable
    // only from an authenticated shell. The one programmatic dispatcher
    // (`bge_app.dart:1117`) fires when `UserSessionScope.activate` fails,
    // which cannot run until this reconcile has already emitted — and web
    // registers no `UserSessionScope` at all until #137.
    //
    // Widening the capture would therefore guard a race no caller can
    // produce, and it would guard it incompletely: the late credential
    // response sets a fresh cookie that Dart cannot clear, so honouring a
    // supersession there needs a second revocation POST, not an earlier
    // capture. Revisit if any screen ever offers sign-out over
    // `AuthLoading` — that, not this line, is what holds the bound.
    final epoch = _sessionEpoch;

    final AuthResponse? confirmed;
    try {
      confirmed = await getSession();
    } on AuthException catch (error, stackTrace) {
      if (epoch != _sessionEpoch) {
        // The reconcile failed AND a sign-out landed meanwhile: do not adopt
        // the granted session over the sign-out's teardown.
        throw const AuthSupersededException();
      }

      // Indeterminate reconcile and no readable grant ([_grantOrNull]):
      // nothing adoptable exists on either side. Surface the reconcile's own
      // failure rather than dressing it up as a server fault — it is what
      // actually went wrong, and its retryable copy is the honest thing to
      // show for a sign-in whose credentials the server accepted. A
      // synthesised stand-in would carry no real `user.id` and so could not
      // activate the per-(server, user) scope anyway (#135).
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
      if (epoch != _sessionEpoch) {
        throw const AuthSupersededException();
      }
      throw AuthServerException(
        message:
            'Authentication succeeded but the server reported no session '
            'during $context.',
      );
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

  void _assertSuccess(
    Response<Map<String, dynamic>> response, {
    required String context,
  }) {
    final status = response.statusCode;
    if (status == HttpStatusCode.unauthorized ||
        status == HttpStatusCode.forbidden) {
      throw const AuthInvalidCredentialsException();
    }

    if (_isEmailAlreadyExists(status, response.data)) {
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
  bool _isEmailAlreadyExists(int? status, Object? body) {
    if (status == HttpStatusCode.conflict) return true;
    final code = body is Map ? body['code'] : null;
    return code is String && code.startsWith('USER_ALREADY_EXISTS');
  }

  AuthException _mapDioException(DioException e) {
    final status = e.response?.statusCode;
    if (status == HttpStatusCode.unauthorized ||
        status == HttpStatusCode.forbidden) {
      return const AuthInvalidCredentialsException();
    }

    if (_isEmailAlreadyExists(status, e.response?.data)) {
      return const AuthEmailAlreadyExistsException();
    }

    if (status != null && status >= HttpStatusCode.internalServerError) {
      return AuthServerException(
        message: 'Server error $status.',
        statusCode: status,
        cause: e,
      );
    }

    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => AuthNetworkException(
        message: 'Connection failed. Check your network.',
        cause: e,
      ),
      _ => AuthNetworkException(
        message: e.message ?? 'Network error.',
        cause: e,
      ),
    };
  }

  /// Tears down auth-state streaming. Does not close the injected [Dio] — that
  /// is a shared per-server resource owned and disposed by the container.
  @override
  Future<void> onDispose() async {
    await _stateController.close();
  }
}
