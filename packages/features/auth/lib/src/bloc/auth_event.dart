import 'package:equatable/equatable.dart';
import 'package:interfaces/repositories.dart';

sealed class AuthEvent extends Equatable {
  const AuthEvent();

  @override
  List<Object?> get props => [];
}

final class AuthSessionCheckRequested extends AuthEvent {
  const AuthSessionCheckRequested();
}

final class AuthSignInRequested extends AuthEvent {
  const AuthSignInRequested({required this.email, required this.password});
  final String email;
  final String password;

  @override
  List<Object?> get props => [email, password];

  /// Redacted stringification.
  ///
  /// [password] stays in [props] for equality (tests rely on full
  /// structural equality of events), but Equatable's default
  /// [toString] honours `EquatableConfig.stringify` — if a host
  /// app or test harness sets that flag, the password would leak
  /// into Bloc transition logs, observer output, and test-failure
  /// matcher diffs. Overriding [toString] here makes the leak
  /// impossible regardless of EquatableConfig.
  @override
  String toString() =>
      'AuthSignInRequested(email: $email, password: <redacted>)';
}

final class AuthRegisterRequested extends AuthEvent {
  const AuthRegisterRequested({
    required this.email,
    required this.password,
    required this.username,
    this.firstName,
    this.lastName,
  });
  final String email;
  final String password;
  final String username;
  final String? firstName;
  final String? lastName;

  @override
  List<Object?> get props => [email, password, username, firstName, lastName];

  /// Redacted stringification — see [AuthSignInRequested.toString].
  @override
  String toString() =>
      'AuthRegisterRequested('
      'email: $email, '
      'password: <redacted>, '
      'username: $username, '
      'firstName: $firstName, '
      'lastName: $lastName)';
}

final class AuthSignOutRequested extends AuthEvent {
  const AuthSignOutRequested();
}

/// Internal — mirrors repository auth-stream changes into the bloc.
final class AuthRepositoryStateChanged extends AuthEvent {
  const AuthRepositoryStateChanged(this.repoState);
  final AuthState repoState;

  @override
  List<Object?> get props => [repoState];

  /// Type-only stringification.
  ///
  /// [repoState] can be [AuthStateAuthenticated] and carry a
  /// session token, refresh token, or user metadata; printing the
  /// full state via Equatable's stringify path (or any default
  /// `'$repoState'` interpolation) would leak credentials and PII
  /// into Bloc logs and test-failure output. The runtime type is
  /// the only part of this event worth surfacing in logs anyway —
  /// it tells you which transition just fired, which is what a
  /// reader of the trail actually needs.
  @override
  String toString() => 'AuthRepositoryStateChanged(${repoState.runtimeType})';
}
