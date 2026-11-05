import 'dart:async';

import 'package:di/di.dart' show LocalClockService, replayThenForward;
import 'package:http_status/http_status.dart';
import 'package:dio/dio.dart';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart'
    show ClockService, ProviderSignInBrowser, UnsupportedProviderSignInBrowser;
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:observability/observability.dart';

import '../network/api_error_envelope.dart';
import '../network/decode_json_body.dart';
import '../network/redact_uri.dart';
import '../network/token_interceptor.dart';
import 'provider_sign_in/app_sign_in_return_address.dart';
import 'provider_sign_in/pkce.dart';
import 'provider_sign_in/provider_sign_in_attempt.dart';
import 'provider_sign_in/server_address.dart';
import 'rate_limited.dart';
import 'session_read_status.dart';
import 'token_storage_service.dart';

/// Dio-based [AuthRepository] for mobile and desktop.
///
/// Scoped to a single BGE server. Must be registered inside the server's
/// [DependencyContainer] after the [ServerIdentity] has been fetched.
/// Never shared across server contexts.
///
/// The [Dio] instance is built and owned by the per-server [DioFactory] and
/// injected here. Token attachment is handled by a [TokenInterceptor] in the
/// factory's interceptor stack, not by this repository — so every repository
/// sharing the same [Dio] inherits authentication regardless of construction
/// order.
///
/// This repository does not close the injected [Dio]: it is a shared
/// per-server resource owned by the container. [onDispose] tears down only the
/// auth-state stream and any provider sign-in still in flight.
///
/// ## Offline-first session restore (#98)
///
/// Every successful `getSession` writes a full session snapshot (token,
/// server-confirmed expiry, user) so a later cold start with no
/// connectivity can enter the app on it via [restoreCachedSession]. Sign-in
/// and sign-up deliberately persist a **null** expiry: the credential-grant
/// response carries no session lifetime, and inventing one is what made the
/// old seven-day guess unsafe to build on.
class AuthRepositoryImpl implements AuthRepository, Disposable {
  AuthRepositoryImpl({
    required this._identity,
    required this._serverUrl,
    required this._tokenStorage,
    required this._dio,
    this._providerBrowser = const UnsupportedProviderSignInBrowser(),
    this._clock = const LocalClockService(),
    this._deviceNowUtc = _systemDeviceNowUtc,
    this._decodeJson = decodeJsonBody,
  }) : _stateController = StreamController<AuthState>.broadcast(sync: true);

  static DateTime _systemDeviceNowUtc() => DateTime.now().toUtc();

  final ServerIdentity _identity;

  /// The address discovery was fetched from (`ServerConfig.serverUrl`).
  /// Provider sign-in is offered only when [_identity]'s issuer names it, a
  /// return's `iss` must name it, and the provider routes resolve against it
  /// (#583).
  final String _serverUrl;

  /// The in-app browser tab provider sign-in runs in (#583). The default, a
  /// device with none, leaves provider sign-in unavailable.
  final ProviderSignInBrowser _providerBrowser;
  final TokenStorageService _tokenStorage;
  final Dio _dio;
  final StreamController<AuthState> _stateController;

  /// Per-server clock (#12). Every timestamp this repository writes or
  /// compares goes through it, so a device with a skewed wall clock does
  /// not mis-decide session expiry. Defaults to the [LocalClockService]
  /// null object for hosts and tests without a skew source; the production
  /// composition in `registerServerNetwork` injects the server's estimator.
  final ClockService _clock;

  /// Raw device clock, deliberately uncorrected and deliberately separate
  /// from [_clock]. Used only for the persisted device stamp and the
  /// clock-plausibility guard that reads it back — both questions about the
  /// device's own timeline rather than the server's. See
  /// [StoredSession.isDeviceClockPlausibleAt] for why mixing the two
  /// silently disables offline restore on skewed devices.
  final DateTime Function() _deviceNowUtc;

  /// The JSON decode behind [_decodeBody]. Always `decodeJsonBody` in
  /// production; injectable because its second failure mode — an offload
  /// isolate that would not spawn — is the one no response body can produce,
  /// so without a seam the more expensive branch of the split is the untested
  /// one (#364).
  final Future<Object?> Function(String) _decodeJson;

  AuthState _currentState = const AuthStateUnknown();

  /// Bumped by [signOut] synchronously, before any await. [getSession]
  /// captures it in its own synchronous prologue — before the storage load,
  /// not merely before the HTTP call — and re-checks it once the response
  /// lands, so a response that resolves *after* the user signed out is
  /// discarded instead of writing session material and re-emitting
  /// authenticated. Both halves must sit ahead of every suspension point:
  /// a capture taken after an await samples a value the racing sign-out may
  /// already have bumped, which makes the later comparison match and the
  /// guard silently inert.
  ///
  /// Without this, sign-out's teardown was not final: the resumed handler
  /// called `store`, which lifts the storage sign-out latch and rewrites
  /// both the token and the user snapshot. The token half of that hole
  /// predates #98; the snapshot half would have broken the "clear is the
  /// single, total teardown path" guarantee this feature's PII handling
  /// rests on, leaving a signed-out user's email and display name back on
  /// disk.
  int _sessionEpoch = 0;

  /// The provider sign-in waiting on its browser tab or its code exchange
  /// (#583). One per repository: a new attempt replaces it, and a sign-out, a
  /// password sign-in or sign-up, and [onDispose] retire it, so a return for
  /// anything but the attempt held here adopts nothing.
  ///
  /// Attempts live here, in the per-server repository, so a return is only
  /// ever adopted by the server its attempt started on. [onDispose] runs when
  /// that server is removed or suspended. A server switch only backgrounds the
  /// server and keeps this repository, so an attempt open across a switch
  /// still finishes here, into this server's own token storage.
  ProviderSignInAttempt? _pendingAttempt;

  /// Ends the pending provider sign-in, if there is one, for a newer intent
  /// (#583). Synchronous, so that it lands before the caller's first await:
  /// the tab's late return then finds no attempt, throws
  /// [AuthSupersededException] and stores nothing.
  void _retireProviderAttempt() => _pendingAttempt = null;

  @override
  AuthState get currentAuthState => _currentState;

  /// Logs the auth seams the network interceptor and bloc cannot see with
  /// the right context (#100): the pre-wire strategy-missing contract
  /// failure (error), stored-session rejection on the 401-clear paths
  /// (warn — the bloc only ever sees the resulting `Unauthenticated`, so
  /// "why was the user logged out" would otherwise be silent), and the
  /// optimistic-restore decisions (#98), which happen entirely below the
  /// bloc and are otherwise invisible. Wire-level transport failures are
  /// `NetworkLogInterceptor`'s job; semantic operation outcomes are
  /// `AuthBloc`'s.
  final BgeLogger _log = BgeLogger('bge.auth.repository');

