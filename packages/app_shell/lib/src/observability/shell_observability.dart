import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:observability/observability.dart';

/// Process-wide observability wiring owned by the shell.
///
/// `package:logging` is inherently global (loggers propagate to
/// [Logger.root]), so the shell owns the single [BreadcrumbBuffer] attached
/// to it. [runBgeApp] initializes this before anything else logs, ensuring
/// the ring buffer has history from the very first bootstrap step — which
/// is exactly what a feedback report about "the app won't start" needs.
///
/// The feedback UI ("ask each time" in alpha) consumes [breadcrumbs] via
/// `FeedbackService` when that wiring lands; #34 layers full zone-based
/// error reporting on top of the same buffer.
abstract final class ShellObservability {
  static BreadcrumbBuffer? _buffer;
  static StreamSubscription<LogRecord>? _debugConsoleSubscription;
  static Level? _previousRootLevel;

  /// The process-wide breadcrumb ring buffer. Throws if [initialize] has
  /// not run yet — that ordering bug should fail fast, not report empty
  /// breadcrumbs.
  static BreadcrumbBuffer get breadcrumbs {
    final buffer = _buffer;
    if (buffer == null) {
      throw StateError(
        'ShellObservability.initialize() must run before breadcrumbs are '
        'read; runBgeApp does this first.',
      );
    }
    return buffer;
  }

  static bool get isInitialized => _buffer != null;

  /// Attaches breadcrumb capture. Idempotent.
  ///
  /// Opens [Logger.root] to [Level.ALL] so verbose/debug records reach the
  /// ring buffer (its bounded capacity is the retention policy; the root
  /// level must not silently drop diagnostics before capture). In debug
  /// builds a console sink is added so the same records are visible while
  /// developing.
  static void initialize({BreadcrumbBuffer? buffer}) {
    if (_buffer != null) return;
    _previousRootLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    _buffer = (buffer ?? BreadcrumbBuffer())..attach();
    if (kDebugMode) {
      _debugConsoleSubscription = Logger.root.onRecord.listen((record) {
        debugPrint(
          '[${record.level.name}] ${record.loggerName}: ${record.message}'
          '${record.error == null ? '' : ' | ${record.error}'}',
        );
      });
    }
  }

  /// Detaches and clears all wiring so tests can re-initialize cleanly,
  /// including restoring [Logger.root]'s level to whatever it was before
  /// [initialize] raised it — otherwise the `Level.ALL` override would leak
  /// across tests and into embedding apps.
  @visibleForTesting
  static Future<void> reset() async {
    await _buffer?.detach();
    _buffer = null;
    await _debugConsoleSubscription?.cancel();
    _debugConsoleSubscription = null;
    if (_previousRootLevel != null) {
      Logger.root.level = _previousRootLevel;
      _previousRootLevel = null;
    }
  }
}
