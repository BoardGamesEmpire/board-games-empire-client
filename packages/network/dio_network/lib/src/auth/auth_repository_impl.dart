import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import 'token_storage_service.dart';

/// Dio-based [AuthRepository] for mobile and desktop.
///
/// Scoped to a single BGE server. Must be registered inside the server's
/// [DependencyContainer] after the [ServerIdentity] has been fetched.
/// Never shared across server contexts.
class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl({
    required ServerIdentity identity,
    required TokenStorageService tokenStorage,
    @visibleForTesting Dio? dio,
  }) : _identity = identity,
       _tokenStorage = tokenStorage,
       _dio = dio ?? _buildDio(),
       _stateController = StreamController<AuthState>.broadcast() {
    _addTokenInterceptor();
  }

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
          if (firstName != null) 'first_name': firstName,
          if (lastName != null) 'last_name': lastName,
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
      if (e.response?.statusCode == 401) {
        await _tokenStorage.clear();
        _setState(const AuthStateUnauthenticated());
        return null;
      }
      throw _mapDioException(e);
    }

    if (response.statusCode == 401) {
      await _tokenStorage.clear();
      _setState(const AuthStateUnauthenticated());
      return null;
    }

    if (response.statusCode != 200 || response.data == null) return null;

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
    try {
      await _dio.post<void>(_identity.signOutEndpoint);
    } catch (_) {
      // best-effort
    } finally {
      await _tokenStorage.clear();
      _setState(const AuthStateUnauthenticated());
    }
  }

  @override
  Future<AuthResponse?> getCachedSession() async {
    final stored = await _tokenStorage.retrieve();
    if (stored == null || stored.isExpired) return null;
    if (_currentState case AuthStateAuthenticated(:final session)) {
      return session;
    }
    return null;
  }

  @override
  Stream<AuthState> watchAuthState() async* {
    yield _currentState;
    yield* _stateController.stream;
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
    if (status == 401 || status == 403) {
      throw const AuthInvalidCredentialsException();
    }
    if (status == 409) throw const AuthEmailAlreadyExistsException();
    if (status == null || status < 200 || status >= 300) {
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
    if (status == 401 || status == 403) {
      return const AuthInvalidCredentialsException();
    }
    if (status == 409) return const AuthEmailAlreadyExistsException();
    if (status != null && status >= 500) {
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

  void _addTokenInterceptor() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final stored = await _tokenStorage.retrieve();
          if (stored != null && !stored.isExpired) {
            options.headers['Authorization'] = 'Bearer ${stored.token}';
          }
          handler.next(options);
        },
      ),
    );
  }

  static Dio _buildDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: const {'Accept': 'application/json'},
      validateStatus: (_) => true,
    ),
  );

  Future<void> dispose() async {
    await _stateController.close();
    _dio.close();
  }
}
