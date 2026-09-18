import 'dart:async';

import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';

import 'app_bootstrap_state.dart';
import 'platform_bootstrap.dart';

/// Drives the application bootstrap sequence over a platform-supplied
/// [PlatformBootstrap] and exposes the outcome as [AppBootstrapState]s that
/// the router maps to locations.
///
/// Failure policy (confirmed in #31 design review):
/// - every failure is retryable;
/// - the destructive recovery action is *offered* only after
///   [_resetOfferThreshold] consecutive failures on a platform that
///   supports it, and executing it still requires explicit user
///   confirmation in the UI — the shell never deletes the meta database
///   on its own.
///
/// Auth transitions (#37): bootstrap itself never emits
/// [AppBootstrapReady] — a registered server routes to the auth leg
/// unconditionally, and the authenticated ↔ auth transitions are driven
/// by the auth wiring through [onAuthenticated] / [onSignedOut], the
/// same presentation-layer-coordination pattern as [onServerRegistered]
/// (a BlocListener over the auth bloc invokes them; blocs never depend
/// on blocs).
class AppBootstrapCubit extends Cubit<AppBootstrapState> {
  AppBootstrapCubit({
    required this._platformBootstrap,
    HydratedStorageInitializer? hydratedStorageInitializer,
    this._feedbackService,
    this._resetOfferThreshold = 3,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.shell.bootstrap'),
       _initializeHydratedStorage =
           hydratedStorageInitializer ?? _defaultHydratedStorageInitializer,
       super(const AppBootstrapInitializing());

  final PlatformBootstrap _platformBootstrap;

  /// The device-global feedback service whose queue is drained on every
  /// authenticated signal (#97). Optional: shell tests and hosts without
  /// feedback wiring pass null and no drain fires.
  final FeedbackService? _feedbackService;

  final BgeLogger _logger;
  final HydratedStorageInitializer _initializeHydratedStorage;
  final int _resetOfferThreshold;

  bool _started = false;
  bool _hydratedStorageReady = false;
  int _consecutiveFailures = 0;
  ServerOrchestrator? _orchestrator;
  ActiveServerScope? _activeServerScope;

  /// The platform's [ServerOrchestrator] once bootstrap has succeeded;
  /// `null` before that and always `null` on web (single-server by
  /// construction, no orchestration).
  ServerOrchestrator? get orchestrator => _orchestrator;

  /// The platform's [ActiveServerScope] once bootstrap has succeeded (#37)
  /// — the seam the shell provisions the auth bloc from. `null` before
  /// bootstrap, and `null` on web until #96 supplies the single-origin
  /// scope.
  ActiveServerScope? get activeServerScope => _activeServerScope;

  /// Runs the bootstrap sequence. Call exactly once, immediately after
  /// construction; subsequent recovery goes through [retry] /
  /// [resetAndRetry].
  Future<void> initialize() async {
    if (_started) {
      throw StateError(
        'AppBootstrapCubit.initialize() may only be called once; '
        'use retry() from a failed state.',
      );
    }
    _started = true;
    await _attempt();
  }

  /// Re-runs the bootstrap sequence after a failure.
  ///
  /// A no-op outside a failed state: this is a user-triggered,
  /// fire-and-forget action (rapid double-taps land the second call while
  /// the first has already moved the cubit to initializing), so an invalid
  /// state is not a programmer error and must not throw into an unawaited
  /// future.
  Future<void> retry() async {
    if (isClosed || state is! AppBootstrapFailed) return;
    emit(const AppBootstrapInitializing());
    await _attempt();
  }

  /// Destroys the device-local meta state via [PlatformBootstrap.reset],
  /// then re-runs the bootstrap sequence with a fresh attempt counter.
  ///
  /// Only valid while the reset offer is active
  /// ([AppBootstrapFailed.canOfferReset]); the calling UI must have
  /// obtained explicit user confirmation first. A no-op otherwise, for the
  /// same fire-and-forget reason as [retry].
  Future<void> resetAndRetry() async {
    final current = state;
    if (isClosed || current is! AppBootstrapFailed || !current.canOfferReset) {
      return;
    }
    emit(const AppBootstrapInitializing());
    _logger.warn(
      'User-confirmed destructive reset of device-local meta state',
      context: {'failedAttempts': _consecutiveFailures},
    );
    try {
      await _platformBootstrap.reset();
    } on Object catch (error, stackTrace) {
      // The reset is awaited, so this leg has the same close-during-attempt
      // window as _attempt, and the same reason to record nothing (#177).
      if (isClosed) return;
      _consecutiveFailures += 1;
      _logger.error(
        'Destructive reset failed',
        error: error,
        stackTrace: stackTrace,
      );
      emit(_failedState(error));
      return;
    }
    _consecutiveFailures = 0;
    await _attempt();
  }

  /// Advances the app past the server-add leg after the onboarding flow
  /// (#36) has persisted and activated the first server.
  ///
  /// Emits [AppBootstrapNeedsAuth]; the router redirect moves the app to
  /// `/auth` (a registered server routes to the auth leg unconditionally
  /// — the authenticated → home transition is [onAuthenticated]'s, #37).
  ///
  /// Only meaningful from [AppBootstrapNeedsServer]; a no-op otherwise,
  /// for the same fire-and-forget reason as [retry] — it is invoked from
  /// a BlocListener reacting to the onboarding bloc's success state, and
  /// a duplicate or late signal must not throw into an unawaited future.
  void onServerRegistered() {
    if (isClosed || state is! AppBootstrapNeedsServer) return;
    _logger.info('First server registered; advancing to auth');
    emit(const AppBootstrapNeedsAuth());
  }

  /// Advances the app past the auth leg once the auth wiring (#37)
  /// reports an authenticated session — sign-in, sign-up, or a
  /// successful startup restore all arrive here identically.
  ///
  /// Emits [AppBootstrapReady]; the router redirect moves the app to
  /// `/home`.
  ///
  /// Only meaningful from [AppBootstrapNeedsAuth]; a no-op otherwise,
  /// for the same fire-and-forget reason as [retry] — it is invoked from
  /// a BlocListener reacting to the auth bloc's authenticated state, and
  /// a duplicate or late signal (including the repository's state
  /// mirroring re-confirming an already-ready session) must not throw
  /// into an unawaited future.
  ///
  /// The queued-feedback drain (#97) fires on **every** invocation,
  /// deliberately before the state guard: sign-in and startup session
  /// restore arrive here from [AppBootstrapNeedsAuth], but a server
  /// switch re-authenticates while the cubit is already
  /// [AppBootstrapReady] — that signal must still drain the new server's
  /// queue even though the state transition is a no-op. Fire-and-forget:
  /// the drain never blocks or fails navigation.
  ///
  /// Two exceptions to "every invocation", both of which withhold the
  /// call rather than narrow the contract:
  /// - a **closed** cubit drains nothing (the guard below) — the app is
  ///   going away, and a best-effort upload has no one left to report to
  ///   (the service itself is device-global and outlives this cubit);
  /// - the shell does not invoke this at all when auth went stale during
  ///   user-session activation (#176), because the queue would be posted
  ///   against a session the server has just disowned.
  void onAuthenticated() {
    // Ahead of the drain, not merely the emit: a closed cubit means the app
    // is going away, and there is no one left for a best-effort upload to
    // report to. The service itself is device-global and outlives this
    // cubit, so the drain is withheld because the moment has passed, not
    // because the collaborator is gone (#177).
    if (isClosed) return;
    _drainPendingFeedback();
    if (state is! AppBootstrapNeedsAuth) return;
    _logger.info('Authenticated; advancing to home');
    emit(const AppBootstrapReady());
  }

  void _drainPendingFeedback() {
    final service = _feedbackService;
    if (service == null) return;
    unawaited(
      service
          .drainPending()
          .then((sent) {
            if (sent > 0) {
              _logger.info(
                'Drained queued feedback reports',
                context: {'sent': sent},
              );
            }
          })
          .catchError((Object error, StackTrace stackTrace) {
            // Best-effort by contract: a drain fault must never surface
            // into the auth transition it piggybacks on.
            _logger.warn(
              'Queued-feedback drain failed',
              error: error,
              stackTrace: stackTrace,
            );
          }),
    );
  }

  /// Returns the app to the auth leg after the authenticated session
  /// ends (#37) — explicit sign-out, or a mid-session authentication
  /// loss surfaced by the repository's auth-state stream (e.g. token
  /// expiry detected by the interceptor).
  ///
  /// Emits [AppBootstrapNeedsAuth]; the router redirect moves the app to
  /// `/auth`.
  ///
  /// Only meaningful from [AppBootstrapReady]; a no-op otherwise, for
  /// the same fire-and-forget reason as [retry] — unauthenticated
  /// signals also fire during the pre-home auth leg (a restore finding
  /// no session), where the app is already exactly where it belongs.
  void onSignedOut() {
    if (isClosed || state is! AppBootstrapReady) return;
    _logger.info('Signed out; returning to auth');
    emit(const AppBootstrapNeedsAuth());
  }

  Future<void> _attempt() async {
    // A closed cubit attempts nothing. The guards further down catch a
    // close that lands *inside* an attempt; this one catches a caller that
    // reaches here already closed — `resetAndRetry` does, on the leg where
    // the destructive reset itself succeeded after the close, and running
    // the bootstrap from there would open the meta database and build an
    // orchestrator that no one is left to reach or dispose (#177).
    if (isClosed) return;
    try {
      if (!_hydratedStorageReady) {
        await _initializeHydratedStorage(_platformBootstrap);
        _hydratedStorageReady = true;
      }
      final result = await _platformBootstrap.initialize();
      // Closed while the attempt was in flight (unmount, hot restart, test
      // teardown). Returning before the side effects keeps a closed cubit
      // from recording anything — an emit here would throw, and the catch
      // below would read that as a bootstrap failure (#177).
      if (isClosed) return;
      _orchestrator = result.orchestrator;
      _activeServerScope = result.activeServerScope;
      _consecutiveFailures = 0;
      _logger.info(
        'Bootstrap succeeded',
        context: {'hasServer': result.hasServer},
      );
      // Never AppBootstrapReady from bootstrap: a registered server routes
      // to the auth leg unconditionally; the authenticated → home
      // transition is owned by the auth wiring (#37, [onAuthenticated]).
      emit(
        result.hasServer
            ? const AppBootstrapNeedsAuth()
            : const AppBootstrapNeedsServer(),
      );
    } on Object catch (error, stackTrace) {
      // Same guard, and it must sit ahead of the counter: a closed cubit
      // that increments _consecutiveFailures leaves the count lying for a
      // failure nobody can see or retry (#177).
      if (isClosed) return;
      _consecutiveFailures += 1;
      _logger.error(
        'Bootstrap attempt failed',
        error: error,
        stackTrace: stackTrace,
        context: {'attempt': _consecutiveFailures},
      );
      emit(_failedState(error));
    }
  }

  AppBootstrapFailed _failedState(Object error) => AppBootstrapFailed(
    error: error,
    attemptCount: _consecutiveFailures,
    canOfferReset:
        _consecutiveFailures >= _resetOfferThreshold &&
        _platformBootstrap.supportsReset,
  );

  static Future<void> _defaultHydratedStorageInitializer(
    PlatformBootstrap bootstrap,
  ) async {
    HydratedBloc.storage = await HydratedStorage.build(
      storageDirectory: await bootstrap.hydratedStorageDirectory(),
    );
  }
}
