import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:server_settings/server_settings.dart';

import 'support/fake_notification_remote.dart';
import 'support/fake_system_settings_remote.dart';

void main() {
  late FakeSystemSettingsRemote settings;
  late int waits;

  setUp(() {
    settings = FakeSystemSettingsRemote();
    waits = 0;
  });

  MailTestBloc build(FakeNotificationRemote notifications) => MailTestBloc(
    settings: settings,
    notifications: notifications,
    wait: (_) async => waits++,
  );

  final answered = MailTestResult.fromNotification(resultNotification('new1'))!;

  blocTest<MailTestBloc, MailTestState>(
    'reads the first new result, then marks it read',
    build: () => build(
      FakeNotificationRemote([
        [resultNotification('old1')],
        [resultNotification('new1'), resultNotification('old1')],
      ]),
    ),
    act: (bloc) => bloc.add(const MailTestRequested()),
    expect: () => [
      const MailTestSending(attempt: 1),
      const MailTestWaiting(attempt: 1),
      MailTestOutcome(attempt: 1, result: answered),
    ],
    verify: (bloc) {
      expect(settings.sendMailTestCalls, 1);
    },
  );

  test('marks only the new result read', () async {
    final notifications = FakeNotificationRemote([
      [resultNotification('old1')],
      [resultNotification('new1'), resultNotification('old1')],
    ]);
    final bloc = build(notifications)..add(const MailTestRequested());
    await bloc.stream.firstWhere((s) => s is MailTestOutcome);
    await pumpEventQueue();
    expect(notifications.markReadCalls, [
      ['new1'],
    ]);
    await bloc.close();
  });

  test('ignores notifications of other types', () async {
    final notifications = FakeNotificationRemote([
      const <UnreadNotification>[],
      [otherNotification('x'), resultNotification('new1')],
    ]);
    final bloc = build(notifications)..add(const MailTestRequested());
    final outcome = await bloc.stream.firstWhere(
      (s) => s is MailTestOutcome,
    ) as MailTestOutcome;
    expect(outcome.result, answered);
    await bloc.close();
  });

  test(
    'keeps polling while only old results are unread, then gives up',
    () async {
      final notifications = FakeNotificationRemote([
        [resultNotification('old1')],
      ]);
      final bloc = build(notifications)..add(const MailTestRequested());
      final last = await bloc.stream.firstWhere((s) => s is MailTestNoResult);
      expect(last, const MailTestNoResult(attempt: 1));
      expect(waits, 24);
      // One baseline read, then one per poll.
      expect(notifications.fetchCalls, 25);
      expect(notifications.markReadCalls, isEmpty);
      await bloc.close();
    },
  );

  test('reads that take time count toward the deadline', () async {
    // Ten polls fit the deadline on the waits alone. Each read takes at least
    // 50ms, so the second poll ends past it.
    final notifications = FakeNotificationRemote([
      const <UnreadNotification>[],
    ])..readDelay = const Duration(milliseconds: 50);
    final bloc = MailTestBloc(
      settings: settings,
      notifications: notifications,
      wait: (_) async => waits++,
      pollInterval: const Duration(milliseconds: 10),
      deadline: const Duration(milliseconds: 100),
    )..add(const MailTestRequested());
    addTearDown(bloc.close);

    final last = await bloc.stream.firstWhere((s) => s is MailTestNoResult);

    expect(last, const MailTestNoResult(attempt: 1));
    // One, if a slow machine stretches the first read past the deadline.
    expect(waits, inInclusiveRange(1, 2));
    expect(notifications.fetchCalls, waits + 1);
  });

  test('a failed baseline read sends nothing', () async {
    final notifications = FakeNotificationRemote([
      const NotificationTransientException('down'),
    ]);
    final bloc = build(notifications)..add(const MailTestRequested());
    final last = await bloc.stream.firstWhere((s) => s is MailTestNotSent);
    expect(
      last,
      const MailTestNotSent(attempt: 1, reason: MailTestNotSentReason.failed),
    );
    expect(settings.sendMailTestCalls, 0);
    await bloc.close();
  });

  final reasons = <String, (Exception, MailTestNotSentReason)>{
    '409': (
      const MailNotConfiguredException('x'),
      MailTestNotSentReason.notConfigured,
    ),
    '503': (
      const MailQueueUnavailableException('x'),
      MailTestNotSentReason.queueUnavailable,
    ),
    '403': (
      const SystemSettingsForbiddenException('x'),
      MailTestNotSentReason.refused,
    ),
    'transient': (
      const SystemSettingsTransientException('x'),
      MailTestNotSentReason.failed,
    ),
  };
  for (final MapEntry(key: name, value: (error, reason)) in reasons.entries) {
    test('a $name send is NotSent($reason)', () async {
      settings.sendMailTestError = error;
      final bloc = build(
        FakeNotificationRemote([const <UnreadNotification>[]]),
      )..add(const MailTestRequested());
      final last = await bloc.stream.firstWhere((s) => s is MailTestNotSent);
      expect(last, MailTestNotSent(attempt: 1, reason: reason));
      expect(waits, 0);
      await bloc.close();
    });
  }

  test('a poll that throws keeps polling', () async {
    final bloc = build(
      FakeNotificationRemote([
        const <UnreadNotification>[],
        const NotificationTransientException('down'),
        [resultNotification('new1')],
      ]),
    )..add(const MailTestRequested());
    final outcome = await bloc.stream.firstWhere((s) => s is MailTestOutcome);
    expect(outcome, MailTestOutcome(attempt: 1, result: answered));
    expect(waits, 2);
    await bloc.close();
  });

  test('a markRead failure leaves the outcome', () async {
    final notifications = FakeNotificationRemote([
      const <UnreadNotification>[],
      [resultNotification('new1')],
    ])..markReadError = const NotificationTransientException('down');
    final bloc = build(notifications);
    final states = <MailTestState>[];
    final sub = bloc.stream.listen(states.add);
    bloc.add(const MailTestRequested());
    await pumpEventQueue();
    expect(notifications.markReadCalls, [
      ['new1'],
    ]);
    expect(states.last, MailTestOutcome(attempt: 1, result: answered));
    await sub.cancel();
    await bloc.close();
  });

  test('a request after the outcome is taken while markRead is still '
      'out', () async {
    final markRead = Completer<void>();
    final notifications = FakeNotificationRemote([
      const <UnreadNotification>[],
      [resultNotification('new1')],
    ])..markReadGate = markRead.future;
    final bloc = build(notifications);
    final states = <MailTestState>[];
    final sub = bloc.stream.listen(states.add);
    bloc.add(const MailTestRequested());
    await bloc.stream.firstWhere((s) => s is MailTestOutcome);
    await pumpEventQueue();
    expect(notifications.markReadCalls, [
      ['new1'],
    ]);

    bloc.add(const MailTestRequested());
    await pumpEventQueue();

    expect(states, contains(const MailTestSending(attempt: 2)));
    markRead.complete();
    await sub.cancel();
    await bloc.close();
  });

  test('a request while waiting is dropped', () async {
    final release = Completer<void>();
    final notifications = FakeNotificationRemote([
      const <UnreadNotification>[],
      [resultNotification('new1')],
    ]);
    final bloc = MailTestBloc(
      settings: settings,
      notifications: notifications,
      wait: (_) => release.future,
    )..add(const MailTestRequested());
    await bloc.stream.firstWhere((s) => s is MailTestWaiting);
    bloc.add(const MailTestRequested());
    release.complete();
    await bloc.stream.firstWhere((s) => s is MailTestOutcome);
    await pumpEventQueue();
    expect(settings.sendMailTestCalls, 1);
    expect(bloc.state.attempt, 1);
    await bloc.close();
  });

  test('a request after an outcome runs again as attempt 2', () async {
    final notifications = FakeNotificationRemote([
      const <UnreadNotification>[],
      [resultNotification('new1')],
      [resultNotification('new1')],
      [resultNotification('new2'), resultNotification('new1')],
    ]);
    final bloc = build(notifications)..add(const MailTestRequested());
    await bloc.stream.firstWhere((s) => s is MailTestOutcome);
    await pumpEventQueue();
    bloc.add(const MailTestRequested());
    final second = await bloc.stream.firstWhere(
      (s) => s is MailTestOutcome,
    ) as MailTestOutcome;
    expect(second.attempt, 2);
    expect(settings.sendMailTestCalls, 2);
    await bloc.close();
  });

  test('closing while waiting sends no further fetchUnread', () async {
    final release = Completer<void>();
    final notifications = FakeNotificationRemote([
      const <UnreadNotification>[],
    ]);
    final bloc = MailTestBloc(
      settings: settings,
      notifications: notifications,
      wait: (_) => release.future,
    )..add(const MailTestRequested());
    await bloc.stream.firstWhere((s) => s is MailTestWaiting);
    final closing = bloc.close();
    release.complete();
    await closing;
    await pumpEventQueue();
    expect(notifications.fetchCalls, 1);
  });

  test('starts idle at attempt 0', () {
    final bloc = build(FakeNotificationRemote([const <UnreadNotification>[]]));
    expect(bloc.state, const MailTestIdle());
    expect(bloc.state.attempt, 0);
    addTearDown(bloc.close);
  });

  group('a test that ran out of time', () {
    MailTestBloc quick(FakeNotificationRemote notifications) => MailTestBloc(
      settings: settings,
      notifications: notifications,
      wait: (_) async {},
      pollInterval: const Duration(minutes: 1),
    );

    Future<MailTestOutcome> second(
      MailTestBloc bloc, {
      required List<Object> rest,
      required FakeNotificationRemote notifications,
    }) async {
      bloc.add(const MailTestRequested());
      await bloc.stream.firstWhere((s) => s is MailTestNoResult);
      notifications.reads.addAll(rest);
      bloc.add(const MailTestRequested());
      return await bloc.stream.firstWhere((s) => s is MailTestOutcome)
          as MailTestOutcome;
    }

    test('leaves the next outcome in doubt while its result is owed', () async {
      // Baseline, then two polls with nothing: the first test runs out.
      final notifications = FakeNotificationRemote([
        const <UnreadNotification>[],
        const <UnreadNotification>[],
        const <UnreadNotification>[],
      ]);
      final bloc = quick(notifications);
      addTearDown(bloc.close);

      final outcome = await second(
        bloc,
        notifications: notifications,
        rest: [
          const <UnreadNotification>[],
          [resultNotification('late', sent: false)],
        ],
      );

      expect(outcome.attempt, 2);
      expect(outcome.mayAnswerEarlierTest, isTrue);
    });

    test('is paid off by a result met in the next baseline', () async {
      final notifications = FakeNotificationRemote([
        const <UnreadNotification>[],
        const <UnreadNotification>[],
        const <UnreadNotification>[],
      ]);
      final bloc = quick(notifications);
      addTearDown(bloc.close);

      final outcome = await second(
        bloc,
        notifications: notifications,
        rest: [
          [resultNotification('late', sent: false)],
          [resultNotification('late', sent: false), resultNotification('new')],
        ],
      );

      expect(outcome.attempt, 2);
      expect(outcome.result.sent, isTrue);
      expect(outcome.mayAnswerEarlierTest, isFalse);
    });

    test('leaves only one outcome in doubt', () async {
      final notifications = FakeNotificationRemote([
        const <UnreadNotification>[],
        const <UnreadNotification>[],
        const <UnreadNotification>[],
      ]);
      final bloc = quick(notifications);
      addTearDown(bloc.close);
      await second(
        bloc,
        notifications: notifications,
        rest: [
          const <UnreadNotification>[],
          [resultNotification('a')],
          [resultNotification('a'), resultNotification('b')],
          [
            resultNotification('a'),
            resultNotification('b'),
            resultNotification('c'),
          ],
        ],
      );

      bloc.add(const MailTestRequested());
      final third = await bloc.stream.firstWhere(
        (s) => s is MailTestOutcome,
      ) as MailTestOutcome;

      // Attempt 2 took 'a'; 'b' paid off the first test in this baseline.
      expect(third.attempt, 3);
      expect(third.mayAnswerEarlierTest, isFalse);
    });
  });

  test('a first outcome is not in doubt', () async {
    final bloc = build(
      FakeNotificationRemote([
        [resultNotification('old1')],
        [resultNotification('new1'), resultNotification('old1')],
      ]),
    )..add(const MailTestRequested());
    addTearDown(bloc.close);

    final outcome = await bloc.stream.firstWhere(
      (s) => s is MailTestOutcome,
    ) as MailTestOutcome;
    expect(outcome.mayAnswerEarlierTest, isFalse);
  });

  group('Cleared', () {
    final ends = <String, (FakeNotificationRemote Function(), Type)>{
      'an outcome': (
        () => FakeNotificationRemote([
          const <UnreadNotification>[],
          [resultNotification('new1')],
        ]),
        MailTestOutcome,
      ),
      'no result': (
        () => FakeNotificationRemote([const <UnreadNotification>[]]),
        MailTestNoResult,
      ),
      'not sent': (
        () => FakeNotificationRemote([
          const NotificationTransientException('down'),
        ]),
        MailTestNotSent,
      ),
    };
    for (final MapEntry(key: name, value: (notifications, end))
        in ends.entries) {
      test('retires $name to idle at the same attempt', () async {
        final bloc = build(notifications())..add(const MailTestRequested());
        await bloc.stream.firstWhere((s) => s.runtimeType == end);
        await pumpEventQueue();

        bloc.add(const MailTestCleared());
        await pumpEventQueue();

        expect(bloc.state, const MailTestIdle(attempt: 1));
        await bloc.close();
      });
    }

    test('while waiting, keeps waiting, then retires the outcome as it '
        'lands, and still marks it read', () async {
      final release = Completer<void>();
      final notifications = FakeNotificationRemote([
        const <UnreadNotification>[],
        [resultNotification('new1')],
      ]);
      final bloc = MailTestBloc(
        settings: settings,
        notifications: notifications,
        wait: (_) => release.future,
      )..add(const MailTestRequested());
      await bloc.stream.firstWhere((s) => s is MailTestWaiting);

      bloc.add(const MailTestCleared());
      await pumpEventQueue();
      expect(bloc.state, const MailTestWaiting(attempt: 1));

      release.complete();
      await pumpEventQueue();
      expect(bloc.state, const MailTestIdle(attempt: 1));
      expect(notifications.markReadCalls, [
        ['new1'],
      ]);
      await bloc.close();
    });

    test('while waiting, retires no result too', () async {
      final release = Completer<void>();
      final bloc = MailTestBloc(
        settings: settings,
        notifications: FakeNotificationRemote([
          const <UnreadNotification>[],
        ]),
        wait: (_) => release.future,
        pollInterval: const Duration(minutes: 2),
      )..add(const MailTestRequested());
      await bloc.stream.firstWhere((s) => s is MailTestWaiting);

      bloc.add(const MailTestCleared());
      release.complete();
      await pumpEventQueue();

      expect(bloc.state, const MailTestIdle(attempt: 1));
      await bloc.close();
    });

    test('while sending, retires a send that fails', () async {
      final release = Completer<void>();
      settings
        ..sendMailTestGate = release
        ..sendMailTestError = const MailNotConfiguredException('x');
      final bloc = build(FakeNotificationRemote([const <UnreadNotification>[]]))
        ..add(const MailTestRequested());
      await bloc.stream.firstWhere((s) => s is MailTestSending);

      bloc.add(const MailTestCleared());
      await pumpEventQueue();
      expect(bloc.state, const MailTestSending(attempt: 1));

      release.complete();
      await pumpEventQueue();
      expect(bloc.state, const MailTestIdle(attempt: 1));
      await bloc.close();
    });

    test('a retired test leaves the next one its outcome', () async {
      final release = Completer<void>();
      var gated = true;
      final bloc = MailTestBloc(
        settings: settings,
        notifications: FakeNotificationRemote([
          const <UnreadNotification>[],
          [resultNotification('new1')],
          [resultNotification('new1')],
          [resultNotification('new1'), resultNotification('new2')],
        ]),
        wait: (_) => gated ? release.future : Future<void>.value(),
      )..add(const MailTestRequested());
      await bloc.stream.firstWhere((s) => s is MailTestWaiting);
      bloc.add(const MailTestCleared());
      gated = false;
      release.complete();
      await pumpEventQueue();
      expect(bloc.state, const MailTestIdle(attempt: 1));

      bloc.add(const MailTestRequested());
      final outcome = await bloc.stream.firstWhere(
        (s) => s is MailTestOutcome,
      );
      expect(outcome.attempt, 2);
      await bloc.close();
    });

    blocTest<MailTestBloc, MailTestState>(
      'is ignored while idle',
      build: () =>
          build(FakeNotificationRemote([const <UnreadNotification>[]])),
      act: (bloc) => bloc.add(const MailTestCleared()),
      expect: () => <MailTestState>[],
    );
  });
}
