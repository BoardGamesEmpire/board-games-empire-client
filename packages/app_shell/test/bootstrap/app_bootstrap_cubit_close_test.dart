import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

import '../support/fake_platform_bootstrap.dart';

/// A [HydratedStorageInitializer] that blocks until the test releases it.
///
/// The close-during-attempt window is otherwise unobservable: every await
/// inside `_attempt` resolves within one microtask against the fakes, so a
/// `close()` can never land inside it. Gating the first await holds the
/// attempt open for as long as the test needs.
class _GatedHydratedInitializer {
  final gate = Completer<void>();
  var started = false;

  Future<void> call(PlatformBootstrap _) async {
    started = true;
    await gate.future;
  }
}

/// A bootstrap whose destructive [reset] parks until released and then
/// fails — the second awaited window a `close()` can land inside.
class _GatedResetBootstrap extends FakePlatformBootstrap {
  _GatedResetBootstrap(Object initializeFailure)
    : super(outcomes: [initializeFailure]);

  final gate = Completer<void>();
  var resetStarted = false;

  @override
  Future<void> reset() async {
    resetStarted = true;
    await gate.future;
    throw StateError('reset failed after the cubit was closed');
  }
}

void main() {
  /// Captures every record the cubit's logger emits for the duration of a
  /// test, so "no breadcrumb" can be asserted rather than assumed.
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

  Iterable<LogRecord> bootstrapFailures(List<LogRecord> records) =>
      records.where(
        (r) => r.loggerName == 'bge.shell.bootstrap' && r.level == Level.SEVERE,
      );

  group('close() during an in-flight attempt', () {
    test('is a clean no-op: nothing escapes the future, and no failure '
        'breadcrumb is recorded for a bootstrap that did not fail', () async {
      final records = captureLogs();
      final hydrated = _GatedHydratedInitializer();
      final cubit = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(),
        hydratedStorageInitializer: hydrated.call,
      );

      final attempt = cubit.initialize();
      await pumpEventQueue();
      expect(
        hydrated.started,
        isTrue,
        reason: 'the attempt must be parked inside the gate',
      );

      await cubit.close();
      hydrated.gate.complete();

      await expectLater(attempt, completes);
      expect(bootstrapFailures(records), isEmpty);
    });

    test('is a clean no-op for the destructive reset leg too — its failure '
        'path emits from behind the same guard', () async {
      final records = captureLogs();
      final bootstrap = _GatedResetBootstrap(Exception('meta db open failed'));
      final cubit = AppBootstrapCubit(
        platformBootstrap: bootstrap,
        hydratedStorageInitializer: (_) async {},
        resetOfferThreshold: 1,
      );

      await cubit.initialize();
      final failed = cubit.state;
      expect(failed, isA<AppBootstrapFailed>());
      expect((failed as AppBootstrapFailed).canOfferReset, isTrue);

      final recovery = cubit.resetAndRetry();
      await pumpEventQueue();
      expect(
        bootstrap.resetStarted,
        isTrue,
        reason: 'the recovery must be parked inside the gate',
      );

      final failuresBeforeClose = bootstrapFailures(records).length;
      await cubit.close();
      bootstrap.gate.complete();

      await expectLater(recovery, completes);
      expect(bootstrapFailures(records), hasLength(failuresBeforeClose));
    });
  });

  group('the transition callbacks on a closed cubit', () {
    /// Builds a cubit, drives it to [stage]'s state, then closes it — the
    /// caller asserts that its callback is a no-op from there.
    Future<AppBootstrapCubit> closedIn(
      Future<void> Function(AppBootstrapCubit cubit) stage, {
      List<Object> outcomes = const [],
      int resetOfferThreshold = 3,
    }) async {
      final cubit = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(outcomes: outcomes),
        hydratedStorageInitializer: (_) async {},
        resetOfferThreshold: resetOfferThreshold,
      );
      await stage(cubit);
      await cubit.close();
      return cubit;
    }

    test('onServerRegistered() does not throw', () async {
      final cubit = await closedIn(
        (c) => c.initialize(),
        outcomes: const [BootstrapResult(hasServer: false)],
      );

      expect(cubit.onServerRegistered, returnsNormally);
    });

    test('onAuthenticated() does not throw — its caller invokes it after an '
        'await, so a closed cubit is reachable', () async {
      final cubit = await closedIn((c) => c.initialize());

      expect(cubit.onAuthenticated, returnsNormally);
    });

    test('onSignedOut() does not throw', () async {
      final cubit = await closedIn((c) async {
        await c.initialize();
        c.onAuthenticated();
      });

      expect(cubit.onSignedOut, returnsNormally);
    });

    test('retry() does not throw', () async {
      final cubit = await closedIn(
        (c) => c.initialize(),
        outcomes: [Exception('meta db open failed')],
      );

      await expectLater(cubit.retry(), completes);
    });

    test('resetAndRetry() does not throw', () async {
      final cubit = await closedIn(
        (c) => c.initialize(),
        outcomes: [Exception('meta db open failed')],
        resetOfferThreshold: 1,
      );

      await expectLater(cubit.resetAndRetry(), completes);
    });
  });
}