  @override
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    // A password sign-in is newer than any provider tab still open: that tab
    // must not sign another account in over this one (#583).
    _retireProviderAttempt();

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

    return _finalizeCredentialGrant(
      _parseGrant(body, context: 'sign-in', status: response.statusCode),
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
    // As in [signIn]: the new account wins over a provider tab still open.
    _retireProviderAttempt();

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

    return _finalizeCredentialGrant(
      _parseGrant(body, context: 'sign-up', status: response.statusCode),
      context: 'sign-up',
    );
  }

  /// Persists a freshly granted credential and reconciles it against the
  /// session endpoint.
  ///
  /// The grant response carries a token and a user but no expiry, so the
  /// material is stored with a **null** (unknown) expiry first — the token
  /// must be readable by the [TokenInterceptor] before the reconcile call
  /// goes out, or that call would be unauthenticated.
  ///
  /// Three outcomes, and the distinction matters:
  ///
  /// - reconcile succeeds → adopt the confirmed session, which has now
  ///   also rewritten the payload with a real expiry;
  /// - reconcile is **indeterminate** → keep the granted session.
  ///   Authentication genuinely happened; failing the sign-in here would
  ///   show "connection failed" for a sign-in that worked, and would leave
  ///   a valid token stored under a state that says otherwise. The cost is
  ///   an unconfirmed expiry, which only forfeits offline restore until the
  ///   next successful `getSession`.
  ///
  ///   A transport failure and a 5xx are the obvious instances, and an
  ///   earlier version of this list named only those two. That read as
  ///   exhaustive and is not: **indeterminate means this client could not
  ///   determine whether a session exists**, and the widest case is a 2xx
  ///   whose body cannot be read at all — a captive portal or proxy
  ///   answering the session endpoint with HTML. #180 **D10** made that a
  ///   modelled `AuthServerException` instead of a bare `TypeError`, and
  ///   the test named for it on web pins the outcome: *an unreadable
  ///   session body is indeterminate, so the reconcile keeps the granted
  ///   session rather than failing a sign-in whose credentials the server
  ///   accepted.*
  ///
  ///   The distinction that makes this the right bucket, and that a reader
  ///   coming to the `on AuthException` catch below is likely to trip on:
  ///   "the response is definitively broken" is not "the session is
  ///   definitively absent". Only the second licenses failing a sign-in the
  ///   server just accepted, and an unparseable body asserts neither.
  ///
  ///   So the catch below is deliberately broad, and is **not** missing a
  ///   classification branch. Every definitive negative returns null rather
  ///   than throwing — #180 **D11** fixed that at the source in
  ///   `getSession` and explicitly *rejected* adding a rethrow inside this
  ///   reconcile, on the grounds that fixing the source makes such a branch
  ///   unreachable and unreachable status checks were the defect that issue
  ///   existed to remove. Anything arriving here as an exception is
  ///   therefore indeterminate by construction.
  ///
  ///   What would change that: giving the session route an error envelope
  ///   able to distinguish "the application rejected you" from "nothing
  ///   answered for it" — the discriminator #297 **D1** looked for and
  ///   could not find. A 4xx carrying it would become a definitive negative
  ///   and belong in the branch above, settled in `getSession`, not here.
  ///   Until then a thrown 4xx stays indeterminate, which is also what
  ///   #297 concluded for a 404 on a fixed route: it says the request never
  ///   reached the application, not that the caller was refused.
  ///
  ///   Either way, `WebAuthRepositoryImpl._reconcileCredentialGrant` holds
  ///   the identical posture and must move with it — #352 exists because
  ///   the two halves of this classification were allowed to drift.
  /// - reconcile returns a **definitive** "no session" → the server
  ///   accepted the credentials and then disowned the session. That is a
  ///   server contract violation, not a network condition, and it must not
  ///   be reported as success: the token has already been cleared, or
  ///   refused if the delete failed, by `getSession`, so a "signed in" state
  ///   here would 401 on every subsequent request. Matches
  ///   `WebAuthRepositoryImpl.signUp`.
  Future<AuthResponse> _finalizeCredentialGrant(
    AuthResponse granted, {
    required String context,
  }) async {
    // `AuthResponse.token` is nullable so web can decline to carry a
    // credential it never reads (#291). Native reads it, so here a null is
    // a grant that cannot be acted on: it is BetterAuth's documented
    // no-session envelope (email verification required, or `autoSignIn`
    // off), which this platform has no way to complete a sign-in from.
    //
    // Checked BEFORE the epoch capture and before any await, so the whole
    // method is unreachable on this shape — nothing is persisted, no
    // reconcile goes out, and the auth state is never moved.
    //
    // This must throw a modelled AuthException rather than let a null
    // reach `TokenStorageService.store`. Before the field was nullable the
    // same envelope failed inside `AuthResponse.fromJson`, and a raw parse
    // error slips past every `on AuthException` clause in AuthBloc and
    // strands the form on AuthLoading — the failure this replaces.
    //
    // Not a server fault: the server answered as configured, and calling it
    // one invited a retry that can only get the same answer (#331).
    final token = granted.token;
    if (token == null) {
      throw AuthSessionNotGrantedException(
        message:
            'The server accepted the $context but granted no session token.',
      );
    }

    // Captured before the first await IN THIS METHOD — every suspension
    // below (the store, the reconcile) is a window a sign-out can land in,
    // and each outcome must be able to tell "the server misbehaved" apart
    // from "the user left" (#146).
    //
    // It does NOT cover the caller's grant POST or the body decode that
    // #352 added after it, and that is a bound rather than an oversight —
    // the same bound the web twin's `_reconcileCredentialGrant` documents at
    // length. Every dispatcher of `AuthSignOutRequested` is either
    // unreachable while a credential grant is in flight or causally
    // downstream of it: the two UI entries live in the authenticated shell
    // (`home_placeholder_screen.dart:93`, `bge_app.dart:552`) and
    // `AuthBloc._onSignIn` holds the form on `AuthLoading` for the whole
    // call, while the one programmatic dispatcher (`bge_app.dart:1561`)
    // fires on a `UserSessionScope.activate` failure that cannot run until
    // this method has already returned.
    //
    // Widening the capture would guard a race no caller can produce.
    // Revisit if any screen ever offers sign-out over `AuthLoading` — that,
    // not this line, is what holds the bound.
    //
    // Provider sign-in (#583) is the exception, and the bound does not hold
    // for it. Its window before this method is a whole browser session, and
    // on macOS the window behind the sheet stays usable, so a password
    // sign-in, and a sign-out after it, can land while the tab is open. That
    // window is guarded before this method instead: `signOut`, `signIn` and
    // `signUp` retire the pending attempt synchronously, and
    // `_exchangeProviderCode` checks it after the POST and again after the
    // decode, with nothing that suspends between that last check and this
    // capture. A provider grant that reaches here is still the newest intent,
    // and from here the epoch covers it as it covers a password grant. Like a
    // password grant's, it is not retired by [onDispose] from here on: a
    // disposal does not move the epoch, and clearing on a retirement could
    // delete a newer password grant's token instead of this one's.
    final epoch = _sessionEpoch;

    await _tokenStorage.store(
      token: token,
      expiresAt: null,
      persistedAt: _deviceNowUtc(),
      user: granted.user,
    );

    // A sign-out during the grant store: the latch stands, whether the store
    // was dropped for it or its write was overtaken. Clear again for whatever
    // that write left, and report supersession — the sign-in genuinely
    // succeeded server-side, but locally the sign-out is the newer intent and
    // must win.
    if (epoch != _sessionEpoch) {
      await _clearQuietly('a superseded credential grant');
      throw const AuthSupersededException();
    }

    final AuthResponse? confirmed;
    try {
      confirmed = await getSession();
    } on AuthException catch (error) {
      if (epoch != _sessionEpoch) {
        // The reconcile failed AND a sign-out landed meanwhile: do not
        // adopt the granted session over the sign-out's teardown.
        throw const AuthSupersededException();
      }

      _log.warn(
        'Session reconcile after $context could not complete; keeping the '
        'granted session with an unconfirmed expiry',
        context: {'cause': error.runtimeType.toString()},
      );
      _setState(AuthStateAuthenticated(session: granted));
      return granted;
    }

    if (confirmed == null) {
      // Null has two meanings and only one is the server's fault: the
      // reconcile's own epoch guard discards a response that resolved
      // after a sign-out and returns null. Blaming the server for the
      // user's own sign-out surfaced AuthFailureServer on the form (#146).
      if (epoch != _sessionEpoch) {
        throw const AuthSupersededException();
      }
      throw AuthServerException(
        message:
            'Authentication succeeded but the server reported no session '
            'during $context.',
      );
    }

    _setState(AuthStateAuthenticated(session: confirmed));
    return confirmed;
  }

