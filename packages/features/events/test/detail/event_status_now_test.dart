import 'package:events/src/detail/event_status_now.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// An event's status as of an instant, and when it next changes (#502, #655).
void main() {
  final start = DateTime.utc(2026, 11, 10, 18);
  final end = DateTime.utc(2026, 11, 10, 22);

  Event eventWith([EventStatus status = EventStatus.planning]) =>
      item('e').event.copyWith(status: status);

  EventOccurrence date(
    DateTime start, {
    DateTime? end,
    OccurrenceStatus status = OccurrenceStatus.confirmed,
    int sortOrder = 0,
  }) => confirmed(
    'o-$sortOrder',
    start,
    end: end,
    sortOrder: sortOrder,
  ).copyWith(status: status);

  group('eventStatusAt', () {
    EventStatus at(
      List<EventOccurrence> dates,
      DateTime now, [
      EventStatus cached = EventStatus.planning,
    ]) => eventStatusAt(eventWith(cached), dates, now: now);

    test('planning with no confirmed date', () {
      expect(at(const [], start), EventStatus.planning);
      expect(
        at([
          date(start, end: end, status: OccurrenceStatus.proposed),
          date(
            start,
            end: end,
            status: OccurrenceStatus.cancelled,
            sortOrder: 1,
          ),
        ], start),
        EventStatus.planning,
      );
    });

    test('scheduled before the first start', () {
      final dates = [date(start, end: end)];
      expect(
        at(dates, start.subtract(const Duration(microseconds: 1))),
        EventStatus.scheduled,
      );
    });

    test('ongoing at the first start', () {
      expect(at([date(start, end: end)], start), EventStatus.ongoing);
    });

    test('ongoing between the days of a multi-day event', () {
      final dates = [
        date(start, end: end),
        date(
          start.add(const Duration(days: 2)),
          end: end.add(const Duration(days: 2)),
          sortOrder: 1,
        ),
      ];
      expect(
        at(dates, start.add(const Duration(days: 1))),
        EventStatus.ongoing,
      );
    });

    test('completed at the last end', () {
      expect(at([date(start, end: end)], end), EventStatus.completed);
    });

    test('a date with no end is completed the moment it starts', () {
      expect(at([date(start)], start), EventStatus.completed);
    });

    test('an end before its start is clamped to the start', () {
      final dates = [
        date(start, end: start.subtract(const Duration(hours: 1))),
      ];
      expect(at(dates, start), EventStatus.completed);
    });

    test('instants compare as instants, whatever their zone', () {
      final local = start.toLocal();
      expect(at([date(local, end: end)], start), EventStatus.ongoing);
    });

    test('cancelled, archived and unknown come from the cached status', () {
      final dates = [date(start, end: end)];
      for (final cached in [
        EventStatus.cancelled,
        EventStatus.archived,
        EventStatus.unknown,
      ]) {
        expect(at(dates, start, cached), cached);
        expect(at(const [], start, cached), cached);
      }
    });
  });

  group('wasCancelled', () {
    final at = DateTime.utc(2026, 11);

    test('a cancelled event was', () {
      expect(wasCancelled(eventWith(EventStatus.cancelled)), isTrue);
    });

    test('an archived event was when the archive kept a cancel', () {
      final archived = eventWith(EventStatus.archived);
      expect(wasCancelled(archived.copyWith(cancelledAt: at)), isTrue);
      expect(wasCancelled(archived), isFalse);
    });

    test('no other status was, whatever the event carries', () {
      for (final status in EventStatus.values) {
        if (status == EventStatus.cancelled || status == EventStatus.archived) {
          continue;
        }
        expect(
          wasCancelled(eventWith(status).copyWith(cancelledAt: at)),
          isFalse,
          reason: status.name,
        );
      }
    });
  });

  group('nextDetailBoundary', () {
    DateTime? next(
      List<EventOccurrence> dates,
      DateTime now, [
      EventStatus cached = EventStatus.planning,
    ]) => nextDetailBoundary(eventWith(cached), dates, now: now);

    final before = start.subtract(const Duration(hours: 1));

    test('scheduled: the earliest start', () {
      expect(next([date(start, end: end)], before), start);
    });

    test('ongoing: the latest end', () {
      expect(next([date(start, end: end)], start), end);
    });

    test('completed: none', () {
      expect(next([date(start, end: end)], end), isNull);
    });

    test('planning with nothing to wait for: none', () {
      expect(next(const [], start), isNull);
    });

    test('a proposed date: just past its end', () {
      final dates = [date(start, end: end, status: OccurrenceStatus.proposed)];
      expect(next(dates, before), end.add(const Duration(microseconds: 1)));
    });

    test('a proposed date ending now has not passed yet', () {
      final dates = [date(start, end: end, status: OccurrenceStatus.proposed)];
      expect(next(dates, end), end.add(const Duration(microseconds: 1)));
    });

    test('a proposed date that has passed is no boundary', () {
      final dates = [date(start, end: end, status: OccurrenceStatus.proposed)];
      expect(next(dates, end.add(const Duration(microseconds: 1))), isNull);
    });

    test('the earliest of the confirmed and proposed boundaries', () {
      final dates = [
        date(start, end: end),
        date(
          start.subtract(const Duration(days: 1)),
          end: start.subtract(const Duration(hours: 20)),
          status: OccurrenceStatus.proposed,
          sortOrder: 1,
        ),
      ];
      expect(
        next(dates, start.subtract(const Duration(days: 2))),
        start.subtract(const Duration(hours: 20, microseconds: -1)),
      );
    });

    test('a cancelled event with a pending proposed date: only that', () {
      final dates = [
        date(start, end: end),
        date(start, end: end, status: OccurrenceStatus.proposed, sortOrder: 1),
      ];
      expect(
        next(dates, before, EventStatus.cancelled),
        end.add(const Duration(microseconds: 1)),
      );
    });
  });
}
