import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifications/src/count/notification_count_cubit.dart';
import 'package:notifications/src/count/notification_count_host.dart';
import 'package:notifications/src/count/notification_count_state.dart';

import '../support/fake_notification_remote.dart';

class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) {
    final unread = context.watch<NotificationCountCubit>().state.unread;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text(unread == null ? 'unknown' : 'unread $unread'),
    );
  }
}

Widget _host(FakeNotificationRemote remote, {Key? key}) =>
    NotificationCountHost(key: key, remote: remote, child: const _Probe());

void main() {
  testWidgets('fetches once on mount', (tester) async {
    final remote = FakeNotificationRemote()..scriptUnreadCounts([4]);

    await tester.pumpWidget(_host(remote));
    await tester.pump();

    expect(remote.fetchUnreadCountCalls, 1);
    expect(find.text('unread 4'), findsOneWidget);
  });

  testWidgets('fetches again on resume', (tester) async {
    final remote = FakeNotificationRemote()..scriptUnreadCounts([4, 6]);

    await tester.pumpWidget(_host(remote));
    await tester.pump();
    expect(remote.fetchUnreadCountCalls, 1);

    // The platform walks the states one at a time; the listener asserts on
    // a jump.
    void walk(List<AppLifecycleState> states) =>
        states.forEach(tester.binding.handleAppLifecycleStateChanged);

    walk([
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    await tester.pump();
    expect(remote.fetchUnreadCountCalls, 1);

    walk([
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await tester.pump();

    expect(remote.fetchUnreadCountCalls, 2);
    expect(find.text('unread 6'), findsOneWidget);
  });

  testWidgets('a new host for a new remote starts from unknown', (
    tester,
  ) async {
    final first = FakeNotificationRemote()..scriptUnreadCounts([4]);
    final second = FakeNotificationRemote()
      ..scriptUnreadCounts([Future<int>.value(9)]);

    await tester.pumpWidget(_host(first, key: const ValueKey('a')));
    await tester.pump();
    expect(find.text('unread 4'), findsOneWidget);

    await tester.pumpWidget(_host(second, key: const ValueKey('b')));
    expect(find.text('unknown'), findsOneWidget);
    expect(find.text('unread 4'), findsNothing);

    await tester.pump();
    expect(find.text('unread 9'), findsOneWidget);
    expect(second.fetchUnreadCountCalls, 1);
  });

  testWidgets('closes the cubit on dispose', (tester) async {
    final remote = FakeNotificationRemote()..scriptUnreadCounts([4]);
    late NotificationCountCubit cubit;

    await tester.pumpWidget(
      NotificationCountHost(
        remote: remote,
        child: Builder(
          builder: (context) {
            cubit = context.read<NotificationCountCubit>();
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();
    expect(cubit.isClosed, isFalse);

    await tester.pumpWidget(const SizedBox());

    expect(cubit.isClosed, isTrue);
    expect(cubit.state, const NotificationCountState(unread: 4));
  });
}
