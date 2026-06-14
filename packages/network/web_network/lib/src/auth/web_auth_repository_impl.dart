import 'dart:async';

import 'package:dio/dio.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
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
  WebAuthRepositoryImpl({required ServerIdentity identity, required Dio dio})
    : _identity = identity,
      _dio = dio,
      _stateController = StreamController<AuthState>.broadcast(sync: true);

  final ServerIdentity _identity;
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

    // BetterAuth sets the session cookie in the response; the browser stores
    // it automatically. Immediately fetch the session for the full user object
    // and canonical expiry.
    final session = await getSession();
    if (session == null) {
      throw const AuthServerException(
        message: 'Sign-in succeeded but session could not be retrieved.',
      );
    }

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

    final session = await getSession();
    if (session == null) {
      throw const AuthServerException(
        message: 'Registration succeeded but session could not be retrieved.',
      );
    }

    return session;
  }

  @override
  Future<AuthResponse?> getSession() async {
    late final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.get<Map<String, dynamic>>(
        _identity.sessionEndpoint,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == HttpStatusCode.unauthorized) {
        _setState(const AuthStateUnauthenticated());
        return null;
      }
      throw _mapDioException(e);
    }

    if (response.statusCode == HttpStatusCode.unauthorized ||
        response.data == null) {
      _setState(const AuthStateUnauthenticated());
      return null;
    }

    if (response.statusCode != HttpStatusCode.ok) {
      throw AuthServerException(
        message: 'Unexpected ${response.statusCode} from session endpoint.',
        statusCode: response.statusCode,
      );
    }

    final sessionResponse = BgeSessionResponse.fromJson(response.data!);
    final auth = AuthResponse(
      // Web: token is opaque — use session id as a stable reference.
      // The actual cookie is browser-managed and never exposed to Dart.
      token: sessionResponse.session.token,
      user: sessionResponse.user,
      expiresAt: sessionResponse.session.expiresAt,
    );

    _setState(AuthStateAuthenticated(session: auth));
    return auth;
  }

  @override
  Future<void> signOut() async {
    try {
      await _dio.post<void>(_identity.signOutEndpoint);
    } catch (_) {
      // Best-effort. The browser discards the cookie on the server's
      // Set-Cookie: Max-Age=0 response regardless of Dart-side errors.
    } finally {
      _setState(const AuthStateUnauthenticated());
    }
  }

  /// On web, httpOnly cookies are opaque to Dart — we cannot inspect them
  /// without a network round-trip. Delegates to [getSession].
  @override
  Future<AuthResponse?> getCachedSession() => getSession();

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
