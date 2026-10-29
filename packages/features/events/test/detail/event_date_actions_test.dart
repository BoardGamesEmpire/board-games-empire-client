import 'package:events/events.dart';
import 'package:events/src/detail/event_date_actions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// Which date actions a status offers (#506), on top of the role table.
void main() {
  const all = {
    EventAction.editDate,
    EventAction.confirmDate,
    EventAction.declineDate,
    EventAction.cancelDate,
    EventAction.removeDate,
  };

  Event eventWith({
    EventStatus status = EventStatus.planning,
    EventSchedulingMode mode = EventSchedulingMode.fixed,
  }) => item('e').event.copyWith(status: status, schedulingMode: mode);

  EventOccurrence date(OccurrenceStatus status, {int sortOrder = 0}) =>
      confirmed(
        'o-$sortOrder',
        DateTime.utc(2026, 11, 1),
        sortOrder: sortOrder,
      ).copyWith(status: status);

  group('dateActionsFor', () {
    final event = eventWith();

    Set<EventAction> forStatus(OccurrenceStatus status) =>
        dateActionsFor(event, date(status), all);

    test('a proposed date can be edited, confirmed, declined or removed', () {
      expect(forStatus(OccurrenceStatus.proposed), {
        EventAction.editDate,
        EventAction.confirmDate,
        EventAction.declineDate,
        EventAction.removeDate,
      });
    });

    test('a confirmed date can be edited, cancelled or removed', () {
      expect(forStatus(OccurrenceStatus.confirmed), {
        EventAction.editDate,
        EventAction.cancelDate,
        EventAction.removeDate,
      });
    });

    test('a declined date can be edited or removed', () {
      expect(forStatus(OccurrenceStatus.declined), {
        EventAction.editDate,
        EventAction.removeDate,
      });
    });

    test('a cancelled date can be edited or removed', () {
      expect(forStatus(OccurrenceStatus.cancelled), {
        EventAction.editDate,
        EventAction.removeDate,
      });
    });

    test('a date of unknown status offers nothing', () {
      expect(forStatus(OccurrenceStatus.unknown), isEmpty);
    });

    for (final status in [
      EventStatus.cancelled,
      EventStatus.archived,
      EventStatus.unknown,
    ]) {
      test('a ${status.name} event offers no date write', () {
        for (final s in OccurrenceStatus.values) {
          expect(
            dateActionsFor(eventWith(status: status), date(s), all),
            isEmpty,
          );
        }
      });
    }

    test('never exceeds what the role allows', () {
      expect(
        dateActionsFor(event, date(OccurrenceStatus.confirmed), {
          EventAction.editDate,
          EventAction.cancelDate,
        }),
        {EventAction.editDate, EventAction.cancelDate},
      );
    });

    test('ignores allowed actions that are not date actions', () {
      expect(
        dateActionsFor(event, date(OccurrenceStatus.proposed), {
          EventAction.edit,
          EventAction.addDate,
        }),
        isEmpty,
      );
    });

    test('answers a set nothing can change', () {
      final actions = forStatus(OccurrenceStatus.proposed);

      expect(actions.clear, throwsUnsupportedError);
    });
  });

  group('canAddDate', () {
    const allowed = {EventAction.addDate};

    test('is false without the addDate action', () {
      expect(canAddDate(eventWith(), const [], {EventAction.editDate}), false);
    });

    for (final status in [
      EventStatus.cancelled,
      EventStatus.archived,
      EventStatus.unknown,
    ]) {
      test('is false on a ${status.name} event', () {
        expect(canAddDate(eventWith(status: status), const [], allowed), false);
      });
    }

    test('is false on an unknown scheduling mode', () {
      final event = eventWith(mode: EventSchedulingMode.unknown);

      expect(canAddDate(event, const [], allowed), false);
    });

    test('is true on a fixed event with no date', () {
      expect(canAddDate(eventWith(), const [], allowed), true);
    });

    test('is false on a fixed event with a date', () {
      expect(
        canAddDate(eventWith(), [date(OccurrenceStatus.confirmed)], allowed),
        false,
      );
    });

    test('is false on a fixed event whose one date is cancelled', () {
      // The server counts a cancelled date too (backend#966).
      expect(
        canAddDate(eventWith(), [date(OccurrenceStatus.cancelled)], allowed),
        false,
      );
    });

    test('is true on a poll and a multi-day event that hold dates', () {
      for (final mode in [
        EventSchedulingMode.poll,
        EventSchedulingMode.multiDay,
      ]) {
        expect(
          canAddDate(eventWith(mode: mode), [
            date(OccurrenceStatus.proposed),
          ], allowed),
          true,
        );
      }
    });
  });

  group('nextSortOrder', () {
    test('is 0 with no dates', () {
      expect(nextSortOrder(const []), 0);
    });

    test('is one past the highest', () {
      expect(
        nextSortOrder([
          date(OccurrenceStatus.proposed, sortOrder: 0),
          date(OccurrenceStatus.proposed, sortOrder: 5),
          date(OccurrenceStatus.proposed, sortOrder: 2),
        ]),
        6,
      );
    });
  });
}
