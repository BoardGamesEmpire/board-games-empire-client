import 'dart:async';

import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart'
    show ConnectivityService, ConnectivityState;
import 'package:models/dto.dart';
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
/// - **Rejected** — the server refused the stored session. The repository
///   owns this classification and expresses it by clearing the stored
///   material and returning null: a 401, a 403, or BetterAuth's
///   200-with-null-body all land here. (Note it returns rather than throws
///   — the per-server Dio sets `validateStatus: (_) => true`, so those
///   statuses arrive as responses and never become
///   [AuthInvalidCredentialsException]. The catch for that type below is
///   defensive, covering a transport-level 401/403 only.) The session is
///   genuinely gone → [AuthUnauthenticated] → sign-in form.
/// - **Indeterminate** — the check could not complete (offline, timeout,
///   5xx, or an unexpected fault such as a locked keychain thrown by token
///   retrieval). We don't know, so we never show the form. #98 makes this
///   the interesting branch: if local material is good enough, enter the
///   app on it optimistically instead of blocking on a retry view.
///
/// ## Optimistic offline restore (#98)
///
/// Two paths reach it, and both funnel through
/// [AuthRepository.restoreCachedSession] so the repository — not this bloc
/// — decides eligibility and adopts the session as its own state (which is
/// what makes the current user resolvable by user-scoped repositories, see
/// #128):
///
/// - **Restore budget** (primary): when a locally restorable session
///   exists, the startup check is bounded by [_restoreBudget] instead of
///   the full Dio timeout — this carries the offline cold start, where the
///   connectivity seed is still optimistically `online`, and also covers
///   captive portals and dead-but-routable servers. A late resolution of
///   the bounded check still lands through the repository state stream.
/// - **Offline shortcut** (best-effort): when [ConnectivityService]
///   already reports offline accurately, the round trip is skipped
///   entirely.
/// - **Fallback**: the check was attempted and came back indeterminate.
///
/// A session entered this way is [SessionVerification.unverifiedOffline]
/// until revalidation confirms it. Three triggers dispatch
/// [AuthSessionRevalidationRequested]: a connectivity `offline → online`
/// edge (#98), the periodic retry timer in [onChange] for an unverified
/// state entered while online (#98), and app resume, owned by
/// `AuthLifecycleRevalidationTrigger` in the widget layer (#141) because
/// this bloc must not reach into Flutter bindings.
///
/// ## Concurrency
///
/// All operation handlers use `droppable()`: while one is in flight,
/// further events of the same type are dropped (not queued), so a
/// double-tapped "Try Again" or submit cannot run overlapping
/// getSession/signIn calls whose out-of-order completion would clobber the
/// correct terminal state. Revalidation is droppable for the same reason:
/// a flapping connection emits repeatedly and must not stack checks.
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
/// `addError`, or any future uncaught throw in a handler. The decision to
/// enter on a cached session is logged by the repository, which owns the
/// reasoning; this bloc does not duplicate it.
class AuthBloc extends Bloc<AuthEvent, AuthBlocState> {
  AuthBloc({
    required AuthRepository authRepository,
    ConnectivityService? connectivity,
    Duration restoreBudget = const Duration(seconds: 4),
    Duration? revalidationInterval = const Duration(seconds: 30),
  }) : _authRepository = authRepository,
       _connectivity = connectivity,
       _restoreBudget = restoreBudget,
       _revalidationInterval = revalidationInterval,
       super(const AuthInitial()) {
    on<AuthSessionCheckRequested>(_onSessionCheck, transformer: droppable());
    on<AuthSessionRevalidationRequested>(
      _onSessionRevalidation,
      transformer: droppable(),
    );
    on<AuthSignInRequested>(_onSignIn, transformer: droppable());
    on<AuthRegisterRequested>(_onRegister, transformer: droppable());
    on<AuthSignOutRequested>(_onSignOut, transformer: droppable());
    on<AuthRepositoryStateChanged>(_onRepositoryStateChanged);

    // Mirror repository-level state changes (e.g. token expiry detected by
    // the interceptor) into the bloc stream.
    _authStateSubscription = _authRepository.watchAuthState().listen(
      (repoState) => add(AuthRepositoryStateChanged(repoState)),
    );

    // #98: when connectivity returns, re-check a session we entered on
    // without server confirmation. `watch()` replays the current state to
    // every subscriber, so this may fire immediately — harmless, because
    // the handler no-ops unless the state is an unverified session, and at
    // construction it is [AuthInitial].
    //
    // The other in-process triggers are the periodic timer in [onChange],
    // which covers the case no connectivity edge ever fires for (an
    // unverified state entered while ONLINE — server 5xx/timeout), and
    // `AuthLifecycleRevalidationTrigger` in the widget layer, which covers
    // a device suspended offline and resumed online without an observed
    // coarse transition (#9 suppresses consecutive duplicates). All three
    // dispatch the same event into the same droppable handler, so they
    // cannot stack overlapping checks (#141).
    _connectivitySubscription = _connectivity
        ?.watch()
        .where((state) => state == ConnectivityState.online)
        .listen((_) => add(const AuthSessionRevalidationRequested()));
  }

