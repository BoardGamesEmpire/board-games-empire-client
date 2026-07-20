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
    required PlatformBootstrap platformBootstrap,
    HydratedStorageInitializer? hydratedStorageInitializer,
    FeedbackService? feedbackService,
    int resetOfferThreshold = 3,
    BgeLogger? logger,
  }) : _platformBootstrap = platformBootstrap,
       _feedbackService = feedbackService,
       _logger = logger ?? BgeLogger('bge.shell.bootstrap'),
       _initializeHydratedStorage =
           hydratedStorageInitializer ?? _defaultHydratedStorageInitializer,
       _resetOfferThreshold = resetOfferThreshold,
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
    if (state is! AppBootstrapFailed) return;
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
    if (current is! AppBootstrapFailed || !current.canOfferReset) return;
    emit(const AppBootstrapInitializing());
    _logger.warn(
      'User-confirmed destructive reset of device-local meta state',
      context: {'failedAttempts': _consecutiveFailures},
    );
    try {
      await _platformBootstrap.reset();
    } on Object catch (error, stackTrace) {
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
    if (state is! AppBootstrapNeedsServer) return;
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
  void onAuthenticated() {
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
    if (state is! AppBootstrapReady) return;
    _logger.info('Signed out; returning to auth');
    emit(const AppBootstrapNeedsAuth());
  }

  Future<void> _attempt() async {
    try {
      if (!_hydratedStorageReady) {
        await _initializeHydratedStorage(_platformBootstrap);
        _hydratedStorageReady = true;
      }
      final result = await _platformBootstrap.initialize();
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
