import 'dart:async';
import 'package:http_status/http_status.dart';
import 'package:dio/dio.dart';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import '../network/token_interceptor.dart';
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
          'username': username,
          'first_name': ?firstName,
          'last_name': ?lastName,
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
    // Capture the token BEFORE latching. clear() below sets the sign-out
    // latch synchronously, ahead of TokenInterceptor's async retrieve() — so
    // if the best-effort POST relied on the interceptor it would be sent
    // WITHOUT an Authorization header, and the server could not revoke the
    // session. Passing the token explicitly keeps the request authenticated
    // regardless of latch timing (PR #99 review).
    //
    // Best-effort: a keychain read failure must not abort sign-out, whose
    // unauthenticated transition is unconditional (see AuthRepository.signOut
    // contract). On failure the POST simply goes out unauthenticated.
    String? token;
    try {
      token = (await _tokenStorage.retrieve())?.token;
    } on Object {
      token = null;
    }

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
      // within this process (PR #99 review). The latch is in-memory only, so
      // the residual risk is the surviving token restoring a session on the
      // next cold start, where sign-out can be repeated (see the
      // AuthRepository.signOut contract).
      Error.throwWithStackTrace(
        AuthSignOutPersistenceException(cause: error),
        stackTrace,
      );
    } finally {
      _setState(const AuthStateUnauthenticated());
    }
  }

  /// Fire-and-forget sign-out POST. Never throws: a synchronous throw or
  /// an async rejection is swallowed (best-effort by design). Typed
  /// `Future<void>` so it satisfies [unawaited].
  ///
  /// Carries [token] as an explicit `Authorization` header and opts out of
  /// [TokenInterceptor]-managed auth: the sign-out latch set by clear() wins
  /// the race against the interceptor's async token read, so relying on the
  /// interceptor would send this request unauthenticated (PR #99 review).
  /// A null [token] (already signed out / nothing stored) posts without auth.
  Future<void> _bestEffortSignOutPost(String? token) async {
    try {
      await _dio.post<void>(
        _identity.signOutEndpoint,
        options: token == null
            ? null
            : Options(
                headers: {'Authorization': 'Bearer $token'},
                extra: {TokenInterceptor.skipAuthKey: true},
              ),
      );
    } on Object {
      // discarded
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

    if (status == HttpStatusCode.conflict) {
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

  AuthException _mapDioException(DioException e) {
    final status = e.response?.statusCode;
    if (status == HttpStatusCode.unauthorized ||
        status == HttpStatusCode.forbidden) {
      return const AuthInvalidCredentialsException();
    }

    if (status == HttpStatusCode.conflict) {
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
