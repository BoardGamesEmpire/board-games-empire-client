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
class AppBootstrapCubit extends Cubit<AppBootstrapState> {
  AppBootstrapCubit({
    required PlatformBootstrap platformBootstrap,
    HydratedStorageInitializer? hydratedStorageInitializer,
    int resetOfferThreshold = 3,
    BgeLogger? logger,
  }) : _platformBootstrap = platformBootstrap,
       _logger = logger ?? BgeLogger('bge.shell.bootstrap'),
       _initializeHydratedStorage =
           hydratedStorageInitializer ?? _defaultHydratedStorageInitializer,
       _resetOfferThreshold = resetOfferThreshold,
       super(const AppBootstrapInitializing());

  final PlatformBootstrap _platformBootstrap;
  final BgeLogger _logger;
  final HydratedStorageInitializer _initializeHydratedStorage;
  final int _resetOfferThreshold;

  bool _started = false;
  bool _hydratedStorageReady = false;
  int _consecutiveFailures = 0;
  ServerOrchestrator? _orchestrator;

  /// The platform's [ServerOrchestrator] once bootstrap has succeeded;
  /// `null` before that and always `null` on web (single-server by
  /// construction, no orchestration).
  ServerOrchestrator? get orchestrator => _orchestrator;

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

  Future<void> _attempt() async {
    try {
      if (!_hydratedStorageReady) {
        await _initializeHydratedStorage(_platformBootstrap);
        _hydratedStorageReady = true;
      }
      final result = await _platformBootstrap.initialize();
      _orchestrator = result.orchestrator;
      _consecutiveFailures = 0;
      _logger.info(
        'Bootstrap succeeded',
        context: {'hasServer': result.hasServer},
      );
      // Never AppBootstrapReady from bootstrap: a registered server routes
      // to the auth leg unconditionally; the authenticated → home
      // transition is owned by the auth wiring issue (#37).
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
