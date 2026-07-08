import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:observability/observability.dart';

void main() {
  tearDown(ShellObservability.reset);

  group('ShellObservability', () {
    test('breadcrumbs throws before initialize() so ordering bugs fail '
        'fast instead of reporting empty history', () {
      expect(() => ShellObservability.breadcrumbs, throwsStateError);
      expect(ShellObservability.isInitialized, isFalse);
    });

    test('initialize() attaches the buffer and BgeLogger records land in '
        'it as breadcrumbs', () {
      ShellObservability.initialize();

      expect(ShellObservability.isInitialized, isTrue);
      expect(ShellObservability.breadcrumbs.isAttached, isTrue);

      BgeLogger(
        'bge.test.shell_observability',
      ).error('boom', context: {'answer': 42});

      final crumbs = ShellObservability.breadcrumbs.snapshot();
      expect(crumbs, isNotEmpty);
      final crumb = crumbs.last;
      expect(crumb.loggerName, 'bge.test.shell_observability');
      expect(crumb.level, BgeLogLevel.error);
      expect(crumb.message, 'boom');
    });

    test('captures verbose records too — the ring buffer, not the root '
        'level, is the retention policy', () {
      ShellObservability.initialize();

      BgeLogger('bge.test.verbose').verbose('fine-grained detail');

      expect(
        ShellObservability.breadcrumbs.snapshot().where(
          (c) => c.message == 'fine-grained detail',
        ),
        hasLength(1),
      );
    });

    test('initialize() is idempotent and keeps the first buffer', () {
      final buffer = BreadcrumbBuffer(capacity: 5);
      ShellObservability.initialize(buffer: buffer);
      ShellObservability.initialize();

      expect(ShellObservability.breadcrumbs, same(buffer));
    });

    test('reset() restores the prior Logger.root.level so the Level.ALL '
        'override does not leak across tests or into embedding apps', () async {
      Logger.root.level = Level.WARNING;

      ShellObservability.initialize();
      expect(Logger.root.level, Level.ALL);

      await ShellObservability.reset();
      expect(Logger.root.level, Level.WARNING);
    });
  });

  group('ShellObservability.lastUncaughtError (issue #34)', () {
    // Single-slot, RAM-only crash record. Stack traces stay OUT of the
    // BreadcrumbBuffer by design (dedicated `stackTrace` DTO field on the
    // backend, traces aren't pattern-redacted, and the ring must stay
    // small); this slot is where the last uncaught error's full detail
    // lives until the user submits — or declines — a feedback report.

    UncaughtErrorRecord record([String message = 'boom']) =>
        UncaughtErrorRecord.capture(StateError(message), StackTrace.current);

    test('throws before initialize() — same fail-fast contract as '
        'breadcrumbs', () {
      expect(() => ShellObservability.lastUncaughtError, throwsStateError);
    });

    test('recordUncaughtError throws before initialize() rather than '
        'silently dropping a crash', () {
      expect(
        () => ShellObservability.recordUncaughtError(record()),
        throwsStateError,
      );
    });

    test('starts empty after initialize()', () {
      ShellObservability.initialize();

      expect(ShellObservability.lastUncaughtError.value, isNull);
    });

    test('recordUncaughtError publishes the record and notifies listeners '
        'so the feedback prompt can react instead of polling', () {
      ShellObservability.initialize();
      var notifications = 0;
      ShellObservability.lastUncaughtError.addListener(() => notifications++);

      final crash = record();
      ShellObservability.recordUncaughtError(crash);

      expect(ShellObservability.lastUncaughtError.value, same(crash));
      expect(notifications, 1);
    });

    test('a second record replaces the first — single slot, most recent '
        'crash wins', () {
      ShellObservability.initialize();

      ShellObservability.recordUncaughtError(record('first'));
      final second = record('second');
      ShellObservability.recordUncaughtError(second);

      expect(ShellObservability.lastUncaughtError.value, same(second));
    });

    test('clearUncaughtError empties the slot and notifies — called after '
        'a report is submitted or the user declines', () {
      ShellObservability.initialize();
      ShellObservability.recordUncaughtError(record());
      var notifications = 0;
      ShellObservability.lastUncaughtError.addListener(() => notifications++);

      ShellObservability.clearUncaughtError();

      expect(ShellObservability.lastUncaughtError.value, isNull);
      expect(notifications, 1);
    });

    test('reset() drops the recorded error so crash state cannot leak '
        'across tests or re-initializations', () async {
      ShellObservability.initialize();
      ShellObservability.recordUncaughtError(record());

      await ShellObservability.reset();
      ShellObservability.initialize();

      expect(ShellObservability.lastUncaughtError.value, isNull);
    });
  });
}