  final AuthRepository _authRepository;

  /// Optional (#98). Absent means no connectivity awareness: no offline
  /// shortcut and no reconnect-triggered revalidation, with the restore
  /// budget and the periodic revalidation retry still intact. Nullable
  /// rather than an "always online" null object, because always-online is
  /// a lie that would both disable the shortcut and fire spurious
  /// revalidations — the same reasoning behind `AppBootstrapCubit`'s
  /// optional feedback service.
  final ConnectivityService? _connectivity;

  /// How long the startup check may hold the splash when a locally
  /// restorable session exists (#98). This — not the connectivity
  /// shortcut — is the primary offline fast path: at cold start
  /// [ConnectivityService.current] still holds its optimistic `online`
  /// seed (the eager platform check is asynchronous), so a shortcut gated
  /// on it can never fire when it matters most. Bounding the attempt also
  /// covers what a connectivity gate structurally cannot: captive portals,
  /// a dead server on a live network, and links slow enough to be
  /// indistinguishable from down. The budget applies ONLY when a cached
  /// session is eligible — with nothing to restore, waiting out the full
  /// attempt is strictly better than failing it early.
  final Duration _restoreBudget;

  /// Retry cadence for revalidating an unverified session (#98). A
  /// connectivity edge alone cannot clear the banner in the case where the
  /// unverified state was entered while ONLINE (server 5xx/timeout):
  /// connectivity never re-emits `online`, so without this the banner is
  /// permanent for the process even after the server recovers. Null
  /// disables the timer (tests). One lightweight GET per interval, running
  /// only while unverified.
  final Duration? _revalidationInterval;

  Timer? _revalidationTimer;

  late final StreamSubscription<AuthState> _authStateSubscription;
  StreamSubscription<ConnectivityState>? _connectivitySubscription;

  /// Diagnostic logger for the auth bloc's failure seams (#100).
  final BgeLogger _log = BgeLogger('bge.auth.bloc');

