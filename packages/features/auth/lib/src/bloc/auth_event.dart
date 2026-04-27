import 'package:interfaces/repositories.dart';

sealed class AuthEvent {
  const AuthEvent();
}

final class AuthSessionCheckRequested extends AuthEvent {
  const AuthSessionCheckRequested();
}

final class AuthSignInRequested extends AuthEvent {
  const AuthSignInRequested({required this.email, required this.password});
  final String email;
  final String password;
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
}

final class AuthSignOutRequested extends AuthEvent {
  const AuthSignOutRequested();
}

/// Internal — mirrors repository auth-stream changes into the bloc.
final class AuthRepositoryStateChanged extends AuthEvent {
  const AuthRepositoryStateChanged(this.repoState);
  final AuthState repoState;
}
