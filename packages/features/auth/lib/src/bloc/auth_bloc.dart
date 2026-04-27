import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';

import 'auth_event.dart';
import 'auth_bloc_state.dart';

/// Manages authentication state for a single server context.
///
/// Receives an [AuthRepository] scoped to the active server. When the active
/// server changes, the parent widget tree should rebuild with a fresh
/// [AuthBloc] bound to the new server's repository.
class AuthBloc extends Bloc<AuthEvent, AuthBlocState> {
  AuthBloc({required AuthRepository authRepository})
    : _authRepository = authRepository,
      super(const AuthInitial()) {
    on<AuthSessionCheckRequested>(_onSessionCheck);
    on<AuthSignInRequested>(_onSignIn);
    on<AuthRegisterRequested>(_onRegister);
    on<AuthSignOutRequested>(_onSignOut);
    on<AuthRepositoryStateChanged>(_onRepositoryStateChanged);

    // Mirror repository-level state changes (e.g. token expiry detected by
    // the interceptor) into the bloc stream.
    _authStateSubscription = _authRepository.watchAuthState().listen(
      (repoState) => add(AuthRepositoryStateChanged(repoState)),
    );
  }

  final AuthRepository _authRepository;
  late final StreamSubscription<AuthState> _authStateSubscription;

  Future<void> _onSessionCheck(
    AuthSessionCheckRequested event,
    Emitter<AuthBlocState> emit,
  ) async {
    emit(const AuthLoading());
    try {
      final session = await _authRepository.getSession();
      emit(
        session != null
            ? AuthAuthenticated(session: session)
            : const AuthUnauthenticated(),
      );
    } on AuthException catch (e) {
      emit(AuthFailure(message: e.message));
    }
  }

  Future<void> _onSignIn(
    AuthSignInRequested event,
    Emitter<AuthBlocState> emit,
  ) async {
    emit(const AuthLoading());
    try {
      final session = await _authRepository.signIn(
        email: event.email,
        password: event.password,
      );
      emit(AuthAuthenticated(session: session));
    } on AuthInvalidCredentialsException {
      emit(const AuthFailure(message: 'Incorrect email or password.'));
    } on AuthNetworkException {
      emit(
        const AuthFailure(
          message: 'Could not reach the server. Check your connection.',
        ),
      );
    } on AuthException catch (e) {
      emit(AuthFailure(message: e.message));
    }
  }

  Future<void> _onRegister(
    AuthRegisterRequested event,
    Emitter<AuthBlocState> emit,
  ) async {
    emit(const AuthLoading());
    try {
      final session = await _authRepository.signUp(
        email: event.email,
        password: event.password,
        username: event.username,
        firstName: event.firstName,
        lastName: event.lastName,
      );
      emit(AuthAuthenticated(session: session));
    } on AuthRegistrationDisabledException {
      emit(
        const AuthFailure(
          message: 'Registration is currently disabled on this server.',
        ),
      );
    } on AuthEmailAlreadyExistsException {
      emit(
        const AuthFailure(
          message: 'An account with this email already exists.',
          field: 'email',
        ),
      );
    } on AuthNetworkException {
      emit(
        const AuthFailure(
          message: 'Could not reach the server. Check your connection.',
        ),
      );
    } on AuthException catch (e) {
      emit(AuthFailure(message: e.message));
    }
  }

  Future<void> _onSignOut(
    AuthSignOutRequested event,
    Emitter<AuthBlocState> emit,
  ) async {
    emit(const AuthLoading());
    await _authRepository.signOut();
    emit(const AuthUnauthenticated());
  }

  void _onRepositoryStateChanged(
    AuthRepositoryStateChanged event,
    Emitter<AuthBlocState> emit,
  ) {
    switch (event.repoState) {
      case AuthStateAuthenticated(:final session):
        if (state is! AuthAuthenticated) {
          emit(AuthAuthenticated(session: session));
        }
      case AuthStateUnauthenticated():
        if (state is! AuthUnauthenticated) {
          emit(const AuthUnauthenticated());
        }
      case AuthStateUnknown():
        break;
    }
  }

  @override
  Future<void> close() async {
    await _authStateSubscription.cancel();
    return super.close();
  }
}
