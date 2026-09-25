import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:app_shell/app_shell.dart';
import 'package:app_shell/src/bootstrap/shell_teardown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import '../support/fake_platform_bootstrap.dart';
import '../support/spy_root_container.dart';

/// The app's one teardown (#384), and the exit hook that runs it (#226).
void main() {
  List<LogRecord> captureLogs() {
    final records = <LogRecord>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await subscription.cancel();
      Logger.root.level = previousLevel;
    });
    return records;
  }

  late FakePlatformBootstrap bootstrap;
  late AppBootstrapCubit cubit;
  late SpyRootContainer rootContainer;

  setUp(() {
    bootstrap = FakePlatformBootstrap();
    cubit = AppBootstrapCubit(
      platformBootstrap: bootstrap,
      hydratedStorageInitializer: (_) async {},
    );
    rootContainer = SpyRootContainer();
  });

  ShellTeardown buildTeardown({
    Duration exitDeadline = const Duration(seconds: 2),
  }) => ShellTeardown(
    bootstrapCubit: cubit,
    platformBootstrap: bootstrap,
    rootContainer: rootContainer,
    exitDeadline: exitDeadline,
  );

  group('ShellTeardown.run', () {
    test('closes the cubit, then disposes the platform bootstrap, then the '
        'root container', () async {
      bool? cubitClosedBeforeBootstrap;
      bool? containerOpenDuringBootstrap;
      bootstrap.onDispose = () async {
        cubitClosedBeforeBootstrap = cubit.isClosed;
        containerOpenDuringBootstrap = !rootContainer.disposed;
      };

      await buildTeardown().run();

      expect(
        cubitClosedBeforeBootstrap,
        isTrue,
        reason:
            'a live cubit could start a retry on a bootstrap that is '
            'already closing',
      );
      expect(containerOpenDuringBootstrap, isTrue);
      expect(rootContainer.disposed, isTrue);
    });

    test('runs once: a second caller waits for the teardown the first '
        'started', () async {
      final closing = Completer<void>();
      bootstrap.onDispose = () => closing.future;
      final teardown = buildTeardown();

      unawaited(teardown.run());
      var secondReturned = false;
      final second = teardown.run().then((_) => secondReturned = true);
      await pumpEventQueue();

      expect(
        secondReturned,
        isFalse,
        reason:
            'the exit hook and the widget unmount share this teardown; '
            'whichever comes second must not return mid-close',
      );
      closing.complete();
      await second;
      expect(bootstrap.disposeCallCount, 1);
      expect(rootContainer.disposeCallCount, 1);
    });

    test('a failing step is breadcrumbed at warn and does not skip the '
        'next', () async {
      final records = captureLogs();
      final failure = StateError('orchestrator dispose exploded');
      bootstrap.onDispose = () async => throw failure;

      await expectLater(buildTeardown().run(), completes);

      expect(
        rootContainer.disposed,
        isTrue,
        reason: 'one step failing must not leave the next one open',
      );
      expect(
        records.where(
          (r) =>
              r.loggerName == 'bge.shell.teardown' &&
              r.level == Level.WARNING &&
              identical(r.error, failure),
        ),
        hasLength(1),
      );
    });
  });

  group('ShellTeardown.onExitRequested', () {
    test('answers only after the teardown has closed everything, and '
        'grants the exit', () async {
      final closing = Completer<void>();
      bootstrap.onDispose = () => closing.future;

      AppExitResponse? response;
      final answer = buildTeardown().onExitRequested().then((r) {
        response = r;
      });
      await pumpEventQueue();

      expect(
        response,
        isNull,
        reason: 'an answer now would let the process exit mid-close (#226)',
      );
      closing.complete();
      await answer;
      expect(response, AppExitResponse.exit);
      expect(rootContainer.disposed, isTrue);
    });

    test('grants the exit at the deadline when the teardown hangs, and '
        'breadcrumbs it at warn', () async {
      final records = captureLogs();
      bootstrap.onDispose = () => Completer<void>().future;

      final response = await buildTeardown(
        exitDeadline: const Duration(milliseconds: 10),
      ).onExitRequested();

      expect(
        response,
        AppExitResponse.exit,
        reason: 'a quit that hangs is worse than the crash (#226)',
      );
      expect(
        records.where(
          (r) =>
              r.loggerName == 'bge.shell.teardown' && r.level == Level.WARNING,
        ),
        hasLength(1),
      );
    });
  });

  group('ShellTeardown.listenForExit', () {
    testWidgets('may only be called once — a second exit listener would '
        'answer the same request twice', (tester) async {
      final teardown = buildTeardown()..listenForExit();
      addTearDown(teardown.run);

      expect(teardown.listenForExit, throwsStateError);
    });
  });
}
