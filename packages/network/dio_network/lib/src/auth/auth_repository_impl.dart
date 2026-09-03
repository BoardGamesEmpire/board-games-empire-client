import 'dart:async';
import 'dart:convert';

import 'package:di/di.dart' show LocalClockService;
import 'package:http_status/http_status.dart';
import 'package:dio/dio.dart';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart' show ClockService;
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:observability/observability.dart';

import '../network/decode_json_body.dart';
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
    required this._identity,
    required this._tokenStorage,
    required this._dio,
    this._clock = const LocalClockService(),
    this._deviceNowUtc = _systemDeviceNowUtc,
  }) : _stateController = StreamController<AuthState>.broadcast(sync: true);

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

    late final Response<String> response;
    try {
      response = await _dio.post<String>(
        strategy.signInEndpoint,
        data: {'email': email, 'password': password},
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
    final token = granted.token;
    if (token == null) {
      throw AuthServerException(
        message:
            'The server accepted the $context but granted no session token.',
      );
    }

    // Captured before the first await, like getSession's own capture: every
    // suspension in this method (the store, the reconcile) is a window a
    // sign-out can land in, and each outcome below must be able to tell
    // "the server misbehaved" apart from "the user left" (#146).
    final epoch = _sessionEpoch;

    await _tokenStorage.store(
      token: token,
      expiresAt: null,
      persistedAt: _deviceNowUtc(),
      user: granted.user,
    );

    // A sign-out during the grant store: our write lifted its latch and
    // re-persisted the snapshot. Undo it and report supersession — the
    // sign-in genuinely succeeded server-side, but locally the sign-out is
    // the newer intent and must win.
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
      response = await _dio.get<String>(_identity.sessionEndpoint);
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
      // now classifies by status rather than as transport (#283). And until
      // this request asked for `Response<String>`, Dio owned the body: a
      // cast or a `jsonDecode` it drove itself threw from inside the call,
      // arriving here as `DioException(type: unknown)` with no response — so
      // a captive portal's HTML reached the user as "can't reach the
      // server" with the dead session still on disk.
      final mapped = _mapDioException(e, credentialGrant: false);

      // A thrown 401/403 is the SAME definitive negative the response path
      // settles below, and it has to settle the same way. Rethrowing it left
      // the dead token on disk for the `TokenInterceptor` and the auth state
      // wherever it stood — and, reaching `_finalizeCredentialGrant` as an
      // exception, its `on AuthException` catch bucketed this definitive
      // rejection as INDETERMINATE and kept a session the server had just
      // disowned. That method's own contract already promises the opposite:
      // "the token has already been cleared by getSession". It was not.
      //
      // Web locked this call in #180 for the same reason; native kept the
      // gap because its permissive `validateStatus` normally resolves a 401
      // as a Response, and only an injected Dio — which this class accepts
      // by design — throws one.
      if (mapped is AuthInvalidCredentialsException) {
        if (epoch != _sessionEpoch) {
          _log.warn(
            'Discarding a rejected session response that resolved after '
            'sign-out',
          );
          return null;
        }
        return _settleNoSession(
          status: e.response?.statusCode,
          uri: e.requestOptions.uri,
        );
      }

      throw mapped;
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
    // BetterAuth's 200-with-no-body — which is how it reports an absent or
    // expired session rather than using a status code. All mean the stored
    // material is dead: clear it and settle on unauthenticated.
    //
    // Two of the three are decidable from the status alone and are taken
    // here. The third needs the body and so waits until after the decode
    // below — which is a reordering #352 forced and not a change of rule:
    // the body no longer arrives pre-decoded, and reading "no session" off
    // an undecoded string would call a captive portal's HTML page a rejected
    // session and clear the user's credentials over it.
    //
    // 403 belongs here, not in the indeterminate bucket below. The
    // per-server Dio sets `validateStatus: (_) => true`, so a 403 resolves
    // as a Response and never reaches `_mapDioException` — the path that
    // maps 403 to `AuthInvalidCredentialsException`. Classifying it as
    // indeterminate would strand a genuinely revoked session on the
    // retry-forever view with the dead material still on disk, and the user
    // has no way out of that loop. A false positive from an intermediary
    // costs one re-sign-in, which is the cheaper failure.
    if (status == HttpStatusCode.unauthorized ||
        status == HttpStatusCode.forbidden) {
      return _settleNoSession(status: status, uri: response.requestOptions.uri);
    }

    // Anything else is INDETERMINATE and must throw, not return null (#98).
    // The previous `return null` here made a 5xx during startup restore
    // indistinguishable from "no session", so a transient server fault sent
    // the user to the sign-in form and implied their stored session had been
    // rejected — the exact failure mode #37's design set out to avoid, and
    // the one #98's optimistic fallback depends on being able to detect.
    // `WebAuthRepositoryImpl.getSession` throws here too — though not until
    // #180: when this comment was first written web was asserted to "already"
    // throw and in fact did not, returning null for any non-2xx that carried
    // no body. Both implementations agree now; do not weaken either half
    // without the other.
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

    // The third "definitively no session" shape, now that the body is
    // readable: BetterAuth answers 200 with no session payload. An empty
    // body and a literal JSON `null` both land here as null, which is
    // exactly what `Response<Map<String, dynamic>>` used to hand over as
    // `data == null`.
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

    // Second epoch check, covering the store await itself: a signOut()
    // landing DURING that write is otherwise undone by it — store lifts the
    // sign-out latch and re-persists the PII snapshot, and the emit below
    // would re-assert the session. Undo our own write (restoring the latch)
    // and stand down; the sign-out's teardown is the newer intent.
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
      // `String` for the same reason as every other request here: any other
      // type argument selects `ResponseType.json` and has Dio decode a body
      // nothing reads. Cosmetic on this path — the catch below discards every
      // outcome — but leaving one call site on the old rule is how the rule
      // gets forgotten.
      await _dio.post<String>(
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
  /// It is NOT gone at the next cold start, and an earlier version of this
  /// comment said it was. That latch is in-memory and unpersisted
  /// (`token_storage_service.dart:55-71`), and `retrieve()` only self-heals a
  /// payload it cannot *decode* — a well-formed one that survived a failed
  /// delete is read again by a fresh instance, where `restoreCachedSession`
  /// may adopt it offline. That residual predates this method: the unguarded
  /// `clear()` left exactly the same bytes on disk and merely failed loudly
  /// while doing it.
  ///
  /// What containment does newly cost is candour. `AuthRepository.getSession`
  /// promises that a null for a definitive negative means "the stored session
  /// material is cleared" (`auth_repository.dart:39-41`), and on this path
  /// that promise cannot be kept when the delete throws. The log record is
  /// currently the only trace. Neither of the honest repairs is free — a typed
  /// throw here would let `_finalizeCredentialGrant`'s `on AuthException`
  /// catch keep a session the server just disowned, and a durable tombstone is
  /// a `TokenStorageService` change that also fixes the pre-existing residual
  /// above — so the choice is deliberately left open rather than guessed at.
  Future<void> _clearQuietly(String what) async {
    try {
      await _tokenStorage.clear();
    } on Object catch (error, stackTrace) {
      _log.warn(
        'Could not clear session material after $what; the sign-out latch '
        'keeps it unreadable until the next cold start',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Decodes a body the transport was told not to touch, **deferring** the
  /// failure so the status can speak first.
  ///
  /// Every request here asks Dio for `Response<String>`, the only type
  /// argument that keeps Dio out of the body: `DioMixin.fetch` forces
  /// `responseType` from `T` — `String` gives `plain`, and anything else gives
  /// `json` (`dio-5.11.0/lib/src/dio_mixin.dart:417-427`). Either half of
  /// Dio's own handling — the cast, or a `jsonDecode` driven by a content type
  /// that merely *claims* JSON — throws from inside the call as
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
      return (value: await decodeJsonBody(raw), failure: null);
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
        failure: AuthNetworkException(
          message: 'Could not decode the response during $context.',
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
    // body is the duplicate-email envelope, which `_isEmailAlreadyExists`
    // reads through [_probeJson] when handed a `String`. Decoding first would
    // pay an isolate spawn and a full parse on a 2 MB proxy error page about
    // to be thrown away on its status — and would answer the duplicate-email
    // question differently from `_mapDioException`, which has always been
    // bounded. Two paths, one question, one bound.
    //
    // `_assertSuccess` never returns for a non-2xx, so this settles every
    // rejection before anything expensive happens.
    if (status == null ||
        status < HttpStatusCode.ok ||
        status >= HttpStatusCode.multipleChoices) {
      _assertSuccess(status, response.data, context: context);
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
    _assertSuccess(status, decoded.value, context: context);

    // An unreadable body on a 2xx is the server's to answer for.
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

  void _assertSuccess(int? status, Object? body, {required String context}) {
    if (status == HttpStatusCode.unauthorized ||
        status == HttpStatusCode.forbidden) {
      throw const AuthInvalidCredentialsException();
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
  /// hundred bytes — BetterAuth's is about a hundred — so anything past this
  /// is not the envelope being looked for, and reading it would be paying
  /// main-isolate parse time for a body that cannot answer the question.
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
  /// sign-up rejected by a `Dio` whose `validateStatus` is not this factory's
  /// would report "unexpected 422" instead of "that account already exists".
  ///
  /// Deliberately not routed through `decodeJsonBody`: this reads a rejection
  /// envelope, which is small, and the probe is best-effort — a body that will
  /// not parse simply is not this envelope. `decodeJsonBody`'s 50 KB isolate
  /// offload exists for success-path payloads and would make this async for no
  /// benefit.
  ///
  /// Bounded by [_probeMaxChars], because this runs SYNCHRONOUSLY on the UI
  /// isolate. Taking the body as a `String` dropped dio's
  /// `BackgroundTransformer`, which used to offload a decode above 50 KB; a
  /// bound restores that protection the only way a synchronous probe can.
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
    // The wire-level failure itself is logged by NetworkLogInterceptor
    // (redacted URI + dio_error_type + status); here we only map it to the
    // domain exception the bloc will categorise (#100 layering).
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

  /// Tears down auth-state streaming. Does not close the injected [Dio] — that
  /// is a shared per-server resource owned and disposed by the container.
  @override
  Future<void> onDispose() async {
    await _stateController.close();
  }
}
