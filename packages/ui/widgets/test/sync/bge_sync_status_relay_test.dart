import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

const _waiting = 'Not yet synced';
const _stuck = "Couldn't sync";

/// A row for record `a`, whose own flags say the server hasn't had it: the
/// badge [BgeSyncStatusScope.stateOf] gives it, or nothing.
Widget _row() => Builder(
  builder: (context) => switch (BgeSyncStatusScope.stateOf(
    context,
    recordId: 'a',
    unsynced: true,
  )) {
    null => const SizedBox.shrink(),
    BgeSyncState.waiting => const BgeSyncBadge(
      state: BgeSyncState.waiting,
      label: _waiting,
    ),
    BgeSyncState.stuck => const BgeSyncBadge(
      state: BgeSyncState.stuck,
      label: _stuck,
    ),
  },
);

void main() {
  group('BgeSyncStatusData', () {
    test('compares the stuck records by their contents', () {
      // The host makes a new set for each state: two sets, not one
      // canonical constant, and in either order.
      final ids = ['a', 'b'];
      final a = BgeSyncStatusData(
        waiting: 1,
        stuck: 2,
        stuckRecordIds: {...ids},
      );
      final b = BgeSyncStatusData(
        waiting: 1,
        stuck: 2,
        stuckRecordIds: {...ids.reversed},
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const BgeSyncStatusData(waiting: 1, stuck: 2)));
      expect(
        a,
        isNot(
          const BgeSyncStatusData(stuck: 2, stuckRecordIds: {'a', 'b'}),
        ),
      );
      expect(const BgeSyncStatusData(), const BgeSyncStatusData());
    });
  });

  group('BgeSyncStatusRelayScope', () {
    testWidgets('relayScope rebuilds a badge as the relay changes', (
      tester,
    ) async {
      final relay = ValueNotifier(const BgeSyncStatusData());
      addTearDown(relay.dispose);

      await tester.pumpWidget(
        hostAtSize(
          tester,
          Scaffold(
            body: BgeSyncStatusRelayScope(relay: relay, child: _row()),
          ),
        ),
      );
      // Nothing read: the row's own flags.
      expect(find.text(_waiting), findsOneWidget);

      relay.value = const BgeSyncStatusData(
        waiting: 1,
        stuck: 1,
        stuckRecordIds: {'a'},
      );
      await tester.pump();
      expect(find.text(_stuck), findsOneWidget);
      expect(find.text(_waiting), findsNothing);

      // Retried and sent: the stuck change has gone, and the flags stand.
      relay.value = const BgeSyncStatusData(waiting: 0, stuck: 0);
      await tester.pump();
      expect(find.text(_waiting), findsOneWidget);
      expect(find.text(_stuck), findsNothing);
    });

    testWidgets('a null relay leaves stateOf on the flags', (tester) async {
      await tester.pumpWidget(
        hostAtSize(
          tester,
          Scaffold(
            body: BgeSyncStatusRelayScope(relay: null, child: _row()),
          ),
        ),
      );

      // The child passes through: no scope, so the row says what its own
      // flags know, and never that its change is stuck.
      expect(find.byType(BgeSyncStatusScope), findsNothing);
      expect(find.text(_waiting), findsOneWidget);
    });

    testWidgets('the scope it builds carries the relay on', (tester) async {
      // So a pop-up opened from the pop-up can relay it in turn.
      final relay = ValueNotifier(const BgeSyncStatusData());
      addTearDown(relay.dispose);
      ValueListenable<BgeSyncStatusData>? read;

      await tester.pumpWidget(
        BgeSyncStatusRelayScope(
          relay: relay,
          child: Builder(
            builder: (context) {
              read = BgeSyncStatusScope.relayOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(read, same(relay));
    });
  });

  group('BgeSyncStatusScope.relayOf', () {
    testWidgets('is null with no scope, or a scope with no relay', (
      tester,
    ) async {
      final reads = <ValueListenable<BgeSyncStatusData>?>[];
      Widget probe() => Builder(
        builder: (context) {
          reads.add(BgeSyncStatusScope.relayOf(context));
          return const SizedBox.shrink();
        },
      );

      await tester.pumpWidget(probe());
      await tester.pumpWidget(BgeSyncStatusScope(child: probe()));

      expect(reads, [null, null]);
    });

    testWidgets('takes no dependency on the scope', (tester) async {
      final relay = ValueNotifier(const BgeSyncStatusData());
      addTearDown(relay.dispose);
      var builds = 0;
      // One instance for every pump, so only a dependency rebuilds it.
      final probe = Builder(
        builder: (context) {
          BgeSyncStatusScope.relayOf(context);
          builds++;
          return const SizedBox.shrink();
        },
      );

      await tester.pumpWidget(
        BgeSyncStatusScope(waiting: 0, stuck: 0, relay: relay, child: probe),
      );
      await tester.pumpWidget(
        BgeSyncStatusScope(
          waiting: 2,
          stuck: 1,
          stuckRecordIds: const {'a'},
          relay: relay,
          child: probe,
        ),
      );

      expect(builds, 1);
    });
  });
}
