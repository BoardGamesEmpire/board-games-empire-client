import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// The overview's date rules (#497), against a fixed clock: which group each
/// event lands in, which of its dates it shows, and the row's other parts.
void main() {
  final now = DateTime.utc(2026, 10, 23, 18);

  DateTime at(int day, [int hour = 0, int minute = 0]) =>
      DateTime.utc(2026, 10, day, hour, minute);

  EventRow only(List<EventListItem> items) {
    final groups = groupEvents(items, now: now);
    return [...groups.upcoming, ...groups.planning, ...groups.past].single;
  }

  group('a confirmed date', () {
    test('not yet ended is upcoming, showing the soonest', () {
      final row = only([
        item(
          'e-1',
          occurrences: [
            confirmed('o-30', at(30, 19)),
            confirmed('o-25', at(25, 19)),
          ],
        ),
      ]);

      expect(row.group, EventGroup.upcoming);
      expect(row.date?.id, 'o-25');
    });

    test('that started but has not ended is still upcoming', () {
      final row = only([
        item(
          'e-1',
          occurrences: [confirmed('o-1', at(23, 17), end: at(23, 21))],
        ),
      ]);

      expect(row.group, EventGroup.upcoming);
      expect(row.date?.id, 'o-1');
    });

    test('with no end is past once it starts', () {
      final row = only([
        item('e-1', occurrences: [confirmed('o-1', at(23, 17, 59))]),
      ]);

      expect(row.group, EventGroup.past);
    });

    test('ending exactly now is upcoming', () {
      // At or after now has not ended.
      final row = only([
        item('e-1', occurrences: [confirmed('o-1', at(23, 15), end: now)]),
      ]);

      expect(row.group, EventGroup.upcoming);
    });

    test('with no start date does not count', () {
      // Confirmed but not yet set: nothing to place the event by.
      final row = only([
        item(
          'e-1',
          occurrences: [
            confirmed('o-1', at(25)).copyWith(startDate: null, endDate: null),
          ],
        ),
      ]);

      expect(row.group, EventGroup.planning);
      expect(row.date, isNull);
    });
  });

  test('every date ended is past, showing the latest', () {
    // A multi-day event whose days are all behind it.
    final row = only([
      item(
        'e-1',
        schedulingMode: EventSchedulingMode.multiDay,
        occurrences: [
          confirmed('o-day1', at(10, 9), end: at(10, 17)),
          confirmed('o-day3', at(12, 9), end: at(12, 17), sortOrder: 2),
          confirmed('o-day2', at(11, 9), end: at(11, 17), sortOrder: 1),
        ],
      ),
    ]);

    expect(row.group, EventGroup.past);
    expect(row.date?.id, 'o-day3');
  });

  test('a multi-day event part way through shows its next day', () {
    final row = only([
      item(
        'e-1',
        schedulingMode: EventSchedulingMode.multiDay,
        occurrences: [
          confirmed('o-day1', at(22, 9), end: at(22, 17)),
          confirmed('o-day2', at(24, 9), end: at(24, 17), sortOrder: 1),
        ],
      ),
    ]);

    expect(row.group, EventGroup.upcoming);
    expect(row.date?.id, 'o-day2');
  });

  test('dates on the same instant are told apart by sortOrder, then id', () {
    List<EventOccurrence> sameInstant(DateTime start) => [
      confirmed('o-b', start, sortOrder: 1),
      confirmed('o-c', start, sortOrder: 2),
      confirmed('o-a', start, sortOrder: 1),
    ];

    final groups = groupEvents([
      item('e-up', occurrences: sameInstant(at(25, 19))),
      item('e-past', occurrences: sameInstant(at(20, 19))),
    ], now: now);

    expect(groups.upcoming.single.date?.id, 'o-a');
    expect(groups.past.single.date?.id, 'o-a');
  });

  test('upcoming sorts soonest first, past most recent first, planning keeps '
      'the input order', () {
    // The input is the list's order, newest created first.
    final groups = groupEvents([
      item('e-plan-new', schedulingMode: EventSchedulingMode.poll),
      item('e-up-late', occurrences: [confirmed('o', at(30))]),
      item('e-past-old', occurrences: [confirmed('o', at(1))]),
      item('e-plan-old'),
      item('e-up-soon', occurrences: [confirmed('o', at(24))]),
      item('e-past-recent', occurrences: [confirmed('o', at(20))]),
      item('e-up-tie-b', occurrences: [confirmed('o', at(27))]),
      item('e-up-tie-a', occurrences: [confirmed('o', at(27))]),
    ], now: now);

    expect(groups.upcoming.map((r) => r.event.id), [
      'e-up-soon',
      'e-up-tie-a',
      'e-up-tie-b',
      'e-up-late',
    ]);
    expect(groups.past.map((r) => r.event.id), ['e-past-recent', 'e-past-old']);
    expect(groups.planning.map((r) => r.event.id), [
      'e-plan-new',
      'e-plan-old',
    ]);
  });

  group('planning', () {
    test('a poll with no confirmed date is planning, date being chosen', () {
      final row = only([
        item(
          'e-1',
          schedulingMode: EventSchedulingMode.poll,
          occurrences: [
            confirmed(
              'o-1',
              at(25),
            ).copyWith(status: OccurrenceStatus.proposed),
          ],
        ),
      ]);

      expect(row.group, EventGroup.planning);
      expect(row.date, isNull);
      expect(row.dateBeingChosen, isTrue);
    });

    test('a poll with a confirmed date is upcoming', () {
      // Event.status stays planning: nothing on the server changes it once
      // a date is confirmed (backend#795), so the dates decide.
      final poll = item(
        'e-1',
        schedulingMode: EventSchedulingMode.poll,
        occurrences: [confirmed('o-1', at(25))],
      );
      expect(poll.event.status, EventStatus.planning);

      final row = only([poll]);

      expect(row.group, EventGroup.upcoming);
      expect(row.dateBeingChosen, isFalse);
    });

    test('a fixed event with no dates is planning, no date yet', () {
      // Nobody is choosing a date, so "being chosen" would be untrue.
      final row = only([item('e-1')]);

      expect(row.group, EventGroup.planning);
      expect(row.date, isNull);
      expect(row.dateBeingChosen, isFalse);
    });

    test('cancelled and declined dates do not count', () {
      final row = only([
        item(
          'e-1',
          schedulingMode: EventSchedulingMode.poll,
          occurrences: [
            confirmed(
              'o-1',
              at(25),
            ).copyWith(status: OccurrenceStatus.cancelled),
            confirmed(
              'o-2',
              at(26),
            ).copyWith(status: OccurrenceStatus.declined),
          ],
        ),
      ]);

      expect(row.group, EventGroup.planning);
      expect(row.date, isNull);
    });

    test('an unknown scheduling mode reads no date yet', () {
      // A mode a newer server adds: not known to be a poll.
      final row = only([
        item('e-1', schedulingMode: EventSchedulingMode.unknown),
      ]);

      expect(row.group, EventGroup.planning);
      expect(row.dateBeingChosen, isFalse);
    });

    test('an unknown occurrence status is not a confirmed date', () {
      final row = only([
        item(
          'e-1',
          occurrences: [
            confirmed('o-1', at(25)).copyWith(status: OccurrenceStatus.unknown),
          ],
        ),
      ]);

      expect(row.group, EventGroup.planning);
      expect(row.date, isNull);
    });
  });

  group('the venue', () {
    test("is the shown date's location", () {
      final row = only([
        item(
          'e-1',
          location: 'Kitchen table',
          occurrences: [confirmed('o-1', at(25), location: 'Back room')],
        ),
      ]);

      expect(row.venue, 'Back room');
    });

    test("falls back to the event's location, and a blank one is none", () {
      final groups = groupEvents([
        item(
          'e-fallback',
          location: 'Kitchen table',
          occurrences: [confirmed('o-1', at(25))],
        ),
        item(
          'e-blank-date',
          location: 'Kitchen table',
          occurrences: [confirmed('o-1', at(26), location: '  ')],
        ),
        item('e-planning', location: 'Kitchen table'),
        item('e-blank', location: ' '),
        item('e-none'),
      ], now: now);

      String? venueOf(String id) => [
        ...groups.upcoming,
        ...groups.planning,
      ].singleWhere((r) => r.event.id == id).venue;

      expect(venueOf('e-fallback'), 'Kitchen table');
      expect(venueOf('e-blank-date'), 'Kitchen table');
      expect(venueOf('e-planning'), 'Kitchen table');
      expect(venueOf('e-blank'), isNull);
      expect(venueOf('e-none'), isNull);
    });
  });

  test('the household name comes from the map, and is null when absent', () {
    final groups = groupEvents(
      [
        item('e-mine', householdId: 'h-1'),
        item('e-elsewhere', householdId: 'h-other'),
        item('e-none'),
      ],
      now: now,
      householdNames: const {'h-1': 'The Smiths'},
    );

    expect(groups.planning.map((r) => r.householdName), [
      'The Smiths',
      null,
      null,
    ]);
  });

  test('rsvp is the attendance status, and null when unknown or absent', () {
    final groups = groupEvents([
      for (final status in EventParticipationStatus.values)
        item('e-${status.name}', attendance: attendance(status)),
      item('e-not-known'),
    ], now: now);

    expect(groups.planning.map((r) => r.rsvp), [
      EventParticipationStatus.attending,
      EventParticipationStatus.invited,
      EventParticipationStatus.maybe,
      EventParticipationStatus.notAttending,
      null,
      null,
    ]);
  });

  group('the groups', () {
    test('are empty for no events', () {
      final groups = groupEvents(const [], now: now);

      expect(groups.isEmpty, isTrue);
      expect(groups, const EventGroups());
    });

    test('are not empty while any group holds a row', () {
      expect(groupEvents([item('e-1')], now: now).isEmpty, isFalse);
    });

    test('of names each group', () {
      final groups = groupEvents([
        item('e-up', occurrences: [confirmed('o', at(25))]),
        item('e-plan'),
        item('e-past', occurrences: [confirmed('o', at(20))]),
      ], now: now);

      expect(groups.of(EventGroup.upcoming), groups.upcoming);
      expect(groups.of(EventGroup.planning), groups.planning);
      expect(groups.of(EventGroup.past), groups.past);
    });

    test('compare by value', () {
      // A bloc drops an emit equal to its current state, so regrouping the
      // same cache against a clock that moved nothing rebuilds nothing.
      final items = [
        item('e-1', occurrences: [confirmed('o', at(25))]),
      ];

      expect(groupEvents(items, now: now), groupEvents(items, now: now));
    });
  });
}
