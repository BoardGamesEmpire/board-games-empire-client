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
/// **`onError` returns `true` unconditionally — two deliberate
/// consequences.** (1) Uncaught async errors are marked handled and do not
/// propagate to any engine-level/native crash reporter; that is by design
/// — BGE is privacy-first, and the sole crash sink is the app's own
/// `FeedbackService` (posting only to the user-controlled server), never a
/// third-party platform. (2) Widget/integration tests that would otherwise
/// fail on an uncaught async error pass silently under these hooks;
/// tests must therefore assert on captured records (inject a [reporter] or
/// read [ShellObservability.lastUncaughtError]) rather than relying on
/// uncaught-error propagation.
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
/// **Capture path per error — each side effect is independently
/// guarded** so no single failure can starve the others or escape the
/// hook:
///
/// 1. [presentError] runs in its own guard (a broken presenter must not
///    skip capture); it is intentionally OUTSIDE the record/report guard
///    because swallowing its output is not its job — it is the framework's
///    console presenter.
/// 2. The static-message [logger] call (PII-free by construction — only
///    the error's runtime type enters crumb context) is guarded.
/// 3. One [UncaughtErrorRecord] is built and handed to [recordError] (the
///    last-error slot) and [reporter], each in its own guard so a throwing
///    `recordError` (e.g. a public caller invoking this before
///    [ShellObservability.initialize]) cannot prevent the [reporter] — the
///    component that actually uploads crashes — from being notified, and
///    vice versa.
///
/// Every guard routes its own failure to [logger] at warn, so a
/// crash-inside-crash never propagates (which, on the framework path,
/// would re-enter these hooks) yet never becomes silent either.
///
/// **Re-entrancy.** A [recordError] that notifies listeners (the last-error
/// slot is a `ValueListenable`, and `FeedbackService` will listen) can, if
/// a listener throws, route back through `FlutterError.reportError` into
/// [FlutterError.onError] and re-enter this capture — an unbounded storm
/// turning one crash into a `StackOverflowError`. A re-entrancy guard
/// detects the nested call, still presents and logs the secondary error,
/// but skips the record/report side effects that caused the re-entry.
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
  var inCapture = false;

  /// Runs [action], routing any throw to a warn-level log instead of
  /// letting it escape the hook (and, on the framework path, re-enter it).
  void guarded(String failureMessage, void Function() action) {
    try {
      action();
    } catch (error, stackTrace) {
      log.warn(failureMessage, error: error, stackTrace: stackTrace);
    }
  }

  void capture(
    void Function() present,
    String message,
    Object error,
    StackTrace stackTrace, {
    String? library,
  }) {
    // Present first and always — it is the framework's console presenter,
    // guarded only so a broken presenter can't skip capture below.
    guarded('Uncaught-error presentation failed', present);

    // Re-entrancy guard: a throwing last-error listener routes back through
    // FlutterError.reportError into FlutterError.onError and re-enters
    // here. Present + log the nested error (above/below) but skip the
    // record/report side effects that triggered it, breaking the loop.
    if (inCapture) {
      log.warn(
        'Re-entrant uncaught error during capture; skipping record/report',
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }
    inCapture = true;
    try {
      // Logged before the record is built so the error is breadcrumbed even
      // if record construction throws. Guarded because a custom log sink
      // could throw. errorType is recomputed in UncaughtErrorRecord.capture;
      // the duplication is deliberate for exactly this ordering.
      guarded('Uncaught-error logging failed', () {
        log.error(
          message,
          error: error,
          stackTrace: stackTrace,
          context: {
            'errorType': error.runtimeType.toString(),
            'library': ?library,
          },
        );
      });

      final record = UncaughtErrorRecord.capture(error, stackTrace);
      // Independent guards: a throwing recordError (e.g. invoked before
      // ShellObservability.initialize) must not prevent the reporter — the
      // component that uploads crashes — from being notified, and vice
      // versa. UncaughtErrorReporter.report's "called once per uncaught
      // error" contract depends on this.
      guarded('Uncaught-error slot update failed', () => recordError(record));
      guarded('Uncaught-error report failed', () => reporter.report(record));
    } finally {
      inCapture = false;
    }
  }

  FlutterError.onError = (details) {
    capture(
      () => (presentError ?? FlutterError.presentError)(details),
      'Uncaught framework error',
      details.exception,
      // Best-effort fallback: a framework error without a stack is rare;
      // when it happens the hook's own stack is a poorer localisation than
      // the (absent) failure site, but better than an empty trace.
      details.stack ?? StackTrace.current,
      library: details.library,
    );
  };

  PlatformDispatcher.instance.onError = (error, stackTrace) {
    // No presenter on the platform path; pass a no-op.
    capture(() {}, 'Uncaught platform error', error, stackTrace);
    return true;
  };
}
