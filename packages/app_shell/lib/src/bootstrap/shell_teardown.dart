import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';

import 'app_bootstrap_cubit.dart';
import 'platform_bootstrap.dart';

/// The app's one teardown (#384), built by `runBgeApp`.
///
/// Closes the bootstrap cubit, then disposes the platform bootstrap, then
/// the root container. The cubit goes first so that nothing can start a
/// retry on a bootstrap that is already closing. The root container goes
/// last: it is device-global and was built before everything else.
///
/// A step that fails is breadcrumbed at warn and does not skip the next:
/// a failed cubit close must not leave the databases open.
class ShellTeardown {
  ShellTeardown({
    required this._bootstrapCubit,
    required this._platformBootstrap,
    required this._rootContainer,
    this._exitDeadline = const Duration(seconds: 2),
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.shell.teardown');

  final AppBootstrapCubit _bootstrapCubit;
  final PlatformBootstrap _platformBootstrap;
  final DependencyContainer _rootContainer;
  final BgeLogger _logger;

  /// How long [onExitRequested] waits for the teardown before it grants the
  /// exit anyway (#226). The close normally takes milliseconds; the deadline
  /// only matters when something is stuck, such as a database open that
  /// never returns while the orchestrator waits for it before disposing.
  final Duration _exitDeadline;

  Future<void>? _running;
  bool _listening = false;
  AppLifecycleListener? _exitListener;

  /// Runs the teardown once. Every caller gets the same future, so the
  /// second of the exit hook and the widget unmount waits for the first
  /// instead of returning mid-close. It never completes with an error.
  Future<void> run() => _running ??= _run();

  /// Registers [onExitRequested] for the platform's exit request (#226).
  /// Call once; a second call is a programmer error and throws
  /// [StateError], the `DeepLinkHandler.start()` precedent.
  ///
  /// Desktop embedders send a cancellable `System.requestAppExit` on quit
  /// and on last-window close. Mobile and web send none, so there it never
  /// fires. The listener is removed once [run] has finished, since there is
  /// nothing left for an exit to wait for.
  ///
  /// This hook assumes it is the only thing that answers exit requests. The
  /// framework asks every listener and cancels the exit if any one of them
  /// says cancel, but by then this one has already torn the app down.
  /// Nothing else answers today. Anything that may cancel — a "quit
  /// anyway?" prompt — must decide before this teardown runs, not beside it.
  void listenForExit() {
    if (_listening) {
      throw StateError(
        'ShellTeardown.listenForExit() may only be called once per instance',
      );
    }
    _listening = true;
    _exitListener = AppLifecycleListener(onExitRequested: onExitRequested);
  }

  /// Answers the platform's cancellable exit request (#226): waits for
  /// [run], up to a deadline of two seconds by default, then grants the
  /// exit either way.
  ///
  /// Granting the exit with the databases still open is what crashes on
  /// macOS, so the answer waits for them to close. A quit that hangs is
  /// worse than the crash, so the wait is bounded. When the deadline wins,
  /// the exit goes ahead with handles open, and that remaining risk is
  /// tracked upstream in #392.
  Future<AppExitResponse> onExitRequested() async {
    try {
      await run().timeout(_exitDeadline);
    } on TimeoutException {
      _logger.warn(
        'Teardown missed the exit deadline; exiting with it unfinished',
        context: {'deadlineMs': _exitDeadline.inMilliseconds},
      );
    }
    return AppExitResponse.exit;
  }

  Future<void> _run() async {
    await _step('bootstrap cubit close', _bootstrapCubit.close);
    await _step('platform bootstrap dispose', _platformBootstrap.dispose);
    await _step('root container dispose', _rootContainer.dispose);
    _exitListener?.dispose();
    _exitListener = null;
  }

  Future<void> _step(String step, Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Teardown step failed; continuing with the rest',
        error: error,
        stackTrace: stackTrace,
        context: {'step': step},
      );
    }
  }
}
