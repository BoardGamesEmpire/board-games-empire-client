import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// The games pool's filter on an event's Games tab, and the attendees a
/// read of the pool names (#516).
void main() {
  /// A game [attendeeId] offers, titled [title].
  OfferedGame offered(String id, String attendeeId, String title) =>
      OfferedGame(
        id: id,
        attendeeId: attendeeId,
        collectionId: 'col-$id',
        platformGameId: 'pg-$id',
        gameId: 'g-$id',
        title: title,
        platformName: 'Tabletop',
      );

  final catanMine = offered('o-1', 'att-me', 'Catan');
  final azul = offered('o-2', 'att-ada', 'Azul');
  final catanAdas = offered('o-3', 'att-ada', 'Catan');
  final root = offered('o-4', 'att-bo', 'Root');
  final pool = [catanMine, azul, catanAdas, root];

  group('filterPool', () {
    test('keeps every game, in order, when nothing narrows', () {
      expect(filterPool(pool, const PoolFilter()), pool);
      expect(const PoolFilter().narrows, isFalse);
    });

    test('the query matches the title, trimmed, ignoring case', () {
      const filter = PoolFilter(query: '  cAT ');

      expect(filterPool(pool, filter), [catanMine, catanAdas]);
      expect(filter.narrows, isTrue);
    });

    test('a blank query narrows nothing', () {
      const filter = PoolFilter(query: '   ');

      expect(filterPool(pool, filter), pool);
      expect(filter.narrows, isFalse);
    });

    test('one person chosen keeps only their games', () {
      const filter = PoolFilter(attendeeIds: {'att-ada'});

      expect(filterPool(pool, filter), [azul, catanAdas]);
      expect(filter.narrows, isTrue);
    });

    test('two people chosen keep both their games, in order', () {
      const filter = PoolFilter(attendeeIds: {'att-bo', 'att-me'});

      expect(filterPool(pool, filter), [catanMine, root]);
    });

    test('leave-out keeps everyone but the people chosen', () {
      const filter = PoolFilter(attendeeIds: {'att-ada'}, leaveOut: true);

      expect(filterPool(pool, filter), [catanMine, root]);
      expect(filter.narrows, isTrue);
    });

    test('nobody chosen with leave-out on narrows nothing', () {
      const filter = PoolFilter(leaveOut: true);

      expect(filterPool(pool, filter), pool);
      expect(filter.narrows, isFalse);
    });

    test('the query and the people narrow together', () {
      const filter = PoolFilter(query: 'catan', attendeeIds: {'att-me'});

      expect(filterPool(pool, filter), [catanMine]);
    });

    test('"Not mine" leaves the viewer\'s games out', () {
      const notMine = PoolFilter(attendeeIds: {'att-me'}, leaveOut: true);

      expect(filterPool(pool, notMine), [azul, catanAdas, root]);
    });

    test(
      'two people offering one game are two rows, and leaving one person out '
      "keeps the other's",
      () {
        expect(filterPool(pool, const PoolFilter(query: 'Catan')), [
          catanMine,
          catanAdas,
        ]);

        expect(
          filterPool(
            pool,
            const PoolFilter(
              query: 'Catan',
              attendeeIds: {'att-me'},
              leaveOut: true,
            ),
          ),
          [catanAdas],
        );
      },
    );

    test('filters are equal by value', () {
      expect(
        const PoolFilter(query: 'a', attendeeIds: {'x'}, leaveOut: true),
        const PoolFilter(query: 'a', attendeeIds: {'x'}, leaveOut: true),
      );
      expect(const PoolFilter(), isNot(const PoolFilter(leaveOut: true)));
    });
  });

  group('poolAttendeeIds', () {
    final me = attendance(EventParticipationStatus.attending);
    EventAttendee member(String id) => me.copyWith(id: id, userId: 'u-$id');

    EventDetail detail({List<EventAttendee>? roster, EventAttendee? viewer}) =>
        EventDetail(
          snapshot: EventSnapshot(
            event: item('e').event,
            occurrences: const [],
            attendees: roster,
          ),
          attendance: viewer,
        );

    test("a roster is read whole, in the roster's order", () {
      expect(
        poolAttendeeIds(
          detail(roster: [member('att-b'), me, member('att-a')], viewer: me),
        ),
        ['att-b', 'att-me', 'att-a'],
      );
    });

    test("a null roster reads the viewer's own games", () {
      expect(poolAttendeeIds(detail(viewer: me)), ['att-me']);
    });

    test("a withheld roster reads the viewer's own games", () {
      expect(poolAttendeeIds(detail(roster: const [], viewer: me)), [
        'att-me',
      ]);
    });

    test('neither a roster nor a row of their own reads nothing', () {
      expect(poolAttendeeIds(detail()), isEmpty);
      expect(poolAttendeeIds(detail(roster: const [])), isEmpty);
    });
  });
}