  Future<void> _onSessionCheck(
    AuthSessionCheckRequested event,
    Emitter<AuthBlocState> emit,
  ) async {
    emit(const AuthSessionCheckInProgress());

    // Offline shortcut (#98). Conditional on a cached session actually
    // existing, NOT on connectivity alone — with no stored material the
    // repository answers "unauthenticated" straight from storage without a
    // network call, and a first-run offline user needs that answer (the
    // sign-in form), not a retry view with nothing to retry into. This
    // shortcut is best-effort only: at cold start `current` still holds
    // its optimistic `online` seed, so the restore BUDGET below is what
    // actually carries the offline cold start. `unknown` does not take the
    // shortcut — undetermined is not absent.
    if (_connectivity?.current == ConnectivityState.offline) {
      final restored = await _tryRestoreCachedSession();
      if (restored != null) {
        _emitOptimistic(emit, restored);
        return;
      }
    }

    // Probe (pure read, no adoption) for whether a budget applies: only a
    // device holding an eligible cached session gets its startup check
    // bounded — everyone else waits out the full attempt, since for them
    // an early timeout only degrades the answer.
    AuthResponse? probe;
    try {
      probe = await _authRepository.getCachedSession();
    } on Object {
      probe = null;
    }

    try {
      // `.timeout` consumes the original future's late result, so a check
      // that eventually resolves AFTER the budget cannot become an
      // unhandled error — and its outcome still lands correctly: a late
      // success reaches the repository state stream as verified (the
      // mirror upgrades the optimistic session and clears the banner); a
      // late definitive rejection reaches it as unauthenticated (the gate
      // routes to the form, which is right — the session IS gone).
      final session = probe == null
          ? await _authRepository.getSession()
          : await _authRepository.getSession().timeout(_restoreBudget);
      emit(
        session != null
            ? AuthAuthenticated(session: session)
            : const AuthUnauthenticated(),
      );
    } on TimeoutException catch (e, s) {
      // Budget expended with restorable material in hand: enter on it.
      await _emitRestoreOrFailed(emit, e, s);
    } on AuthInvalidCredentialsException {
      // Rejected, not indeterminate. Defensive: the repository normally
      // expresses rejection by returning null (see the class docs), so
      // this covers a transport-level 401/403 surfacing as an exception.
      emit(const AuthUnauthenticated());
    } on AuthException catch (e, s) {
      // Indeterminate (network, timeout, 5xx).
      await _emitRestoreOrFailed(emit, e, s);
    } on Object catch (e, s) {
      // Unexpected non-auth fault — e.g. a PlatformException from a locked
      // keychain during token retrieval. Still indeterminate (we couldn't
      // verify), so try the cached session and otherwise surface the
      // retryable view rather than stranding the gate on an endless
      // splash. The stack rides along for the error log.
      await _emitRestoreOrFailed(emit, e, s);
    }
  }

  /// #98: re-check a session entered without server confirmation.
  ///
  /// Deliberately emits no progress state. The user is already inside the
  /// app; yanking them back to a splash to re-check a session they are
  /// actively using would be a worse experience than the stale banner this
  /// is trying to clear. It also means [_onRepositoryStateChanged]'s
  /// in-flight guard does not apply here — which is correct, since a
  /// repository transition to unauthenticated during revalidation is
  /// exactly the outcome that should reach the gate.
  Future<void> _onSessionRevalidation(
    AuthSessionRevalidationRequested event,
    Emitter<AuthBlocState> emit,
  ) async {
    final current = state;
    if (current is! AuthAuthenticated || !current.isUnverifiedOffline) return;

    try {
      final session = await _authRepository.getSession();
      emit(
        session != null
            ? AuthAuthenticated(session: session)
            : const AuthUnauthenticated(),
      );
    } on AuthInvalidCredentialsException {
      emit(const AuthUnauthenticated());
    } on AuthException {
      // Still unreachable. Keep the optimistic session and its banner: the
      // user is working offline and nothing about their situation changed.
      // No emit, so no spurious transition.
    } on Object catch (error, stackTrace) {
      // Unexpected fault while revalidating. Report it, but do not evict a
      // session that is working locally on the strength of a bug.
      addError(error, stackTrace);
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
    } on AuthSupersededException {
      // A sign-out overtook the grant (#146): the system is already
      // unauthenticated and storage already reflects it. Not a failure the
      // user needs to hear about — their own newer intent won.
      emit(const AuthUnauthenticated());
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
    } on AuthSupersededException {
      // See _onSignIn: the sign-out already won; return quietly.
      emit(const AuthUnauthenticated());
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
      // Compared by VALUE, not by type (#98). A type check —
      // `if (state is! AuthAuthenticated)` — was correct while this state
      // carried only a session, but now that it also carries a
      // verification it would swallow the one transition the widened
      // equality exists to expose: unverifiedOffline → verified on the
      // same session is still an AuthAuthenticated, so a type check
      // declares there is nothing to do and the banner never clears.
      // `emit` itself skips a state equal to the current one, so this is
      // safe to hand the same value repeatedly.
      case AuthStateAuthenticated(:final session, :final verification):
        emit(AuthAuthenticated(session: session, verification: verification));
      case AuthStateUnauthenticated():
        if (state is! AuthUnauthenticated) {
          emit(const AuthUnauthenticated());
        }
      case AuthStateUnknown():
        break;
    }
  }