  @override
  Future<AuthResponse?> getSession() async {
    // Captured in the synchronous prologue, before ANY await. Reading it
    // after the storage load would sample an epoch that a sign-out landing
    // during that load had already bumped, so the comparison below would
    // match and the guard would never fire — the whole race the epoch
    // exists to catch happens across exactly that first suspension point.
    final epoch = _sessionEpoch;

    final stored = await _tokenStorage.retrieve();
    if (stored == null) {
      _setState(const AuthStateUnauthenticated());
      return null;
    }

    late final Response<String> response;
    try {
      response = await _dio.get<String>(
        _identity.sessionEndpoint,
        options: _plainBody,
      );
    } on DioException catch (e) {
      // A rejected session (401) arrives as a Response, not a thrown
      // DioException — the per-server Dio sets validateStatus:(_)=>true, so
      // any HTTP status resolves normally and is handled on the response
      // path below.
      //
      // This comment used to say reaching here MEANS a transport-level
      // failure. That was false twice over, and #352 is the second half.
      // A Dio whose validateStatus is not this factory's throws
      // `badResponse` with the response attached, which `_mapDioException`
      // now classifies by status rather than as transport (#283). And before
      // this request asked for `Response<String>` and pinned `responseType`
      // (see `_plainBody`, #360), Dio owned the body: a cast or a
      // `jsonDecode` it drove itself threw from inside the call, arriving
      // here as `DioException(type: unknown)` with no response — so a
      // captive portal's HTML reached the user as "can't reach the server"
      // with the dead session still on disk.
      final status = e.response?.statusCode;

      // A thrown 401/403 is the SAME definitive negative the response path
      // settles below, so it goes through `readSessionStatus` too and settles
      // the same way. Rethrowing it left the dead token on disk for the
      // `TokenInterceptor` and the auth state wherever it stood — and,
      // reaching `_finalizeCredentialGrant` as an exception, its
      // `on AuthException` catch bucketed this definitive rejection as
      // INDETERMINATE and kept a session the server had just disowned. That
      // method's own contract already promises the opposite: "the token has
      // already been cleared by getSession". It was not.
      //
      // Web locked this call in #180 for the same reason; native kept the
      // gap because its permissive `validateStatus` normally resolves a 401
      // as a Response, and only an injected Dio — which this class accepts
      // by design — throws one.
      if (readSessionStatus(status) == SessionReadStatus.noSession) {
        if (epoch != _sessionEpoch) {
          _log.warn(
            'Discarding a rejected session response that resolved after '
            'sign-out',
          );
          return null;
        }
        return _settleNoSession(status: status, uri: e.requestOptions.uri);
      }

      throw _mapDioException(e, credentialGrant: false);
    }

    // The user signed out while this request was in flight. Their intent is
    // newer than this response: discard it without touching storage or
    // state, so sign-out stays final (see [_sessionEpoch]).
    if (epoch != _sessionEpoch) {
      _log.warn(
        'Discarding a session response that resolved after sign-out',
        context: {'status': response.statusCode},
      );
      return null;
    }

    final status = response.statusCode;

    // The status decides first, by the rules `readSessionStatus` holds with
    // their reasons. What is local is the reaction: a definitive "no
    // session" means the stored material is dead, so `_settleNoSession`
    // clears it and settles on unauthenticated. BetterAuth's 200-with-no-body
    // settles the same way, after the decode below — a reordering #352
    // forced, not a change of rule: reading "no session" off an undecoded
    // string would call a captive portal's HTML page a rejected session and
    // clear the user's credentials over it.
    switch (readSessionStatus(status)) {
      case SessionReadStatus.noSession:
        return _settleNoSession(
          status: status,
          uri: response.requestOptions.uri,
        );
      case SessionReadStatus.undecided:
        throw AuthServerException(
          message: 'Unexpected $status from the session endpoint.',
          statusCode: status,
        );
      case SessionReadStatus.readBody:
        break;
    }

    final decoded = await _decodeBody(
      response.data,
      context: 'the session check',
      status: status,
    );

    // Second checkpoint, and it has to be HERE rather than after the store
    // below. The decode is a suspension point — `decodeJsonBody` offloads a
    // body over 50 KB to another isolate — and it now sits between the guard
    // above and `_tokenStorage.store`. Without this, a sign-out landing
    // mid-decode still reaches that store, which lifts the sign-out latch and
    // re-persists the signed-out user's bearer token and PII snapshot to disk
    // before the post-store guard undoes it. `clear()` is documented as the
    // single, total teardown path (see [_sessionEpoch]); a write that has to
    // be taken back is not that.
    //
    // Ahead of the throw as well, so a response the user's own sign-out
    // superseded is discarded rather than reported as a server fault. The web
    // twin takes the same call at the same point.
    if (epoch != _sessionEpoch) {
      _log.warn(
        'Discarding a session response decoded after sign-out',
        context: {'status': status},
      );
      return null;
    }

    // A 2xx the transport answered but this client cannot read. Definitive
    // when the body is not JSON, INDETERMINATE when the decode itself could
    // not be performed — and the difference is the whole of #352 on this
    // path, because only one of them may clear the user's credentials.
    // Neither does: both leave as an exception, and the clear below is
    // reached only by a session the SERVER disowned.
    final failure = decoded.failure;
    if (failure != null) throw failure;

    // The "no session" answer the status could not give, which
    // `SessionReadStatus.readBody` left to the body: BetterAuth answers 200
    // with no session payload. An empty body and a literal JSON `null` both
    // land here as null, which is exactly what
    // `Response<Map<String, dynamic>>` used to hand over as `data == null`.
    final body = decoded.value;
    if (body == null) {
      return _settleNoSession(status: status, uri: response.requestOptions.uri);
    }

    if (body is! Map<String, dynamic>) {
      throw AuthServerException(
        message:
            'The session endpoint returned a body that is not a JSON object.',
        statusCode: status,
      );
    }

    // Wrapped so a well-formed body with the WRONG FIELDS cannot escape as a
    // raw `TypeError` (#181) — see [_parseGrant] for why nothing raw may
    // leave an auth method.
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

    // The one path that produces a server-confirmed expiry, and therefore
    // the one that makes a later offline restore possible (#98).
    //
    // Persist the SERVER-VENDED token, not the one we sent. BetterAuth's
    // session endpoint returns the authoritative session record, and its
    // `token` is the same raw session token used as the bearer credential
    // (the sign-in body's `token` is that same column — an opaque string
    // with no signature suffix, so there is no signed/raw mismatch to
    // guard against). Echoing back `stored.token` would silently pin the
    // client to a stale credential the moment the server renews one, and
    // the symptom — 401s appearing roughly one refresh interval after
    // sign-in — points nowhere near this line.
    await _tokenStorage.store(
      token: sessionResponse.session.token,
      expiresAt: sessionResponse.session.expiresAt,
      persistedAt: _deviceNowUtc(),
      user: sessionResponse.user,
    );

    // Second epoch check, covering the store await itself: after a signOut()
    // landing DURING that write, the emit below would re-assert the session.
    // Clear again for whatever the write left and stand down; the sign-out's
    // teardown is the newer intent.
    if (epoch != _sessionEpoch) {
      _log.warn(
        'Sign-out landed while persisting a session response; re-clearing',
      );
      await _clearQuietly('a session response overtaken by sign-out');
      return null;
    }

    final auth = AuthResponse(
      // Same server-vended token that was just persisted — the in-memory
      // session and the stored payload must never disagree about the
      // credential.
      token: sessionResponse.session.token,
      user: sessionResponse.user,
      expiresAt: sessionResponse.session.expiresAt,
    );

    _setState(AuthStateAuthenticated(session: auth));
    return auth;
  }

