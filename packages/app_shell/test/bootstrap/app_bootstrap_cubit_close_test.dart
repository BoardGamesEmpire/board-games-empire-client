import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:observability/observability.dart';

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
    // Recorded before the throw: the reset really did run, and a fake that
    // skips super leaves `calls`/`resetCallCount` lying about it.
    await super.reset();
    throw StateError('reset failed after the cubit was closed');
  }
}

/// A bootstrap whose destructive [reset] parks until released and then
/// **succeeds** — the one caller that reaches `_attempt` already closed,
/// because `resetAndRetry` falls through to it on the success leg.
class _GatedSuccessfulResetBootstrap extends FakePlatformBootstrap {
  _GatedSuccessfulResetBootstrap(Object initializeFailure)
    : super(outcomes: [initializeFailure]);

  final gate = Completer<void>();
  var resetStarted = false;

  @override
  Future<void> reset() async {
    resetStarted = true;
    await gate.future;
    await super.reset();
  }
}

/// Counts the drains the transition callback would trigger.
class _CountingFeedbackService implements FeedbackService {
  int drainCalls = 0;

  @override
  Future<int> drainPending() async {
    drainCalls += 1;
    return 0;
  }

  @override
  FeedbackReport buildReport({
    required FeedbackCategory category,
    FeedbackSeverity? severity,
    String? title,
    String? errorMessage,
    String? stackTrace,
    String? userComment,
    String? clientRequestId,
  }) => throw UnimplementedError();

  @override
  Future<FeedbackSubmitResult> submit(FeedbackReport report) =>
      throw UnimplementedError();
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
      final bootstrap = FakePlatformBootstrap();
      final cubit = AppBootstrapCubit(
        platformBootstrap: bootstrap,
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
      // Not merely "emitted nothing": the attempt must not have *started*
      // the resource-acquiring half. On native `initialize()` opens the
      // encrypted meta database and builds the orchestrator, and nothing
      // is left to dispose either.
      expect(
        bootstrap.initializeCallCount,
        0,
        reason:
            'a close inside the hydrated-storage await must stop the attempt '
            'before it acquires anything',
      );
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
      expect(bootstrap.resetCallCount, 1);
    });

    test('a reset that SUCCEEDS after the close does not run the bootstrap '
        'it would normally fall through to', () async {
      final bootstrap = _GatedSuccessfulResetBootstrap(
        Exception('meta db open failed'),
      );
      final cubit = AppBootstrapCubit(
        platformBootstrap: bootstrap,
        hydratedStorageInitializer: (_) async {},
        resetOfferThreshold: 1,
      );

      await cubit.initialize();
      expect(bootstrap.initializeCallCount, 1);

      final recovery = cubit.resetAndRetry();
      await pumpEventQueue();
      expect(bootstrap.resetStarted, isTrue);

      await cubit.close();
      bootstrap.gate.complete();
      await expectLater(recovery, completes);

      // The distinct leg: the reset succeeded, so `resetAndRetry` walks on
      // into `_attempt`. Every emit guard downstream would still let the
      // attempt open the meta database and build an orchestrator that no
      // one is left to dispose — only the entry guard stops it.
      expect(
        bootstrap.initializeCallCount,
        1,
        reason: 'a closed cubit must attempt no bootstrap after a reset',
      );
    });
  });

  group('the transition callbacks on a closed cubit', () {
    /// Builds a cubit, drives it to [stage]'s state, then closes it — the
    /// caller asserts that its callback is a no-op from there.
    Future<AppBootstrapCubit> closedIn(
      Future<void> Function(AppBootstrapCubit cubit) stage, {
      List<Object> outcomes = const [],
      int resetOfferThreshold = 3,
      FeedbackService? feedbackService,
    }) async {
      final cubit = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(outcomes: outcomes),
        hydratedStorageInitializer: (_) async {},
        feedbackService: feedbackService,
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

    test('onAuthenticated() drains no queued feedback — the guard sits ahead '
        'of the drain, not merely ahead of the emit', () async {
      final feedback = _CountingFeedbackService();
      final cubit = await closedIn(
        (c) => c.initialize(),
        feedbackService: feedback,
      );

      cubit.onAuthenticated();
      await pumpEventQueue();

      // The drain fires on *every* live invocation, including ones whose
      // state transition is a no-op, so "no throw" alone cannot tell the
      // guard's placement apart from the emit guard it sits above.
      expect(feedback.drainCalls, 0);
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
