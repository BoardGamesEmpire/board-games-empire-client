import 'dart:async';

import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';

import 'auth_event.dart';
import 'auth_bloc_state.dart';

/// Manages authentication state for a single server context.
///
/// Receives an [AuthRepository] scoped to the active server. When the active
/// server changes, the parent widget tree should rebuild with a fresh
/// [AuthBloc] bound to the new server's repository (#37: keyed on the
/// `ActiveServer.serverId` from the `ActiveServerScope` seam).
///
/// ## Phases (#37)
///
/// The startup session check ("restore") uses dedicated states —
/// [AuthSessionCheckInProgress] / [AuthSessionCheckFailed] — so the auth
/// gate can render splash / retry without widget-local memory. Interactive
/// operations (sign-in, register, sign-out) use [AuthLoading] and the
/// sealed [AuthOperationFailure] kinds, which the auth form renders inline.
///
/// ## Rejected vs. indeterminate (#37 review)
///
/// A session check distinguishes two failure modes:
/// - **Rejected** — the server refused the stored session (401 clears the
///   token and yields null; a 403 or other credential rejection maps to
///   [AuthInvalidCredentialsException]). The session is genuinely gone →
///   [AuthUnauthenticated] → sign-in form.
/// - **Indeterminate** — the check could not complete (offline, timeout,
///   5xx, or an unexpected fault such as a locked keychain thrown by token
///   retrieval). We don't know → [AuthSessionCheckFailed] → retryable
///   "can't reach server" view, never the form (#98 upgrades this to
///   optimistic offline restore).
///
/// ## Concurrency
///
/// All operation handlers use `droppable()`: while one is in flight,
/// further events of the same type are dropped (not queued), so a
/// double-tapped "Try Again" or submit cannot run overlapping
/// getSession/signIn calls whose out-of-order completion would clobber the
/// correct terminal state.
///
/// ## i18n
///
/// This bloc emits no display strings — failures are semantic kinds and
/// the widget layer owns localization (`AuthLocalizations`).
class AuthBloc extends Bloc<AuthEvent, AuthBlocState> {
  AuthBloc({required AuthRepository authRepository})
    : _authRepository = authRepository,
      super(const AuthInitial()) {
    on<AuthSessionCheckRequested>(_onSessionCheck, transformer: droppable());
    on<AuthSignInRequested>(_onSignIn, transformer: droppable());
    on<AuthRegisterRequested>(_onRegister, transformer: droppable());
    on<AuthSignOutRequested>(_onSignOut, transformer: droppable());
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
    emit(const AuthSessionCheckInProgress());
    try {
      final session = await _authRepository.getSession();
      emit(
        session != null
            ? AuthAuthenticated(session: session)
            : const AuthUnauthenticated(),
      );
    } on AuthInvalidCredentialsException {
      // Rejected, not indeterminate: the server refused the stored session
      // (e.g. 403 on a banned/stale session, which the repository maps to
      // this type). The session is gone — go to the sign-in form, not the
      // retry-forever unreachable view.
      emit(const AuthUnauthenticated());
    } on AuthException catch (e) {
      // Indeterminate (network, timeout, 5xx). Offer retry.
      emit(AuthSessionCheckFailed(e));
    } on Object catch (e) {
      // Unexpected non-auth fault — e.g. a PlatformException from a locked
      // keychain during token retrieval. Still indeterminate (we couldn't
      // verify), so surface the retryable view rather than stranding the
      // gate on an endless splash.
      emit(AuthSessionCheckFailed(e));
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
      emit(const AuthFailureInvalidCredentials());
    } on AuthNetworkException {
      emit(const AuthFailureNetwork());
    } on AuthException catch (e) {
      emit(AuthFailureServer(e));
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
      emit(const AuthFailureRegistrationDisabled());
    } on AuthEmailAlreadyExistsException {
      emit(const AuthFailureEmailAlreadyExists());
    } on AuthNetworkException {
      emit(const AuthFailureNetwork());
    } on AuthException catch (e) {
      emit(AuthFailureServer(e));
    }
  }

  Future<void> _onSignOut(
    AuthSignOutRequested event,
    Emitter<AuthBlocState> emit,
  ) async {
    emit(const AuthLoading());
    try {
      await _authRepository.signOut();
    } on Object catch (error, stackTrace) {
      // Sign-out is intent-to-leave: it must ALWAYS reach
      // AuthUnauthenticated so the gate flips, regardless of what failed.
      // (This deliberately differs from the sign-in/register handlers,
      // where a failure keeps the user on the form to retry — sign-out has
      // nowhere better to land.) The repository already guarantees its
      // in-memory state is unauthenticated before any throw
      // (AuthSignOutPersistenceException), so the mirror cannot resurrect
      // the session. Any error — typed or not — is surfaced via addError
      // for the crash channel, then we flip.
      addError(error, stackTrace);
    }
    emit(const AuthUnauthenticated());
  }

  void _onRepositoryStateChanged(
    AuthRepositoryStateChanged event,
    Emitter<AuthBlocState> emit,
  ) {
    // Never override an in-flight startup check: its own handler owns the
    // terminal emit, and a stray repo Unauthenticated (e.g. the 401-clear
    // from that very getSession, or an interceptor 401 on another request)
    // must not flip the gate into the sign-in form mid-check — defeating
    // the indeterminate-never-shows-the-form invariant (#37 review).
    if (state is AuthSessionCheckInProgress) return;

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