  @override
  Future<void> signOut() async {
    // Invalidate any in-flight session request FIRST, before any await: a
    // response that resolves after this point must not resurrect the
    // session material or the auth state (see [_sessionEpoch]).
    _sessionEpoch += 1;

    // Likewise a provider tab still open: its return must not sign the user
    // back in after this (#583).
    _retireProviderAttempt();

    // Capture the bearer token BEFORE clearing. TokenStorageService.clear()
    // sets its sign-out latch synchronously, after which retrieve() — and so
    // the TokenInterceptor — reports no token; a POST left to the interceptor
    // would go out with no Authorization header, leaving the session
    // un-revoked server-side. Reading it here lets the POST carry the token
    // explicitly (PR #103 review). The POST also opts out of the interceptor,
    // so this value is its credential whatever the timing: an interceptor
    // that reached storage after a new sign-in would otherwise overwrite it
    // and revoke that session instead (#433).
    final token = await _readSignOutToken();

    // Best-effort server call, fire-and-forget: its result is discarded,
    // so we must not block the local sign-out on it — awaiting would make
    // the user watch a spinner for the full Dio timeout on an unreachable
    // server (#37 review #9). The helper is Future<void> and swallows both
    // synchronous throws and async rejections.
    unawaited(_bestEffortSignOutPost(token));

    try {
      await _tokenStorage.clear();
    } on Object catch (error, stackTrace) {
      // The persisted material could not be cleared. Rethrow as the typed,
      // contract-covered exception (stack preserved). The `finally` runs
      // before it propagates, so callers and the state stream observe the
      // unauthenticated transition FIRST. TokenStorageService.clear() sets
      // its sign-out latch BEFORE the failing delete, so retrieve() — and
      // therefore the TokenInterceptor's Authorization header and any
      // same-process getSession() — already report nothing stored: a
      // surviving payload can be resurrected neither at the HTTP layer nor
      // in state (PR #99 review). At the next cold start the marker clear()
      // wrote ahead of the delete refuses the payload, and the delete is
      // retried (#356). If the marker could not be written either, the payload
      // can still be read then.
      Error.throwWithStackTrace(
        AuthSignOutPersistenceException(cause: error),
        stackTrace,
      );
    } finally {
      _setState(const AuthStateUnauthenticated());
    }
  }

  /// Fire-and-forget sign-out POST carrying [token] as an explicit bearer
  /// credential. It opts out of the [TokenInterceptor] with
  /// [TokenInterceptor.skipAuthKey], so the credential does not depend on
  /// when Dio reaches the interceptor relative to the sign-out latch or a
  /// later sign-in (#433; see [signOut]). A null [token] sends no header.
  /// Never throws: a synchronous throw or an async rejection is swallowed
  /// (best-effort by design). Typed `Future<void>` so it satisfies
  /// [unawaited].
  Future<void> _bestEffortSignOutPost(String? token) async {
    try {
      // `String` plus the pin, for the same reason as every other request
      // here — see `_plainBody`. Cosmetic on this path, since the catch below
      // discards every outcome, but leaving one call site off the rule is how
      // the rule gets forgotten.
      //
      // Written out rather than cascaded onto `_plainBody`. This is the only
      // site that would mutate the pinned instance, and what it writes is a
      // bearer token: if `_plainBody` ever became a shared `final` — which
      // its own doc warns against, and which is the obvious "avoid the
      // allocation" refactor — a cascade here would stamp one user's
      // `Authorization` header onto every later request in the process.
      // Keeping every call site read-only means that refactor stays merely
      // wrong rather than a credential leak.
      await _dio.post<String>(
        _identity.signOutEndpoint,
        options: Options(
          responseType: ResponseType.plain,
          headers: {if (token != null) 'Authorization': 'Bearer $token'},
          extra: {TokenInterceptor.skipAuthKey: true},
        ),
      );
    } on Object {
      // discarded
    }
  }

