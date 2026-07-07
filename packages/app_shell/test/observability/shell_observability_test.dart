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
}
