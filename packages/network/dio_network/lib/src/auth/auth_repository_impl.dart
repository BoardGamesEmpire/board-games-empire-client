import 'dart:async';
import 'package:di/di.dart' show LocalClockService;
import 'package:http_status/http_status.dart';
import 'package:dio/dio.dart';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart' show ClockService;
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:observability/observability.dart';

import '../network/redact_uri.dart';
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
/// auth-state stream.
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
    required ServerIdentity identity,
    required TokenStorageService tokenStorage,
    required Dio dio,
    ClockService clock = const LocalClockService(),
    DateTime Function() deviceNowUtc = _systemDeviceNowUtc,
  }) : _identity = identity,
       _tokenStorage = tokenStorage,
       _dio = dio,
       _clock = clock,
       _deviceNowUtc = deviceNowUtc,
       _stateController = StreamController<AuthState>.broadcast(sync: true);

  static DateTime _systemDeviceNowUtc() => DateTime.now().toUtc();

  final ServerIdentity _identity;
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

    return _finalizeCredentialGrant(
      AuthResponse.fromJson(response.data!),
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

    return _finalizeCredentialGrant(
      AuthResponse.fromJson(response.data!),
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
  /// - reconcile is **indeterminate** (transport failure, 5xx) → keep the
  ///   granted session. Authentication genuinely happened; failing the
  ///   sign-in here would show "connection failed" for a sign-in that
  ///   worked, and would leave a valid token stored under a state that
  ///   says otherwise. The cost is an unconfirmed expiry, which only
  ///   forfeits offline restore until the next successful `getSession`.
  /// - reconcile returns a **definitive** "no session" → the server
  ///   accepted the credentials and then disowned the session. That is a
  ///   server contract violation, not a network condition, and it must not
  ///   be reported as success: the token has already been cleared by
  ///   `getSession`, so a "signed in" state here would 401 on every
  ///   subsequent request. Matches `WebAuthRepositoryImpl.signUp`.
  Future<AuthResponse> _finalizeCredentialGrant(
    AuthResponse granted, {
    required String context,
  }) async {
    // Captured before the first await, like getSession's own capture: every
    // suspension in this method (the store, the reconcile) is a window a
    // sign-out can land in, and each outcome below must be able to tell
    // "the server misbehaved" apart from "the user left" (#146).
    final epoch = _sessionEpoch;

    await _tokenStorage.store(
      token: granted.token,
      expiresAt: null,
      persistedAt: _deviceNowUtc(),
      user: granted.user,
    );

    // A sign-out during the grant store: our write lifted its latch and
    // re-persisted the snapshot. Undo it and report supersession — the
    // sign-in genuinely succeeded server-side, but locally the sign-out is
    // the newer intent and must win.
    if (epoch != _sessionEpoch) {
      await _tokenStorage.clear();
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

    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.get<Map<String, dynamic>>(
        _identity.sessionEndpoint,
      );
    } on DioException catch (e) {
      // A rejected session (401) arrives as a Response, not a thrown
      // DioException — the per-server Dio sets validateStatus:(_)=>true, so
      // any HTTP status resolves normally and is handled on the response
      // path below. Reaching here means a transport-level failure (no/failed
      // connection, timeout); NetworkLogInterceptor logs it — map it.
      throw _mapDioException(e);
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

    // Three shapes of "definitively no session": an explicit 401, a 403, and
    // BetterAuth's 200-with-null-body — which is how it reports an absent or
    // expired session rather than using a status code. All mean the stored
    // material is dead: clear it and settle on unauthenticated.
    //
    // 403 belongs here, not in the indeterminate bucket below. The
    // per-server Dio sets `validateStatus: (_) => true`, so a 403 resolves
    // as a Response and never reaches `_mapDioException` — the path that
    // maps 403 to `AuthInvalidCredentialsException`. Classifying it as
    // indeterminate would strand a genuinely revoked session on the
    // retry-forever view with the dead material still on disk, and the user
    // has no way out of that loop. A false positive from an intermediary
    // costs one re-sign-in, which is the cheaper failure.
    final isDefinitiveNoSession =
        status == HttpStatusCode.unauthorized ||
        status == HttpStatusCode.forbidden ||
        (status == HttpStatusCode.ok && response.data == null);

    if (isDefinitiveNoSession) {
      _log.warn(
        'Stored session rejected; clearing session material',
        context: {
          'uri': redactUri(response.requestOptions.uri),
          'status': status,
        },
      );
      await _tokenStorage.clear();

      _setState(const AuthStateUnauthenticated());
      return null;
    }

    // Anything else is INDETERMINATE and must throw, not return null (#98).
    // The previous `return null` here made a 5xx during startup restore
    // indistinguishable from "no session", so a transient server fault sent
    // the user to the sign-in form and implied their stored session had been
    // rejected — the exact failure mode #37's design set out to avoid, and
    // the one #98's optimistic fallback depends on being able to detect.
    // `WebAuthRepositoryImpl.getSession` already throws here; this restores
    // parity.
    if (status != HttpStatusCode.ok) {
      throw AuthServerException(
        message: 'Unexpected $status from the session endpoint.',
        statusCode: status,
      );
    }

    final sessionResponse = BgeSessionResponse.fromJson(response.data!);

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

    // Second epoch check, covering the store await itself: a signOut()
    // landing DURING that write is otherwise undone by it — store lifts the
    // sign-out latch and re-persists the PII snapshot, and the emit below
    // would re-assert the session. Undo our own write (restoring the latch)
    // and stand down; the sign-out's teardown is the newer intent.
    if (epoch != _sessionEpoch) {
      _log.warn(
        'Sign-out landed while persisting a session response; re-clearing',
      );
      await _tokenStorage.clear();
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

    // Capture the bearer token BEFORE clearing. TokenStorageService.clear()
    // sets its sign-out latch synchronously, after which retrieve() — and so
    // the TokenInterceptor — reports no token; a POST left to the interceptor
    // would race that latch and go out with no Authorization header, leaving
    // the session un-revoked server-side. Reading it here lets the POST carry
    // the token explicitly (PR #103 review).
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
      // in state (PR #99 review). It is cleared for good on the next cold
      // start.
      Error.throwWithStackTrace(
        AuthSignOutPersistenceException(cause: error),
        stackTrace,
      );
    } finally {
      _setState(const AuthStateUnauthenticated());
    }
  }

  /// Fire-and-forget sign-out POST carrying [token] as an explicit bearer
  /// credential (the [TokenInterceptor] cannot be relied on here — see
  /// [signOut]). Never throws: a synchronous throw or an async rejection is
  /// swallowed (best-effort by design). Typed `Future<void>` so it satisfies
  /// [unawaited].
  Future<void> _bestEffortSignOutPost(String? token) async {
    try {
      await _dio.post<void>(
        _identity.signOutEndpoint,
        options: Options(
          headers: {if (token != null) 'Authorization': 'Bearer $token'},
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

    if (status == null ||
        status < HttpStatusCode.ok ||
        status >= HttpStatusCode.multipleChoices) {
      throw AuthServerException(
        message: 'Unexpected $status during $context.',
        statusCode: status,
      );
    }

    if (response.data == null) {
      throw AuthServerException(
        message: 'Empty response body during $context.',
        statusCode: status,
      );
    }
  }

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
    // The wire-level failure itself is logged by NetworkLogInterceptor
    // (redacted URI + dio_error_type + status); here we only map it to the
    // domain exception the bloc will categorise (#100 layering).
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
