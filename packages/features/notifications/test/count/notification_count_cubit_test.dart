import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';
import 'package:notifications/src/count/notification_count_cubit.dart';
import 'package:notifications/src/count/notification_count_state.dart';

import '../support/fake_notification_remote.dart';

void main() {
  late FakeNotificationRemote remote;
  late NotificationCountCubit cubit;

  setUp(() {
    remote = FakeNotificationRemote();
    cubit = NotificationCountCubit(remote);
  });

  tearDown(() => cubit.close());

  test('starts unknown', () {
    expect(cubit.state, const NotificationCountState());
    expect(cubit.state.unread, isNull);
    expect(cubit.state.refreshing, isFalse);
  });

  test('refresh reads the unread count', () async {
    remote.scriptUnreadCounts([3]);

    final states = <NotificationCountState>[];
    final sub = cubit.stream.listen(states.add);
    await cubit.refresh();
    await pumpEventQueue();
    await sub.cancel();

    expect(cubit.state.unread, 3);
    expect(cubit.state.refreshing, isFalse);
    expect(states, const [
      NotificationCountState(refreshing: true),
      NotificationCountState(unread: 3),
    ]);
  });

  test('refresh does not cap the count', () async {
    remote.scriptUnreadCounts([250]);

    await cubit.refresh();

    expect(cubit.state.unread, 250);
  });

  test('a failed refresh keeps the last count', () async {
    remote.scriptUnreadCounts([
      3,
      const NotificationTransientException('offline'),
    ]);

    await cubit.refresh();
    await cubit.refresh();

    expect(cubit.state.unread, 3);
    expect(cubit.state.refreshing, isFalse);
  });

  test('a failed first refresh leaves the count unknown', () async {
    remote.scriptUnreadCounts([
      const NotificationPermanentException('no', statusCode: 403),
    ]);

    await cubit.refresh();

    expect(cubit.state.unread, isNull);
    expect(cubit.state.refreshing, isFalse);
  });

  test('a refresh started while another is in flight wins', () async {
    final first = Completer<int>();
    final second = Completer<int>();
    remote.scriptUnreadCounts([first.future, second.future]);

    final firstRefresh = cubit.refresh();
    final secondRefresh = cubit.refresh();
    second.complete(7);
    await secondRefresh;
    expect(cubit.state.unread, 7);
    expect(cubit.state.refreshing, isFalse);

    first.complete(1);
    await firstRefresh;

    expect(cubit.state.unread, 7);
    expect(cubit.state.refreshing, isFalse);
  });

  test(
    'an earlier refresh that fails late does not clear refreshing',
    () async {
      final first = Completer<int>();
      final second = Completer<int>();
      remote.scriptUnreadCounts([first.future, second.future]);

      final firstRefresh = cubit.refresh();
      final secondRefresh = cubit.refresh();
      first.completeError(const NotificationTransientException('offline'));
      await firstRefresh;

      expect(cubit.state.refreshing, isTrue);

      second.complete(2);
      await secondRefresh;
      expect(cubit.state.unread, 2);
      expect(cubit.state.refreshing, isFalse);
    },
  );

  test('a refresh that lands after close emits nothing', () async {
    final pending = Completer<int>();
    remote.scriptUnreadCounts([pending.future]);

    final refresh = cubit.refresh();
    await cubit.close();
    pending.complete(5);

    await expectLater(refresh, completes);
    expect(cubit.state.unread, isNull);
  });

  test('markedRead takes the count down at once, then reads it', () async {
    final again = Completer<int>();
    remote.scriptUnreadCounts([5, again.future]);
    await cubit.refresh();

    cubit.markedRead(2);

    expect(cubit.state.unread, 3);
    expect(remote.fetchUnreadCountCalls, 2);
    again.complete(3);
    await pumpEventQueue();
    expect(cubit.state, const NotificationCountState(unread: 3));
  });

  test('markedRead never goes below zero', () async {
    final again = Completer<int>();
    remote.scriptUnreadCounts([1, again.future]);
    await cubit.refresh();

    cubit.markedRead(4);

    expect(cubit.state.unread, 0);
    again.complete(0);
    await pumpEventQueue();
  });

  test(
    "markedRead takes the server's count when a row was already read there",
    () async {
      // The row was read on another device: the server's count, 4, never
      // held it, and marking it read here changes nothing there.
      remote.scriptUnreadCounts([4, 4]);
      await cubit.refresh();

      cubit.markedRead(1);
      expect(cubit.state.unread, 3);
      await pumpEventQueue();

      expect(cubit.state, const NotificationCountState(unread: 4));
    },
  );

  test('a refresh in flight does not undo allMarkedRead', () async {
    final pending = Completer<int>();
    remote.scriptUnreadCounts([4, pending.future, 0]);
    await cubit.refresh();

    final refresh = cubit.refresh();
    cubit.allMarkedRead();
    pending.complete(5);
    await refresh;
    await pumpEventQueue();

    expect(cubit.state, const NotificationCountState(unread: 0));
  });

  test(
    'markedRead drops a refresh in flight and reads again in its place',
    () async {
      // Two arrived (3 + 2) while the badge read 3. The refresh that would
      // have shown them is out when a row is marked read.
      final pending = Completer<int>();
      remote.scriptUnreadCounts([3, pending.future, 4]);
      await cubit.refresh();

      final refresh = cubit.refresh();
      cubit.markedRead(1);
      expect(cubit.state.unread, 2);
      pending.complete(5);
      await refresh;
      await pumpEventQueue();

      expect(remote.fetchUnreadCountCalls, 3);
      expect(cubit.state, const NotificationCountState(unread: 4));
    },
  );

  test('allMarkedRead reads again and counts one that arrived since', () async {
    remote.scriptUnreadCounts([8, 1]);
    await cubit.refresh();

    cubit.allMarkedRead();
    expect(cubit.state.unread, 0);
    await pumpEventQueue();

    expect(cubit.state, const NotificationCountState(unread: 1));
  });

  test(
    'a refresh in flight that fails after allMarkedRead stays quiet',
    () async {
      final pending = Completer<int>();
      final replacement = Completer<int>();
      remote.scriptUnreadCounts([pending.future, replacement.future]);

      final refresh = cubit.refresh();
      cubit.allMarkedRead();
      pending.completeError(const NotificationTransientException('offline'));
      await refresh;
      await pumpEventQueue();

      // The stale failure says nothing: the read again is still out.
      expect(
        cubit.state,
        const NotificationCountState(unread: 0, refreshing: true),
      );

      replacement.completeError(
        const NotificationTransientException('offline'),
      );
      await pumpEventQueue();

      expect(cubit.state, const NotificationCountState(unread: 0));
    },
  );

  test('markedRead leaves an unknown count unknown until it is read', () async {
    final again = Completer<int>();
    remote.scriptUnreadCounts([again.future]);

    cubit.markedRead(1);

    expect(cubit.state.unread, isNull);
    again.complete(2);
    await pumpEventQueue();
    expect(cubit.state.unread, 2);
  });

  group('unreadBadgeText', () {
    test('shows the count up to 99', () {
      expect(unreadBadgeText(1), '1');
      expect(unreadBadgeText(99), '99');
    });

    test('caps above 99', () {
      expect(unreadBadgeText(100), '99+');
      expect(unreadBadgeText(250), '99+');
    });
  });
}
