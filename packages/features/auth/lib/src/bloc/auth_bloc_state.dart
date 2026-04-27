import 'package:equatable/equatable.dart';
import 'package:models/dto.dart';

sealed class AuthBlocState extends Equatable {
  const AuthBlocState();

  @override
  List<Object?> get props => [];
}

final class AuthInitial extends AuthBlocState {
  const AuthInitial();
}

final class AuthLoading extends AuthBlocState {
  const AuthLoading();
}

final class AuthAuthenticated extends AuthBlocState {
  const AuthAuthenticated({required this.session});
  final AuthResponse session;

  @override
  List<Object?> get props => [session];
}

final class AuthUnauthenticated extends AuthBlocState {
  const AuthUnauthenticated();
}

/// An auth operation failed. [field] hints which form field caused it, if any.
final class AuthFailure extends AuthBlocState {
  const AuthFailure({required this.message, this.field});
  final String message;
  final String? field;

  @override
  List<Object?> get props => [message, field];
}