  /// Emits the restored session with the verification the REPOSITORY
  /// reports, not an assumed `unverifiedOffline` (#98 review). The
  /// repository's `restoreCachedSession` deliberately does not downgrade a
  /// session it already holds as verified (a same-server bloc rebuild hits
  /// this), so unconditionally labelling the result unverified put bloc
  /// and repository in disagreement — banner showing for a verified
  /// session, and nothing to correct it because the repository, being
  /// verified all along, never re-emits.
  void _emitOptimistic(Emitter<AuthBlocState> emit, AuthResponse session) {
    final verification = switch (_authRepository.currentAuthState) {
      AuthStateAuthenticated(:final verification) => verification,
      _ => SessionVerification.unverifiedOffline,
    };
    emit(AuthAuthenticated(session: session, verification: verification));
  }

  /// Emits an optimistic session if one is available, else the retryable
  /// failure carrying the ORIGINAL cause — not whatever the restore
  /// attempt did. The user's problem is that the server was unreachable;
  /// a keychain hiccup during the fallback would be a misleading
  /// substitute.
  Future<void> _emitRestoreOrFailed(
    Emitter<AuthBlocState> emit,
    Object cause,
    StackTrace stackTrace,
  ) async {
    final restored = await _tryRestoreCachedSession();
    if (restored != null) {
      _emitOptimistic(emit, restored);
      return;
    }
    emit(AuthSessionCheckFailed(cause, stackTrace));
  }

  /// Never throws. An optimistic restore is an enhancement over the retry
  /// view, so a fault here must degrade to "no cached session" rather than
  /// replacing a diagnosable network failure with a storage one.
  Future<AuthResponse?> _tryRestoreCachedSession() async {
    try {
      return await _authRepository.restoreCachedSession();
    } on Object catch (error) {
      _log.warn(
        'Cached session restore failed; falling back to the retry view',
        context: {'cause': error.runtimeType.toString()},
      );
      return null;
    }
  }

  /// Keeps the periodic revalidation timer (#98) alive exactly while the
  /// state is an unverified session, from wherever that state was entered
  /// — the offline shortcut, the budget expiry, or the indeterminate
  /// fallback (which can happen while ONLINE, where no connectivity edge
  /// will ever fire). Cancelled the moment the state is anything else, so
  /// the retry GET runs only while there is something to retry for.
  @override
  void onChange(Change<AuthBlocState> change) {
    super.onChange(change);
    final interval = _revalidationInterval;
    if (interval == null) return;
    final next = change.nextState;
    final unverified = next is AuthAuthenticated && next.isUnverifiedOffline;
    if (unverified) {
      _revalidationTimer ??= Timer.periodic(
        interval,
        (_) => add(const AuthSessionRevalidationRequested()),
      );
    } else {
      _revalidationTimer?.cancel();
      _revalidationTimer = null;
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
      // Indeterminate restore with no cached session to fall back on:
      // severity keys off the CAUSE, not the state — a modelled
      // AuthException (network/timeout/5xx) is expected (warn); a non-auth
      // fault (e.g. locked keychain) is a system problem (error).
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
  /// revalidation's non-auth faults, or any uncaught throw in a handler
  /// that is not modelled as a failure state. Modelled failures are logged
  /// in [onTransition]; this catches what would otherwise vanish into the
  /// error sink.
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
    _revalidationTimer?.cancel();
    await _authStateSubscription.cancel();
    await _connectivitySubscription?.cancel();
    return super.close();
  }
}
