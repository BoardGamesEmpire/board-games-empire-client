import 'dart:ui';

import 'package:app_shell/app_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

/// Red-phase tests for `installGlobalErrorHooks` (issue #34).
///
/// Design decisions pinned here (see #34 for rationale):
///
/// - **No custom Zone.** Per official Flutter guidance (3.3+),
///   `PlatformDispatcher.instance.onError` supersedes `runZonedGuarded`;
///   these hooks are the entire catch-all surface.
/// - **Idempotent re-installation.** The framework hook delegates to an
///   injectable `presentError` (defaulting to `FlutterError.presentError`,
///   a fixed target) and never reads/chains the previous handler, so hot
///   restart cannot grow a handler chain or duplicate reports.
/// - **`onError` returns `true` unconditionally** after capture —
///   returning `false` can hard-crash the app.
/// - **Reporter failures are swallowed.** A crash inside crash reporting
///   must never take the app down or re-enter the hooks.
///
/// Presentation of build failures (`ErrorWidget.builder`) is deliberately
/// NOT wired here — split to #66 to keep this unit capture-only.
///
/// Handlers are process globals, so every test saves and restores both
/// hooks; leaking a test handler would corrupt the rest of the suite.
class _RecordingReporter implements UncaughtErrorReporter {
  final List<UncaughtErrorRecord> records = [];

  @override
  void report(UncaughtErrorRecord record) => records.add(record);
}

class _ThrowingReporter implements UncaughtErrorReporter {
  @override
  void report(UncaughtErrorRecord record) =>
      throw StateError('reporter exploded');
}

/// A reporter that counts calls — used to prove the reporter still fires
/// when the *other* side effect (recordError) throws.
class _CountingReporter implements UncaughtErrorReporter {
  int calls = 0;

  @override
  void report(UncaughtErrorRecord record) => calls++;
}

