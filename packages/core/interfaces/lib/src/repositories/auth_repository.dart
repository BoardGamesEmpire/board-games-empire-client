import 'package:models/dto.dart';
import 'package:models/domain.dart';

/// Per-server authentication repository.
///
/// Scoped to a single BGE server. All endpoint URLs are sourced from the
/// [ServerIdentity] injected at construction — never hardcoded.
///
/// Mobile/desktop: backed by [AuthRepositoryImpl] with [TokenStorageService].
/// Web: backed by [WebAuthRepositoryImpl] using browser-managed httpOnly cookies.
abstract class AuthRepository {
  /// Signs in with email and password.
  ///
  /// Throws [AuthInvalidCredentialsException] for 401/403.
  /// Throws [AuthNetworkException] for connectivity failures.
  /// Throws [AuthServerException] for unexpected server errors.
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  });

  /// Registers a new account and signs in.
  ///
  /// Throws [AuthRegistrationDisabledException] if registration is disabled.
  /// Throws [AuthEmailAlreadyExistsException] if the email is taken.
  /// Throws [AuthNetworkException] for connectivity failures.
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String username,
    String? firstName,
    String? lastName,
  });

  /// Validates the current session with the server.
  ///
  /// Returns null if unauthenticated. Updates stored expiry on success.
  Future<AuthResponse?> getSession();

  /// Signs out and clears the local session.
  ///
  /// Best-effort server call — local state is always cleared.
  Future<void> signOut();

  /// Returns the locally cached session without a network call.
  ///
  /// On web, delegates to [getSession] since httpOnly cookies are opaque.
  Future<AuthResponse?> getCachedSession();

  /// Stream of auth state changes. Replays current state on subscribe.
  Stream<AuthState> watchAuthState();
}

sealed class AuthState {
  const AuthState();
}

final class AuthStateUnknown extends AuthState {
  const AuthStateUnknown();
}

final class AuthStateAuthenticated extends AuthState {
  const AuthStateAuthenticated({required this.session});
  final AuthResponse session;
}

final class AuthStateUnauthenticated extends AuthState {
  const AuthStateUnauthenticated();
}

sealed class AuthException implements Exception {
  const AuthException({required this.message, this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

final class AuthInvalidCredentialsException extends AuthException {
  const AuthInvalidCredentialsException({
    super.message = 'Invalid email or password.',
  });
}

final class AuthEmailAlreadyExistsException extends AuthException {
  const AuthEmailAlreadyExistsException({
    super.message = 'An account with this email already exists.',
  });
}

final class AuthRegistrationDisabledException extends AuthException {
  const AuthRegistrationDisabledException({
    super.message = 'Registration is currently disabled on this server.',
  });
}

final class AuthNetworkException extends AuthException {
  const AuthNetworkException({required super.message, super.cause});
}

final class AuthServerException extends AuthException {
  const AuthServerException({
    required super.message,
    this.statusCode,
    super.cause,
  });
  final int? statusCode;
}