  /// Best-effort read of the current bearer token for the sign-out POST.
  /// Never throws — a storage read failure must not block local sign-out.
  Future<String?> _readSignOutToken() async {
    try {
      final stored = await _tokenStorage.retrieve();
      return stored?.token;
    } on Object {
      return null;
    }
  }

  @override
  Future<AuthResponse?> getCachedSession() async {
    final stored = await _tokenStorage.retrieve();
    if (stored == null) return null;

    final now = _clock.nowUtc();
    final deviceNow = _deviceNowUtc();

    // Known-dead material is never handed back, not even via the in-memory
    // branch below.
    if (stored.isExpiredAt(now)) return null;

    // An in-memory session wins: it is at least as fresh as the payload and,
    // unlike the payload, it exists even when the expiry was never confirmed
    // (a sign-in whose reconcile failed). Dropping this branch would tell a
    // signed-in caller — `UserDataExportBundler`, for one — that it is
    // unauthenticated purely because the server never sent an expiry.
    if (_currentState case AuthStateAuthenticated(:final session)) {
      return session;
    }

    // The snapshot local is read first purely to promote it to non-null for
    // the AuthResponse below; canRestoreOffline already requires it, so the
    // null branch here is belt-and-braces rather than a second policy.
    final snapshot = stored.user;
    if (snapshot == null ||
        !stored.canRestoreOffline(
          correctedNowUtc: now,
          deviceNowUtc: deviceNow,
        )) {
      _logIneligibleRestore(stored, deviceNow);
      return null;
    }

    return AuthResponse(
      token: stored.token,
      user: snapshot,
      expiresAt: stored.expiresAt,
    );
  }

  @override
  Future<AuthResponse?> restoreCachedSession() async {
    final cached = await getCachedSession();
    if (cached == null) return null;

    // Already the working session — nothing to adopt, and re-emitting would
    // wrongly downgrade a server-verified state to unverified.
    if (_currentState case AuthStateAuthenticated()) return cached;

    _log.info(
      'Entering on a cached session; server unreachable, awaiting '
      'revalidation',
      context: {'expires_at': cached.expiresAt?.toIso8601String()},
    );

    _setState(
      AuthStateAuthenticated(
        session: cached,
        verification: SessionVerification.unverifiedOffline,
      ),
    );
    return cached;
  }

  /// Explains a refused restore at warn level. These are the decisions no
  /// other layer can see: the bloc receives only "no cached session" and
  /// would otherwise leave a support question ("why does it make me sign in
  /// when I was signed in yesterday?") with no trail.
  void _logIneligibleRestore(StoredSession stored, DateTime deviceNow) {
    final String reason;
    if (!stored.isDeviceClockPlausibleAt(deviceNow)) {
      reason = 'device clock precedes the moment the session was persisted';
    } else if (!stored.hasConfirmedExpiry) {
      reason = 'expiry was never confirmed by the server';
    } else {
      reason = 'no persisted user snapshot';
    }
    _log.warn(
      'Cached session is not eligible for offline restore',
      context: {'reason': reason},
    );
  }

  /// Native app sign-in (#583): a PKCE pair and a `state`, the in-app browser
  /// tab, the checks on what it returns, then the code exchange at the token
  /// route the attempt recorded when it started.
  ///
  /// The attempt is recorded before the tab opens and dropped when this call
  /// ends, but only while it is still the one held: a newer attempt that
  /// replaced it stays pending.
  @override
  Future<ProviderSignInOutcome> signInWithProvider(
    OidcStrategy strategy,
  ) async {
    final unavailable = switch (providerSignInAvailability) {
      ProviderSignInAvailable() => null,
      ProviderSignInUnsupportedDevice() => 'device',
      ProviderSignInAddressMismatch() => 'issuer',
    };
    if (unavailable != null) {
      // The screen disables its provider buttons in this case, so reaching
      // here is a caller that skipped the check. Refused before any request.
      _log.warn(
        'Refusing to start a provider sign-in that is not available here',
        context: {'check': unavailable},
      );
      throw const AuthProviderSignInException(
        ProviderSignInFailureReason.generic,
        message: 'Provider sign-in is not available here.',
      );
    }

    final start = resolveServerEndpoint(_serverUrl, strategy.appSignInEndpoint);
    final tokenEndpoint = resolveServerEndpoint(
      _serverUrl,
      strategy.appTokenEndpoint,
    );
    if (start == null || tokenEndpoint == null) {
      // A discovery path no address can be made from, or an absolute one off
      // this server's origin. Refused here, before the tab opens or any
      // request goes out, as a modelled exception: a raw FormatException
      // would strand the caller on its loading state (#181).
      _log.warn(
        'Refusing to start a provider sign-in whose routes are not addresses '
        'on this server',
        context: {'check': 'endpoint'},
      );
      throw const AuthProviderSignInException(
        ProviderSignInFailureReason.generic,
        message: 'The server sent a provider sign-in route that is not valid.',
      );
    }

    final attempt = ProviderSignInAttempt(
      state: randomUrlSafeToken(),
      codeVerifier: randomUrlSafeToken(),
      providerId: strategy.providerId,
      tokenEndpoint: tokenEndpoint,
      issuerAddress: _serverUrl,
    );
    _pendingAttempt = attempt;

    try {
      return await _runProviderSignIn(attempt, start);
    } finally {
      if (identical(_pendingAttempt, attempt)) _pendingAttempt = null;
    }
  }

