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
      // Web authenticates via the browser-managed httpOnly cookie, never
      // this field — nothing on web reads `AuthResponse.token` as a
      // credential. It is carried for shape parity with native.
      //
      // Note this IS the real session token, not an opaque identifier: an
      // earlier comment here claimed it was the session id, which it never
      // was. That makes it a live credential sitting in Dart-reachable
      // memory on web, which partly undoes the point of the httpOnly
      // cookie. Tracked separately (#144); do not persist or log it.
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
