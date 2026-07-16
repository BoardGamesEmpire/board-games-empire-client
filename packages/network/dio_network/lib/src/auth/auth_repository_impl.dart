// packages/network/dio_network/lib/src/auth/auth_repository_impl.dart
import 'dart:async';
import 'package:http_status/http_status.dart';
import 'package:dio/dio.dart';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
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
class AuthRepositoryImpl implements AuthRepository, Disposable {
  AuthRepositoryImpl({
    required ServerIdentity identity,
    required TokenStorageService tokenStorage,
    required Dio dio,
  }) : _identity = identity,
       _tokenStorage = tokenStorage,
       _dio = dio,
       _stateController = StreamController<AuthState>.broadcast(sync: true);

  final ServerIdentity _identity;
  final TokenStorageService _tokenStorage;
  final Dio _dio;
  final StreamController<AuthState> _stateController;

  AuthState _currentState = const AuthStateUnknown();

  /// TEMP (#101, removed by #100): diagnostic logger for the auth seams.
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

    final auth = AuthResponse.fromJson(response.data!);
    await _tokenStorage.store(
      token: auth.token,
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
    );

    final session = await getSession() ?? auth;

    _setState(AuthStateAuthenticated(session: session));
    return session;
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

    final auth = AuthResponse.fromJson(response.data!);
    await _tokenStorage.store(
      token: auth.token,
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
    );

    final session = await getSession() ?? auth;

    _setState(AuthStateAuthenticated(session: session));
    return session;
  }

  @override
  Future<AuthResponse?> getSession() async {
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
      if (e.response?.statusCode == HttpStatusCode.unauthorized) {
        await _tokenStorage.clear();

        _setState(const AuthStateUnauthenticated());
        return null;
      }

      throw _mapDioException(e);
    }

    if (response.statusCode == HttpStatusCode.unauthorized) {
      await _tokenStorage.clear();

      _setState(const AuthStateUnauthenticated());
      return null;
    }

    if (response.statusCode != HttpStatusCode.ok || response.data == null) {
      return null;
    }

    final sessionResponse = BgeSessionResponse.fromJson(response.data!);
    await _tokenStorage.store(
      token: stored.token,
      expiresAt: sessionResponse.session.expiresAt,
    );

    final auth = AuthResponse(
      token: stored.token,
      user: sessionResponse.user,
      expiresAt: sessionResponse.session.expiresAt,
    );

    _setState(AuthStateAuthenticated(session: auth));
    return auth;
  }

  @override
  Future<void> signOut() async {
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
      // The persisted token could not be cleared. Rethrow as the typed,
      // contract-covered exception (stack preserved). The `finally` runs
      // before it propagates, so callers and the state stream observe the
      // unauthenticated transition FIRST. TokenStorageService.clear() sets
      // its sign-out latch BEFORE the failing delete, so retrieve() — and
      // therefore the TokenInterceptor's Authorization header and any
      // same-process getSession() — already report no token: a surviving
      // token can be resurrected neither at the HTTP layer nor in state
      // (PR #99 review). It is cleared for good on the next cold start.
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
    if (stored == null || stored.isExpired) {
      return null;
    }

    if (_currentState case AuthStateAuthenticated(:final session)) {
      return session;
    }

    return null;
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
      // TEMP (#101): strategy resolution is a pre-wire failure origin.
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
    // TEMP (#101): a response reached us — record how it resolved.
    _log.debug(
      'Auth response received',
      context: {
        'context': context,
        'status': status,
        // Redacted: uri.toString() would carry query/fragment/userInfo, which
        // must never be logged on auth endpoints (PR #103 review).
        'uri': redactUri(response.requestOptions.uri),
        'has_body': response.data != null,
      },
    );
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
    final status = e.response?.statusCode;
    // TEMP (#101): a Dio-level failure — the "no connection" vs "rejected"
    // discriminator. dio_error_type=connectionError with no status ⇒ the
    // request never reached the server.
    _log.error(
      'Auth Dio exception',
      // Log the underlying transport error, NOT the DioException: the latter
      // carries RequestOptions (headers incl. the bearer token, and body) that
      // a verbose formatter/sink could serialise. Failure kind is in
      // dio_error_type; the redacted uri gives the endpoint (PR #103 review).
      error: e.error,
      stackTrace: e.stackTrace,
      context: {
        'uri': redactUri(e.requestOptions.uri),
        'dio_error_type': e.type.name,
        'status': status,
      },
    );
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
