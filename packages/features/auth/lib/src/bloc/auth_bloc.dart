import 'dart:async';

import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:observability/observability.dart';

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
///
/// ## Observability (#100)
///
/// Failure logging is centralised in [onTransition] and [onError] rather
/// than scattered through the handlers. The handlers *catch* their
/// [AuthException]s and *emit* failure states (they do not rethrow), so
/// [onError] alone would see almost nothing; [onTransition] categorises the
/// emitted failure states by the #100 severity buckets — warn for the
/// modelled, recoverable outcomes (invalid credentials, network, email
/// taken, registration disabled), error for [AuthFailureServer] and for an
/// [AuthSessionCheckFailed] whose cause is an unexpected non-auth fault.
/// [onError] is the backstop for the genuinely unexpected: sign-out's
/// `addError`, or any future uncaught throw in a handler.
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

  /// Diagnostic logger for the auth bloc's failure seams (#100).
  final BgeLogger _log = BgeLogger('bge.auth.bloc');

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
    } on AuthException catch (e, s) {
      // Indeterminate (network, timeout, 5xx). Offer retry.
      emit(AuthSessionCheckFailed(e, s));
    } on Object catch (e, s) {
      // Unexpected non-auth fault — e.g. a PlatformException from a locked
      // keychain during token retrieval. Still indeterminate (we couldn't
      // verify), so surface the retryable view rather than stranding the
      // gate on an endless splash. The stack rides along for the error log.
      emit(AuthSessionCheckFailed(e, s));
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

  /// Centralised failure logging (#100). Runs on every state change; only
  /// failure states are logged, categorised by the #100 severity buckets.
  /// Success and progress states are intentionally silent here (per-request
  /// activity, when wanted, is the network interceptor's debug trail).
  @override
  void onTransition(Transition<AuthEvent, AuthBlocState> transition) {
    super.onTransition(transition);
    final next = transition.nextState;
    final event = transition.event.runtimeType.toString();
    switch (next) {
      // Recoverable, expected outcomes → warn.
      case AuthFailureInvalidCredentials():
      case AuthFailureEmailAlreadyExists():
      case AuthFailureRegistrationDisabled():
      case AuthFailureNetwork():
        _log.warn(
          'Auth operation failed',
          context: {'event': event, 'failure': next.runtimeType.toString()},
        );
      // Anything unanticipated (unexpected status, malformed body, …) → error.
      case AuthFailureServer(:final cause):
        _log.error(
          'Auth operation failed unexpectedly',
          error: cause,
          context: {'event': event, 'failure': 'AuthFailureServer'},
        );
      // Indeterminate restore: severity keys off the CAUSE, not the state —
      // a modelled AuthException (network/timeout/5xx) is expected (warn); a
      // non-auth fault (e.g. locked keychain) is a system problem (error).
      case AuthSessionCheckFailed(:final cause, :final stackTrace):
        if (cause is AuthException) {
          _log.warn(
            'Session check could not complete',
            context: {'event': event, 'cause': cause.runtimeType.toString()},
          );
        } else {
          _log.error(
            'Session check failed with an unexpected fault',
            error: cause,
            stackTrace: stackTrace,
            context: {'event': event},
          );
        }
      case _:
        break;
    }
  }

  /// Backstop for the genuinely unexpected (#100): sign-out's `addError`,
  /// or any uncaught throw in a handler that is not modelled as a failure
  /// state. Modelled failures are logged in [onTransition]; this catches
  /// what would otherwise vanish into the error sink.
  @override
  void onError(Object error, StackTrace stackTrace) {
    _log.error(
      'Uncaught error in AuthBloc',
      error: error,
      stackTrace: stackTrace,
    );
    super.onError(error, stackTrace);
  }

  @override
  Future<void> close() async {
    await _authStateSubscription.cancel();
    return super.close();
  }
}
