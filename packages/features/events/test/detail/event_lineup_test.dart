import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// The lineup on an event's Games tab (#519): its games grouped by date, the
/// event's own first, then each date in order, then any whose date the event
/// no longer lists.
void main() {
  /// A game on the lineup, on the date [occurrenceId] or, where it is null,
  /// on the event itself.
  LineupGame game(String id, {String? occurrenceId}) => LineupGame(
    id: id,
    occurrenceId: occurrenceId,
    platformGameId: 'pg-$id',
    gameId: 'g-$id',
    title: 'Game $id',
    platformName: 'Tabletop',
    role: ScheduledGameRole.primary,
    sortOrder: 0,
    suppliedById: 'o-$id',
    supplierAttendeeId: 'att-ada',
  );

  /// A date of the event, [sortOrder] among them.
  EventOccurrence date(String id, int sortOrder) =>
      confirmed(id, DateTime(2026, 11, 6, 19), sortOrder: sortOrder);

  /// What [groups] hold, as lists a matcher compares deeply: each group's
  /// kind, its date's id, then its games' ids in order.
  List<List<Object?>> shape(List<LineupGroup> groups) => [
    for (final group in groups)
      [group.kind, group.date?.id, for (final each in group.games) each.id],
  ];

  const everyDate = LineupGroupKind.everyDate;
  const onDate = LineupGroupKind.date;
  const goneDate = LineupGroupKind.goneDate;

  final friday = date('d-1', 0);
  final saturday = date('d-2', 1);
  final sunday = date('d-3', 2);

  group('lineupGroups', () {
    test("the event's own games come first, then each date in order", () {
      // The snapshot's dates out of order: the groups follow their order
      // among the event's dates, and the server's order within each.
      final groups = lineupGroups(
        [
          game('l-1'),
          game('l-2', occurrenceId: 'd-2'),
          game('l-3', occurrenceId: 'd-1'),
          game('l-4'),
          game('l-5', occurrenceId: 'd-2'),
        ],
        [saturday, friday],
      );

      expect(shape(groups), [
        [everyDate, null, 'l-1', 'l-4'],
        [onDate, 'd-1', 'l-3'],
        [onDate, 'd-2', 'l-2', 'l-5'],
      ]);
      expect(groups[1].date, friday);
    });

    test('dates that share a place are ordered by id', () {
      final groups = lineupGroups(
        [game('l-1', occurrenceId: 'd-b'), game('l-2', occurrenceId: 'd-a')],
        [date('d-b', 0), date('d-a', 0)],
      );

      expect(shape(groups), [
        [onDate, 'd-a', 'l-2'],
        [onDate, 'd-b', 'l-1'],
      ]);
    });

    test('a date with no games has no group', () {
      final groups = lineupGroups(
        [game('l-1', occurrenceId: 'd-3')],
        [friday, saturday, sunday],
      );

      expect(shape(groups), [
        [onDate, 'd-3', 'l-1'],
      ]);
    });

    test('no games, no groups', () {
      expect(lineupGroups(const [], [friday, saturday]), isEmpty);
    });

    test('a game for a date the snapshot lacks shows under the gone-date '
        'group', () {
      final groups = lineupGroups(
        [
          game('l-3', occurrenceId: 'd-gone'),
          game('l-1'),
          game('l-2', occurrenceId: 'd-1'),
          game('l-4', occurrenceId: 'd-other-gone'),
        ],
        [friday],
      );

      // Never dropped: last, as one group with no date, in the server's
      // order.
      expect(shape(groups), [
        [everyDate, null, 'l-1'],
        [onDate, 'd-1', 'l-2'],
        [goneDate, null, 'l-3', 'l-4'],
      ]);
    });

    test('with no dates at all, every dated game is under the gone-date '
        'group', () {
      final groups = lineupGroups([
        game('l-1'),
        game('l-2', occurrenceId: 'd-1'),
      ], const []);

      expect(shape(groups), [
        [everyDate, null, 'l-1'],
        [goneDate, null, 'l-2'],
      ]);
    });
  });

  group('lineupDrawsHeaders', () {
    test('an event of two or more dates draws them', () {
      final groups = lineupGroups([game('l-1')], [friday, saturday]);

      expect(lineupDrawsHeaders(groups, [friday, saturday]), isTrue);
    });

    test('an event of one date or none draws none', () {
      final groups = lineupGroups(
        [
          game('l-1'),
          game('l-2', occurrenceId: 'd-1'),
        ],
        [friday],
      );

      expect(lineupDrawsHeaders(groups, [friday]), isFalse);
      expect(
        lineupDrawsHeaders(lineupGroups([game('l-1')], const []), const []),
        isFalse,
      );
    });

    test('a gone-date group draws them on an event of one date', () {
      final groups = lineupGroups(
        [
          game('l-1'),
          game('l-2', occurrenceId: 'd-gone'),
        ],
        [friday],
      );

      expect(lineupDrawsHeaders(groups, [friday]), isTrue);
    });
  });
}
