import 'package:flutter/foundation.dart';
import 'package:observability/observability.dart';

import 'shell_observability.dart';
import 'uncaught_error_record.dart';

/// Consumes captured [UncaughtErrorRecord]s (issue #34).
///
/// The seam the follow-up `FeedbackService` wiring implements. The
/// default is [NoopUncaughtErrorReporter]: capture (logging, breadcrumbs,
/// the last-error slot) happens regardless; *reporting* is opt-in.
abstract interface class UncaughtErrorReporter {
  /// Called once per uncaught error with the same record instance that
  /// filled the last-error slot. Implementations must not assume they run
  /// on any particular zone or that UI exists yet; errors thrown here are
  /// swallowed by the hooks (a crash inside crash reporting must never
  /// take the app down).
  void report(UncaughtErrorRecord record);
}

/// Default reporter: does nothing.
final class NoopUncaughtErrorReporter implements UncaughtErrorReporter {
  const NoopUncaughtErrorReporter();

  @override
  void report(UncaughtErrorRecord record) {}
}

/// Sink for captured records; defaults to
/// [ShellObservability.recordUncaughtError].
typedef RecordUncaughtError = void Function(UncaughtErrorRecord record);

/// Installs the process-global uncaught-error hooks (issue #34).
///
/// Wires the two catch-all surfaces the Flutter team recommends:
///
/// - [FlutterError.onError] — framework errors (build/layout/paint).
///   Delegates first to [presentError] so console output survives, then
///   captures.
/// - [PlatformDispatcher.instance.onError] — uncaught async and non-UI
///   Dart errors. Returns `true` unconditionally after capture; returning
///   `false` can hard-crash the app.
///
/// **No custom Zone.** Per official Flutter guidance (3.3+),
/// `PlatformDispatcher.onError` supersedes `runZonedGuarded` for uncaught
/// async errors; a custom zone risks binding zone-mismatch and bypassing
/// `onError`. These two hooks are the entire catch-all surface.
///
/// **Idempotent re-installation.** The framework hook delegates to
/// [presentError] — when not injected, [FlutterError.presentError] is
/// read *at invocation time* (it is a mutable static field, so this both
/// satisfies const-default rules and always honours the framework's
/// current presenter, e.g. under test bindings) — and never reads or
/// chains the previous `onError`. If this runs more than once in a
/// process (hot restart, test setups), the new handlers simply replace
/// the old ones; the chain cannot grow and reports cannot duplicate.
///
/// **Capture path per error:** static-message log via [logger] (the
/// breadcrumb trail stays PII-free by construction — only the error's
/// runtime type enters crumb context), then one [UncaughtErrorRecord] is
/// built and handed to [recordError] (the last-error slot) and
/// [reporter]. Failures anywhere in that capture path are swallowed and
/// logged at warn.
///
/// `ErrorWidget.builder` (the in-build failure UI) is deliberately NOT
/// replaced here — that is presentation, split to #66 so this unit stays
/// capture-only.
void installGlobalErrorHooks({
  FlutterExceptionHandler? presentError,
  UncaughtErrorReporter reporter = const NoopUncaughtErrorReporter(),
  RecordUncaughtError recordError = ShellObservability.recordUncaughtError,
  BgeLogger? logger,
}) {
  final log = logger ?? BgeLogger('bge.shell.uncaught');

  void capture(
    String message,
    Object error,
    StackTrace stackTrace, {
    String? library,
  }) {
    log.error(
      message,
      error: error,
      stackTrace: stackTrace,
      context: {'errorType': error.runtimeType.toString(), 'library': ?library},
    );
    try {
      final record = UncaughtErrorRecord.capture(error, stackTrace);
      recordError(record);
      reporter.report(record);
    } catch (captureError, captureStack) {
      // A crash inside crash capture must never propagate — it would
      // re-enter these hooks (framework path) or crash the app
      // (platform path returns true regardless).
      log.warn(
        'Uncaught-error capture failed',
        error: captureError,
        stackTrace: captureStack,
      );
    }
  }

  FlutterError.onError = (details) {
    (presentError ?? FlutterError.presentError)(details);
    capture(
      'Uncaught framework error',
      details.exception,
      details.stack ?? StackTrace.current,
      library: details.library,
    );
  };

  PlatformDispatcher.instance.onError = (error, stackTrace) {
    capture('Uncaught platform error', error, stackTrace);
    return true;
  };
}