void main() {
  late FlutterExceptionHandler? savedFlutterOnError;
  late ErrorCallback? savedDispatcherOnError;

  setUp(() {
    savedFlutterOnError = FlutterError.onError;
    savedDispatcherOnError = PlatformDispatcher.instance.onError;
  });

  tearDown(() async {
    FlutterError.onError = savedFlutterOnError;
    PlatformDispatcher.instance.onError = savedDispatcherOnError;
    await ShellObservability.reset();
  });

  FlutterErrorDetails frameworkDetails({Object? exception}) =>
      FlutterErrorDetails(
        exception: exception ?? StateError('framework boom'),
        stack: StackTrace.current,
        library: 'test harness',
      );

  group('installGlobalErrorHooks — FlutterError.onError', () {
    test('delegates to the injected presentError so console output '
        'survives, then reports exactly once', () {
      final presented = <FlutterErrorDetails>[];
      final reporter = _RecordingReporter();
      installGlobalErrorHooks(
        presentError: presented.add,
        reporter: reporter,
        recordError: (_) {},
      );

      final details = frameworkDetails();
      FlutterError.onError!(details);

      expect(presented, [same(details)]);
      expect(reporter.records, hasLength(1));
    });

    test('the reported record carries the redacted message, error type, '
        'and original stack trace', () {
      final reporter = _RecordingReporter();
      UncaughtErrorRecord? recorded;
      installGlobalErrorHooks(
        presentError: (_) {},
        reporter: reporter,
        recordError: (record) => recorded = record,
      );

      final trace = StackTrace.current;
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: Exception('failed for john.doe@email.com'),
          stack: trace,
          library: 'test harness',
        ),
      );

      final record = reporter.records.single;
      expect(record.message, contains('j**n.d*e@email.com'));
      expect(record.message, isNot(contains('john.doe@email.com')));
      expect(record.stackTrace, same(trace));
      expect(
        recorded,
        same(record),
        reason:
            'the same record instance feeds the last-error slot and '
            'the reporter — one capture, two consumers',
      );
    });

    test('a throwing reporter is swallowed — a crash inside crash '
        'reporting must not propagate — and the failure is logged at warn '
        'so it never becomes silent', () {
      ShellObservability.initialize();
      installGlobalErrorHooks(
        presentError: (_) {},
        reporter: _ThrowingReporter(),
        recordError: (_) {},
      );

      expect(() => FlutterError.onError!(frameworkDetails()), returnsNormally);

      final warns = ShellObservability.breadcrumbs.snapshot().where(
        (c) =>
            c.level == BgeLogLevel.warn &&
            c.message ==
                'Uncaught-error '
                    'report failed',
      );
      expect(warns, hasLength(1));
    });
  });

  group('installGlobalErrorHooks — PlatformDispatcher.onError', () {
    test('captures the error and returns true unconditionally', () {
      final reporter = _RecordingReporter();
      installGlobalErrorHooks(
        presentError: (_) {},
        reporter: reporter,
        recordError: (_) {},
      );

      final handler = PlatformDispatcher.instance.onError;
      expect(handler, isNotNull);

      final handled = handler!(StateError('async boom'), StackTrace.current);

      expect(handled, isTrue);
      expect(reporter.records, hasLength(1));
      expect(reporter.records.single.errorType, 'StateError');
    });

    test('returns true even when the reporter throws — capture failure '
        'must not let the engine treat the error as unhandled', () {
      installGlobalErrorHooks(
        presentError: (_) {},
        reporter: _ThrowingReporter(),
        recordError: (_) {},
      );

      final handled = PlatformDispatcher.instance.onError!(
        StateError('async boom'),
        StackTrace.current,
      );

      expect(handled, isTrue);
    });
  });

  group('installGlobalErrorHooks — independent side-effect guards', () {
    test('a throwing recordError does not starve the reporter — the '
        'component that uploads crashes must still be notified', () {
      final reporter = _CountingReporter();
      installGlobalErrorHooks(
        presentError: (_) {},
        reporter: reporter,
        recordError: (_) => throw StateError('slot not ready'),
      );

      expect(() => FlutterError.onError!(frameworkDetails()), returnsNormally);
      expect(reporter.calls, 1);
    });

    test('a throwing presentError does not skip capture', () {
      final reporter = _RecordingReporter();
      installGlobalErrorHooks(
        presentError: (_) => throw StateError('bad presenter'),
        reporter: reporter,
        recordError: (_) {},
      );

      expect(() => FlutterError.onError!(frameworkDetails()), returnsNormally);
      expect(reporter.records, hasLength(1));
    });

    test('presentError runs even for the platform path is not applicable — '
        'the platform hook still captures with a no-op presenter', () {
      final reporter = _RecordingReporter();
      installGlobalErrorHooks(
        presentError: (_) => fail(
          'presentError must not run on the '
          'platform path',
        ),
        reporter: reporter,
        recordError: (_) {},
      );

      PlatformDispatcher.instance.onError!(
        StateError('async boom'),
        StackTrace.current,
      );
      expect(reporter.records, hasLength(1));
    });
  });

  group('installGlobalErrorHooks — re-entrancy guard', () {
    test('a last-error listener that throws does not cause an unbounded '
        'capture storm; the nested error is logged and side effects are '
        'skipped', () {
      ShellObservability.initialize();
      // A real listener on the slot that throws — exactly the shape a buggy
      // FeedbackService listener would take. Its throw routes through
      // ChangeNotifier.notifyListeners → FlutterError.reportError →
      // FlutterError.onError, re-entering capture.
      ShellObservability.lastUncaughtError.addListener(
        () => throw StateError('listener exploded'),
      );
      installGlobalErrorHooks(presentError: (_) {});

      // Without the guard this recurses to a StackOverflowError.
      expect(() => FlutterError.onError!(frameworkDetails()), returnsNormally);

      final reentrantWarns = ShellObservability.breadcrumbs.snapshot().where(
        (c) =>
            c.level == BgeLogLevel.warn &&
            c.message.startsWith('Re-entrant uncaught error'),
      );
      expect(reentrantWarns, isNotEmpty);
    });
  });

  test('installing twice does not chain handlers: one framework error '
      'still presents and reports exactly once (hot-restart safety)', () {
    final presented = <FlutterErrorDetails>[];
    final reporter = _RecordingReporter();
    void install() => installGlobalErrorHooks(
      presentError: presented.add,
      reporter: reporter,
      recordError: (_) {},
    );

    install();
    install();

    FlutterError.onError!(frameworkDetails());
    expect(presented, hasLength(1));
    expect(reporter.records, hasLength(1));
  });

  test('installing twice reports one dispatcher error exactly once', () {
    final reporter = _RecordingReporter();
    void install() => installGlobalErrorHooks(
      presentError: (_) {},
      reporter: reporter,
      recordError: (_) {},
    );

    install();
    install();

    PlatformDispatcher.instance.onError!(
      StateError('async boom'),
      StackTrace.current,
    );
    expect(reporter.records, hasLength(1));
  });

  group('installGlobalErrorHooks — observability integration (defaults)', () {
    test('an uncaught framework error lands as a redaction-safe breadcrumb '
        'with the error type in context, and fills the last-error slot', () {
      ShellObservability.initialize();
      installGlobalErrorHooks(presentError: (_) {});

      FlutterError.onError!(frameworkDetails());

      final crumb = ShellObservability.breadcrumbs.snapshot().last;
      expect(crumb.message, 'Uncaught framework error');
      expect(crumb.loggerName, 'bge.shell.uncaught');
      expect(crumb.level, BgeLogLevel.error);
      expect(crumb.sanitizedContext, containsPair('errorType', 'StateError'));

      final last = ShellObservability.lastUncaughtError.value;
      expect(last, isNotNull);
      expect(last!.errorType, 'StateError');
    });

    test('an uncaught platform error breadcrumbs as "Uncaught platform '
        'error" and fills the last-error slot', () {
      ShellObservability.initialize();
      installGlobalErrorHooks(presentError: (_) {});

      PlatformDispatcher.instance.onError!(
        FormatException('bad payload'),
        StackTrace.current,
      );

      final crumb = ShellObservability.breadcrumbs.snapshot().last;
      expect(crumb.message, 'Uncaught platform error');
      expect(
        crumb.sanitizedContext,
        containsPair('errorType', 'FormatException'),
      );
      expect(
        ShellObservability.lastUncaughtError.value?.errorType,
        'FormatException',
      );
    });
  });
}
