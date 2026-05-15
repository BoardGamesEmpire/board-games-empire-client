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
}
