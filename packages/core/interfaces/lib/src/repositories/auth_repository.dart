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
  /// Best-effort server call. The repository's in-memory auth state
  /// ALWAYS transitions to [AuthStateUnauthenticated] — unconditionally,
  /// even when clearing the persisted session material fails. In that
  /// case an [AuthSignOutPersistenceException] is thrown, but only after
  /// the state transition has been observed by [watchAuthState], so the
  /// stream can never re-assert a session the user just ended (#37). The
  /// residual risk of a failed persisted clear is the surviving token
  /// restoring a session on the next cold start, where sign-out can be
  /// repeated.
  Future<void> signOut();

  /// Returns the locally cached session without a network call.
  ///
  /// On web, delegates to [getSession] since httpOnly cookies are opaque.
  Future<AuthResponse?> getCachedSession();

  /// Stream of auth state changes. Replays current state on subscribe.
  Stream<AuthState> watchAuthState();
}

/// Sealed hierarchy of authentication states.
///
/// ## Value equality
///
/// All three variants implement value equality:
///
/// - [AuthStateUnknown] and [AuthStateUnauthenticated]: const-no-field
///   singletons. Dart canonicalises const constructors, so two
///   `const AuthStateUnknown()` literals are already the same
///   instance and identity equality works. The explicit
///   `==`/`hashCode` overrides defend the non-const construction
///   case (e.g. a caller writing `AuthStateUnknown()` without
///   `const`) so the type alone determines equality.
/// - [AuthStateAuthenticated]: compares by `session` (which is an
///   `AuthResponse` — a freezed model with built-in value equality
///   from `@freezed`'s generated `==`/`hashCode`).
///
/// Value equality matters for [AuthRepositoryStateChanged] in the
/// bloc layer: that event extends Equatable with `props =
/// [repoState]`, and Equatable's equality only works correctly if
/// `repoState`'s own `==` is value-based. Without these overrides,
/// `AuthRepositoryStateChanged(AuthStateAuthenticated(s)) ==
/// AuthRepositoryStateChanged(AuthStateAuthenticated(s))` returned
/// false for freshly-constructed instances, breaking bloc-test
/// matchers like
/// `emits(AuthRepositoryStateChanged(AuthStateAuthenticated(expectedSession)))`.
sealed class AuthState {
  const AuthState();
}

final class AuthStateUnknown extends AuthState {
  const AuthStateUnknown();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AuthStateUnknown;

  @override
  int get hashCode => (AuthStateUnknown).hashCode;
}

final class AuthStateAuthenticated extends AuthState {
  const AuthStateAuthenticated({required this.session});
  final AuthResponse session;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AuthStateAuthenticated && other.session == session);

  @override
  int get hashCode => Object.hash(runtimeType, session);
}

final class AuthStateUnauthenticated extends AuthState {
  const AuthStateUnauthenticated();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AuthStateUnauthenticated;

  @override
  int get hashCode => (AuthStateUnauthenticated).hashCode;
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

/// Sign-out could not clear the locally persisted session material (#37).
///
/// Thrown by [AuthRepository.signOut] only AFTER the repository's
/// in-memory auth state has transitioned to [AuthStateUnauthenticated] —
/// the sign-out is effective for this process regardless, and
/// [AuthRepository.watchAuthState] can never re-assert the ended session.
/// The residual risk is the persisted token surviving until the next cold
/// start, where the restored session can be signed out again. [cause]
/// carries the underlying storage fault.
final class AuthSignOutPersistenceException extends AuthException {
  const AuthSignOutPersistenceException({
    super.message =
        'Signed out, but the stored session material could not be cleared.',
    super.cause,
  });
}