  /// Opens the tab for [attempt] at the start route [start], checks its return
  /// and exchanges its code.
  Future<ProviderSignInOutcome> _runProviderSignIn(
    ProviderSignInAttempt attempt,
    Uri start,
  ) async {
    final url = start.replace(
      queryParameters: {
        ...start.queryParameters,
        'provider': attempt.providerId,
        'redirect_uri': appSignInReturnAddress,
        'code_challenge': codeChallengeS256(attempt.codeVerifier),
        'code_challenge_method': 'S256',
        'state': attempt.state,
      },
    );

    final Uri? returned;
    try {
      returned = await _providerBrowser.authenticate(
        url: url,
        callbackScheme: appSignInCallbackScheme,
      );
    } on AuthException {
      // A replaced attempt ends quietly, even when its tab failed.
      _requirePendingAttempt(attempt);
      rethrow;
    } on Object catch (error, stackTrace) {
      _requirePendingAttempt(attempt);
      // The seam promises an AuthProviderSignInException; anything else is
      // wrapped, so nothing raw leaves an auth method (#181).
      Error.throwWithStackTrace(
        AuthProviderSignInException(
          ProviderSignInFailureReason.generic,
          message: 'The in-app browser tab failed.',
          cause: error,
        ),
        stackTrace,
      );
    }

    _requirePendingAttempt(attempt);

    if (returned == null) return const ProviderSignInCancelled();

    final failedCheck = _failedReturnCheck(returned, attempt);
    if (failedCheck != null) {
      _log.warn(
        'Refusing a provider sign-in return that failed a check',
        context: {'check': failedCheck},
      );
      throw const AuthProviderSignInException(
        ProviderSignInFailureReason.generic,
        message: 'The provider sign-in return failed a check.',
      );
    }

    final query = returned.queryParameters;

    // Mapped by the code alone. `error_description` is optional, comes in the
    // server's fallback locale, and is never shown or logged.
    final error = query['error'];
    if (error != null) {
      _log.warn(
        'The provider sign-in came back with an error',
        context: {'code': error},
      );
      throw AuthProviderSignInException(
        ProviderSignInFailureReason.forCode(error),
        code: error,
      );
    }

    final code = query['code'];
    if (code == null || code.isEmpty) {
      _log.warn(
        'Refusing a provider sign-in return that failed a check',
        context: {'check': 'code'},
      );
      throw const AuthProviderSignInException(
        ProviderSignInFailureReason.generic,
        message: 'The provider sign-in return carried no code.',
      );
    }

    return ProviderSignInCompleted(await _exchangeProviderCode(attempt, code));
  }

  /// The name of the first check [returned] fails for [attempt], or null when
  /// it passes them all. Only the name is ever logged, never the address, its
  /// `state` or its code.
  ///
  /// Runs before `error` is read. The server echoes the app's `state` on
  /// every return it sends, failures included, so an error return that fails
  /// these is not this attempt's to report.
  ///
  /// A query that does not decode, such as one holding `%FF`, which is not
  /// UTF-8, fails the `query` check. Read raw, its `FormatException` would
  /// leave the auth method unmodelled and strand the caller on its loading
  /// state (#181). Once this passes, the query decodes for the reads after it.
  static String? _failedReturnCheck(
    Uri returned,
    ProviderSignInAttempt attempt,
  ) {
    if (returned.scheme.toLowerCase() != appSignInCallbackScheme ||
        returned.host.toLowerCase() != appSignInReturnHost) {
      return 'return_address';
    }

    final Map<String, String> query;
    try {
      query = returned.queryParameters;
    } on FormatException {
      return 'query';
    }
    if (query['state'] != attempt.state) return 'state';

    // RFC 9207 section 2.4: compared with the address this attempt was
    // started against, never with an issuer some other response supplied.
    final iss = query['iss'];
    if (iss == null || !isSameServerAddress(iss, attempt.issuerAddress)) {
      return 'iss';
    }

    return null;
  }

  /// Exchanges [code] at the token route [attempt] recorded and adopts the
  /// grant the way a password sign-in does.
  Future<AuthResponse> _exchangeProviderCode(
    ProviderSignInAttempt attempt,
    String code,
  ) async {
    late final Response<String> response;
    try {
      // Absolute, so the Dio's base URL plays no part: the recorded route is
      // the only one this code goes to.
      response = await _dio.postUri<String>(
        attempt.tokenEndpoint,
        data: {'code': code, 'code_verifier': attempt.codeVerifier},
        options: _plainBody,
      );
    } on DioException catch (e) {
      _requirePendingAttempt(attempt);
      // A thrown rejection (an injected Dio that throws on a non-2xx) is
      // worded the same as a resolved one.
      throw _tokenRouteRefusal(e.response?.statusCode, e.response?.data) ??
          _mapDioException(e, credentialGrant: true);
    }

    // The answer may land after the attempt was replaced or its server scope
    // closed. Either way the grant is not this repository's to adopt.
    _requirePendingAttempt(attempt);

    final refusal = _tokenRouteRefusal(response.statusCode, response.data);
    if (refusal != null) throw refusal;

    final body = await _requireGrantBody(
      response,
      context: _providerSignInContext,
    );

    // Again after the decode, which can suspend on a large body.
    _requirePendingAttempt(attempt);

    return _finalizeCredentialGrant(
      _parseGrant(
        body,
        context: _providerSignInContext,
        status: response.statusCode,
      ),
      context: _providerSignInContext,
    );
  }

  static const String _providerSignInContext = 'provider sign-in';

  /// A refusal from the token route that names its reason: a 4xx other than a
  /// 429 whose envelope carries a `code`, read under the same bound as every
  /// other rejection envelope. A code outside
  /// [ProviderSignInFailureReason.forCode]'s table, `BANNED_USER` among them,
  /// is the generic refusal.
  ///
  /// Null for anything else, which is classified as every credential grant
  /// is: a 429 is a rate limit whatever its body says (#559), and a 5xx or a
  /// rejection with no readable code is not a refusal the provider flow can
  /// word.
  AuthProviderSignInException? _tokenRouteRefusal(int? status, Object? body) {
    if (status == null ||
        status == HttpStatusCode.tooManyRequests ||
        status < HttpStatusCode.badRequest ||
        status >= HttpStatusCode.internalServerError) {
      return null;
    }

    final code = _rejectionCode(body);
    if (code == null) return null;

    _log.warn(
      'The server refused the provider sign-in code',
      context: {'code': code, 'status': status},
    );
    return AuthProviderSignInException(
      ProviderSignInFailureReason.forCode(code),
      code: code,
    );
  }

  /// Throws [AuthSupersededException] unless [attempt] is still the one this
  /// repository holds: a newer attempt replaced it, or [onDispose] dropped it
  /// when its server scope closed.
  void _requirePendingAttempt(ProviderSignInAttempt attempt) {
    if (identical(_pendingAttempt, attempt)) return;

    _log.info(
      'Discarding a provider sign-in that was replaced or whose server '
      'scope closed',
    );
    throw const AuthSupersededException(
      message:
          'The provider sign-in was replaced by a newer attempt, or its '
          'server was closed.',
    );
  }

  @override
  ProviderSignInAvailability get providerSignInAvailability {
    if (!_providerBrowser.isSupported) {
      return const ProviderSignInUnsupportedDevice();
    }

    // RFC 8414 section 3.3, checked for provider sign-in only, so a server
    // reached under another address still offers email sign-in.
    if (!isSameServerAddress(_identity.issuer, _serverUrl)) {
      return ProviderSignInAddressMismatch(_identity.issuer);
    }

    return const ProviderSignInAvailable();
  }

