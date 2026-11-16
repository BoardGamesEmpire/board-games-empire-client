import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

/// Calls [read] with its own context on every build.
Widget _probe(void Function(BuildContext context) read) => Builder(
  builder: (context) {
    read(context);
    return const SizedBox.shrink();
  },
);

/// A scope around [child], with a fresh set of ids per call, as the host
/// makes one per state.
Widget _scope({
  required Widget child,
  int? waiting = 0,
  int? stuck = 0,
  Iterable<String> ids = const [],
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: BgeSyncStatusScope(
    waiting: waiting,
    stuck: stuck,
    stuckRecordIds: Set.of(ids),
    child: child,
  ),
);

void main() {
  group('BgeSyncStatusScope', () {
    testWidgets('no scope: counts are null, nothing is stuck', (tester) async {
      late ({int? waiting, int? stuck}) counts;
      late bool stuck;
      late BgeSyncState? unsynced;
      await tester.pumpWidget(
        _probe((context) {
          counts = BgeSyncStatusScope.countsOf(context);
          stuck = BgeSyncStatusScope.isStuckOf(context, 'a');
          unsynced = BgeSyncStatusScope.stateOf(
            context,
            recordId: 'a',
            unsynced: true,
          );
        }),
      );

      // Null, not zero counts, which would say everything had synced.
      expect(counts, (waiting: null, stuck: null));
      expect(stuck, isFalse);
      // A row still says what its own flags know.
      expect(unsynced, BgeSyncState.waiting);
    });

    testWidgets('a count not read is null, and the other stands', (
      tester,
    ) async {
      final counts = <({int? waiting, int? stuck})>[];
      Widget probe() =>
          _probe((context) => counts.add(BgeSyncStatusScope.countsOf(context)));
      await tester.pumpWidget(_scope(waiting: null, stuck: 1, child: probe()));
      await tester.pumpWidget(_scope(waiting: 2, stuck: null, child: probe()));
      await tester.pumpWidget(
        _scope(waiting: null, stuck: null, child: probe()),
      );

      expect(counts, [
        (waiting: null, stuck: 1),
        (waiting: 2, stuck: null),
        (waiting: null, stuck: null),
      ]);
    });

    test('names no records from stuck changes it has not read', () {
      expect(
        () => BgeSyncStatusScope(
          waiting: 0,
          stuckRecordIds: const {'a'},
          child: const SizedBox.shrink(),
        ),
        throwsAssertionError,
      );
    });

    testWidgets('a stuck record shows whether or not waiting is read', (
      tester,
    ) async {
      final states = <BgeSyncState?>[];
      Widget probe() => _probe(
        (context) => states.add(
          BgeSyncStatusScope.stateOf(context, recordId: 'a', unsynced: true),
        ),
      );
      await tester.pumpWidget(
        _scope(waiting: null, stuck: 1, ids: ['a'], child: probe()),
      );

      expect(states, [BgeSyncState.stuck]);
    });

    testWidgets('read counts are its own', (tester) async {
      ({int? waiting, int? stuck})? counts;
      await tester.pumpWidget(
        _scope(
          waiting: 3,
          stuck: 1,
          ids: ['a'],
          child: _probe(
            (context) => counts = BgeSyncStatusScope.countsOf(context),
          ),
        ),
      );

      expect(counts, (waiting: 3, stuck: 1));
    });

    testWidgets('stateOf prefers stuck over waiting', (tester) async {
      final states = <String, BgeSyncState?>{};
      await tester.pumpWidget(
        _scope(
          waiting: 2,
          stuck: 1,
          ids: ['a'],
          child: _probe((context) {
            for (final (id, unsynced) in [
              ('a', true),
              ('b', true),
              // Stuck says what the flags can't: the change will not send.
              ('a', false),
            ]) {
              states['$id/$unsynced'] = BgeSyncStatusScope.stateOf(
                context,
                recordId: id,
                unsynced: unsynced,
              );
            }
          }),
        ),
      );

      expect(states, {
        'a/true': BgeSyncState.stuck,
        'b/true': BgeSyncState.waiting,
        'a/false': BgeSyncState.stuck,
      });
    });

    testWidgets('stateOf is null for a synced record', (tester) async {
      BgeSyncState? state = BgeSyncState.waiting;
      await tester.pumpWidget(
        _scope(
          waiting: 2,
          stuck: 1,
          ids: ['a'],
          child: _probe(
            (context) => state = BgeSyncStatusScope.stateOf(
              context,
              recordId: 'b',
              unsynced: false,
            ),
          ),
        ),
      );

      expect(state, isNull);
    });

    group('a reader rebuilds only for the part it reads', () {
      late List<String> builds;
      late Widget readers;

      setUp(() {
        builds = [];
        Widget reader(String name, void Function(BuildContext) read) =>
            _probe((context) {
              read(context);
              builds.add(name);
            });
        // One instance for every pump, so only the scope rebuilds a reader.
        readers = Column(
          children: [
            reader('counts', BgeSyncStatusScope.countsOf),
            reader(
              'a',
              (context) => BgeSyncStatusScope.isStuckOf(context, 'a'),
            ),
            reader(
              'b',
              (context) => BgeSyncStatusScope.stateOf(
                context,
                recordId: 'b',
                unsynced: true,
              ),
            ),
          ],
        );
      });

      testWidgets('a count change does not rebuild a row that reads only its '
          'id', (tester) async {
        await tester.pumpWidget(_scope(waiting: 1, child: readers));
        builds.clear();

        await tester.pumpWidget(_scope(waiting: 2, child: readers));

        expect(builds, ['counts']);
      });

      testWidgets("a membership change rebuilds only that id's dependents", (
        tester,
      ) async {
        await tester.pumpWidget(_scope(stuck: 2, ids: ['b'], child: readers));
        builds.clear();

        await tester.pumpWidget(
          _scope(stuck: 2, ids: ['a', 'b'], child: readers),
        );

        expect(builds, ['a']);
      });

      testWidgets('a count going unread rebuilds only the counts', (
        tester,
      ) async {
        await tester.pumpWidget(_scope(child: readers));
        builds.clear();

        await tester.pumpWidget(_scope(waiting: null, child: readers));

        expect(builds, ['counts']);
      });
    });

    testWidgets('a fresh set with the same ids is no change', (tester) async {
      var builds = 0;
      // Depends on the whole scope, so it hears every change the scope
      // reports, not only its own part.
      final reader = _probe((context) {
        context.dependOnInheritedWidgetOfExactType<BgeSyncStatusScope>();
        builds++;
      });
      await tester.pumpWidget(_scope(stuck: 1, ids: ['a'], child: reader));
      builds = 0;

      await tester.pumpWidget(_scope(stuck: 1, ids: ['a'], child: reader));

      expect(builds, 0);
    });
  });
}