  /// Always null: a native return reaches [signInWithProvider] directly.
  @override
  AuthProviderSignInException? takeProviderSignInReturn() => null;

  @override
  Stream<AuthState> watchAuthState() {
    return replayThenForward(
      current: () => _currentState,
      updates: () => _stateController.stream,
    );
  }

  void _setState(AuthState next) {
    _currentState = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  EmailAndPasswordStrategy _requireEmailPasswordStrategy() {
    final strategy = _identity.emailAndPasswordStrategy;
    if (strategy == null) {
      // A cached ServerIdentity lacking an email/password strategy is a
      // server-side contract problem (its well-known advertised no such
      // strategy), surfaced BEFORE any HTTP call — so neither the network
      // interceptor nor the bloc has the context to log it. Log here.
      _log.error(
        'Email/password strategy missing on cached identity',
        context: {
          // Redacted (userInfo/query/fragment stripped) — the auth
          // diagnostics never log raw URLs (PR #103 review).
          'base_url': redactUri(Uri.tryParse(_dio.options.baseUrl) ?? Uri()),
          'has_strategies': _identity.strategies.isNotEmpty,
          'strategy_count': _identity.strategies.length,
        },
      );
      throw const AuthServerException(
        message: 'This server does not support email/password authentication.',
      );
    }

    return strategy;
  }

  /// Clears the stored material and settles on unauthenticated, for a session
  /// the **server** has definitively disowned.
  Future<AuthResponse?> _settleNoSession({
    required int? status,
    required Uri uri,
  }) async {
    _log.warn(
      'Stored session rejected; clearing session material',
      context: {'uri': redactUri(uri), 'status': status},
    );
    await _clearQuietly('a rejected session');
    _setState(const AuthStateUnauthenticated());
    return null;
  }

  /// [TokenStorageService.clear] with a platform fault contained (#181).
  ///
  /// Unguarded, a keychain fault leaves `getSession` as a raw
  /// `PlatformException` — which slips past every `on AuthException` clause in
  /// `AuthBloc` exactly as an unwrapped parse error does, and strands the
  /// caller with an uncategorised failure.
  ///
  /// Contained rather than rethrown, which is where this deliberately differs
  /// from [signOut]'s `AuthSignOutPersistenceException`. There the user asked
  /// to sign out, so a failed persist IS the answer to their question. Here
  /// the caller asked whether a session exists and the answer — no — is
  /// already settled by the server's rejection; throwing instead would move
  /// the user off the unauthenticated state this is in the middle of
  /// establishing, over a fault that changes nothing about the answer.
  ///
  /// Contained safely **for this process**: `TokenStorageService.clear()` sets
  /// its sign-out latch SYNCHRONOUSLY, before the delete that failed, so
  /// `retrieve()` — and therefore the `TokenInterceptor` and any same-process
  /// `getSession` — already report nothing stored.
  ///
  /// Contained across a restart as well: `clear()` writes a durable marker
  /// ahead of the delete, so the next cold start refuses a payload that
  /// survived and retries the delete (#356). If that marker could not be
  /// written either, the payload is still there for a fresh instance to read,
  /// and `restoreCachedSession` may adopt it offline.
  /// `AuthRepository.getSession` states that remaining case, and the log
  /// records are its only trace.
  ///
  /// A typed throw is not available for that double fault:
  /// `_finalizeCredentialGrant`'s `on AuthException` catch would read it as an
  /// indeterminate reconcile and keep a session the server just disowned.
  Future<void> _clearQuietly(String what) async {
    try {
      await _tokenStorage.clear();
    } on Object catch (error, stackTrace) {
      _log.warn(
        'Could not clear session material after $what; the sign-out latch '
        'keeps it unreadable in this process, and its marker, if written, '
        'refuses it at the next cold start',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Decodes a body the transport was told not to touch, **deferring** the
  /// failure so the status can speak first.
  ///
  /// Every request here asks Dio for `Response<String>` **and pins
  /// `responseType` per request** — together, not either alone.
  /// `DioMixin.fetch` forces `responseType` from `T`, so `String` gives
  /// `plain` and anything else gives `json`
  /// (`dio-5.11.0/lib/src/dio_mixin.dart:419-427`) — but it skips that forcing
  /// entirely for an instance already set to `bytes` or `stream` (`:419-421`),
  /// and this class takes an arbitrary `Dio` by constructor. The pin is what
  /// makes the rule true here rather than only for the Dio the factories build
  /// (see `_plainBody`). Either half of Dio's own handling — the cast, or a
  /// `jsonDecode` driven by a content type that merely *claims* JSON —
  /// throws from inside the call as
  /// `DioException(type: unknown)` with **no response attached**. The status
  /// was gone before anything could classify it, so every such answer became
  /// `AuthNetworkException`: the INDETERMINATE bucket, which keeps a dead
  /// session on the retry-forever view with no way out (#352).
  ///
  /// The failure is **returned, not thrown**, because the two callers disagree
  /// about what it means. A rejected response whose body will not parse is
  /// still a rejection and its status is the honest answer — the
  /// duplicate-email probe simply finds no envelope there. Only a 2xx has to
  /// answer for an unreadable body.
  ///
  /// Which failure it was decides the bucket, and that distinction matters
  /// more here than anywhere else in the client. A body that is not JSON is a
  /// statement *about the response* and is definitive. A failure to **perform**
  /// the decode — an isolate that would not spawn — is local and momentary and
  /// must stay retryable: filing it as definitive would clear the user's
  /// credentials over a fault the server had no part in.
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
  /// body.
  Future<Map<String, dynamic>> _requireGrantBody(
    Response<String> response, {
    required String context,
  }) async {
    final status = response.statusCode;

    // A REJECTION is settled from the status plus a bounded read of the raw
    // body, and never a full decode. The only thing wanted from a rejected
    // body is its envelope's code (a duplicate email, or why a 403 refused),
    // which [_rejectionCode] reads through [probeJsonBody] when handed a
    // `String`. Decoding first would pay an isolate spawn and a full parse on
    // a 2 MB proxy error page about to be thrown away on its status — and
    // would answer the code question differently from `_mapDioException`,
    // which has always been bounded. Two paths, one question, one bound.
    //
    // `_assertSuccess` never returns for a non-2xx, so this settles every
    // rejection before anything expensive happens.
    if (status == null ||
        status < HttpStatusCode.ok ||
        status >= HttpStatusCode.multipleChoices) {
      _assertSuccess(
        status,
        response.data,
        headers: response.headers,
        context: context,
      );
    }

    // A 2xx: the body IS the payload, so it earns a real decode.
    final decoded = await _decodeBody(
      response.data,
      context: context,
      status: status,
    );

    // Re-run on the decoded body. The duplicate-email envelope is not
    // status-gated, so a 2xx can carry it too — and here the decode has
    // already happened, so the check is free.
    _assertSuccess(
      status,
      decoded.value,
      headers: response.headers,
      context: context,
    );

    // An unreadable body on a 2xx fails the grant: as a server fault when it
    // is not JSON, and as a local one when this device could not run the
    // decode (#357).
    final failure = decoded.failure;
    if (failure != null) throw failure;

    final body = decoded.value;
    if (body == null) {
      throw AuthServerException(
        message: 'Empty response body during $context.',
        statusCode: status,
      );
    }
    if (body is! Map<String, dynamic>) {
      throw AuthServerException(
        message:
            'The server returned a body that is not a JSON object during '
            '$context.',
        statusCode: status,
      );
    }
    return body;
  }

  /// Wraps `AuthResponse.fromJson` so a well-formed body whose **fields** are
  /// wrong cannot escape as a raw `TypeError` (#181).
  ///
  /// `AuthBloc`'s sign-in and register handlers catch `AuthException` and
  /// nothing wider, so a bare parse error slips past every clause and strands
  /// the form on `AuthLoading` with no way back. Every sibling transport —
  /// well-known, household, feedback — already upholds this rule; auth was the
  /// one hole in it.
  AuthResponse _parseGrant(
    Map<String, dynamic> body, {
    required String context,
    required int? status,
  }) {
    try {
      return AuthResponse.fromJson(body);
    } on Object catch (error) {
      throw AuthServerException(
        message: 'The server returned an unreadable $context response.',
        statusCode: status,
        cause: error,
      );
    }
  }

  void _assertSuccess(
    int? status,
    Object? body, {
    required Headers? headers,
    required String context,
  }) {
    if (status == HttpStatusCode.unauthorized) {
      throw const AuthInvalidCredentialsException();
    }

    if (status == HttpStatusCode.forbidden) throw _forbidden(body);

    // A 429 is a rate limit whatever its body says (#559): classified on the
    // status alone, with the wait read from `X-Retry-After` when it is there.
    // It sits before the duplicate-email check, which reads a body code at any
    // status, and before the generic non-2xx throw, which would file it as a
    // server fault with nothing to act on.
    if (status == HttpStatusCode.tooManyRequests) {
      throw rateLimitedFrom(headers);
    }

    if (_isEmailAlreadyExists(status, body)) {
      throw const AuthEmailAlreadyExistsException();
    }

    if (status == null ||
        status < HttpStatusCode.ok ||
        status >= HttpStatusCode.multipleChoices) {
      throw AuthServerException(
        message: 'Unexpected $status during $context.',
        statusCode: status,
      );
    }
  }

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
  bool _isEmailAlreadyExists(int? status, Object? body) {
    if (status == HttpStatusCode.conflict) return true;
    final code = _rejectionCode(body);
    return code != null && code.startsWith('USER_ALREADY_EXISTS');
  }

  /// What a 403 on a credential grant means, read by its body code (#394).
  ///
  /// BetterAuth answers two refusals with a 403 that are not a wrong
  /// password: `EMAIL_NOT_VERIFIED` on sign-in, after the password check has
  /// passed, and `REGISTRATION_DISABLED` from the `/sign-up/email` route gate
  /// once the server has closed registration (#443). Each code comes from one
  /// route only, so the code decides, not which grant made the request.
  ///
  /// The code is read under the same bound as the duplicate-email envelope.
  /// The status still decides first: only a 403 gets here, and the body only
  /// refines it. A 403 without a readable envelope (a proxy's HTML page, an
  /// envelope past [probeJsonMaxChars], no body at all) stays the invalid
  /// credentials it always was.
  AuthException _forbidden(Object? body) => switch (_rejectionCode(body)) {
    'EMAIL_NOT_VERIFIED' => const AuthEmailNotVerifiedException(),
    'REGISTRATION_DISABLED' => const AuthRegistrationDisabledException(),
    _ => const AuthInvalidCredentialsException(),
  };

  /// The `code` of a rejection envelope, or null when [body] is not one.
  ///
  /// [body] is the raw text, or a body [_requireGrantBody] has already
  /// decoded; both go through [probeJsonBody]. [_mapDioException] reads the
  /// raw text off a **thrown** `DioException` too: without the probe, a
  /// duplicate sign-up rejected by a `Dio` whose `validateStatus` is not
  /// `DefaultDioFactory`'s would report "unexpected 422" instead of "that
  /// account already exists".
  ///
  /// It probes rather than decodes because a rejection envelope is small, and
  /// `decodeJsonBody`'s isolate hop would make this async for nothing.
  String? _rejectionCode(Object? body) {
    final decoded = probeJsonBody(body);
    final code = decoded is Map ? decoded['code'] : null;
    return code is String ? code : null;
  }

  /// [credentialGrant] gates the body probes, the duplicate-email one and a
  /// 403's code, which are meaningful only where an account is being created
  /// or a credential presented.
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
    // The wire-level failure itself is logged by NetworkLogInterceptor
    // (redacted URI + dio_error_type + status); here we only map it to the
    // domain exception the bloc will categorise (#100 layering).
    final status = e.response?.statusCode;
    if (status == HttpStatusCode.unauthorized) {
      return const AuthInvalidCredentialsException();
    }

    // `getSession` settles a session 403 before it gets here, whatever its
    // body says, so only a grant's body is read.
    if (status == HttpStatusCode.forbidden) {
      return credentialGrant
          ? _forbidden(e.response?.data)
          : const AuthInvalidCredentialsException();
    }

    // Only a credential grant's 429 is a rate-limited grant (#559); a session
    // read that is throttled stays what it was. Ahead of the duplicate-email
    // check, as in [_assertSuccess].
    if (credentialGrant && status == HttpStatusCode.tooManyRequests) {
      return rateLimitedFrom(e.response?.headers);
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

    // The server answered, with something the branches above did not claim —
    // a 404 from a misrouted path, a 400 or 422 it rejected. That is a server
    // fault, and calling it a network one told the user to check the one part
    // of the system demonstrably working (#283). Reachable when the injected
    // `Dio`'s `validateStatus` is not this factory's permissive default, which
    // this class accepts by design.
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

  /// Tears down auth-state streaming and drops any provider sign-in still in
  /// flight. Does not close the injected [Dio] — that is a shared per-server
  /// resource owned and disposed by the container.
  @override
  Future<void> onDispose() async {
    // Before the await: a tab or token answer for this server that lands
    // while the stream closes must already find no attempt to adopt (#583).
    _pendingAttempt = null;
    await _stateController.close();
  }
}
