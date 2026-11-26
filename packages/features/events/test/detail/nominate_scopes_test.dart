import 'package:events/events.dart';
import 'package:events/src/detail/nominate_scopes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// The choices Nominate offers on an event as of a time (#517), from the date
/// view the row of dates chose (#1042): the pure rule, apart from the view's
/// mode and the row it is offered on.
void main() {
  final now = DateTime.utc(2026, 10, 1, 12);

  /// A confirmed date [days] from [now], [order]th among the event's.
  EventOccurrence date(String id, int days, {int order = 0}) =>
      confirmed(id, now.add(Duration(days: days)), sortOrder: order);

  final passed = date('passed', -3);
  final soon = date('soon', 2, order: 1);
  final later = date('later', 9, order: 2);
  final cancelled = date(
    'cancelled',
    16,
    order: 3,
  ).copyWith(status: OccurrenceStatus.cancelled);

  /// The event on [dates]: all [nominateScopes] reads.
  EventDetail eventOn(List<EventOccurrence> dates) => EventDetail(
    snapshot: EventSnapshot(event: item('e').event, occurrences: dates),
  );

  /// What [scopes] are for: null for the whole event, else the date's id.
  List<String?> forWhat(List<NominateScope> scopes) => [
    for (final each in scopes) each.scope.occurrenceId,
  ];

  group('nominateScopes', () {
    test('with no view, an event of one date offers the whole event alone', () {
      expect(
        forWhat(nominateScopes(eventOn([soon]), now: now)),
        [null],
      );
    });

    test('with no view, an event of more dates offers the whole event alone '
        '(#1062)', () {
      final detail = eventOn([later, cancelled, passed, soon]);

      expect(forWhat(nominateScopes(detail, now: now)), [null]);
    });

    test('Every date offers the whole event alone', () {
      final detail = eventOn([passed, soon, later]);

      expect(
        forWhat(
          nominateScopes(detail, now: now, view: const EveryDateView()),
        ),
        [null],
      );
    });

    test('a date offers itself alone', () {
      final detail = eventOn([passed, soon, later]);

      final scopes = nominateScopes(
        detail,
        now: now,
        view: const OneDateView('later'),
      );

      expect(forWhat(scopes), ['later']);
      expect(scopes.single.date, later);
    });

    test('a date started, or cancelled, offers nothing', () {
      final detail = eventOn([passed, soon, cancelled]);

      for (final id in ['passed', 'cancelled']) {
        expect(
          nominateScopes(detail, now: now, view: OneDateView(id)),
          isEmpty,
          reason: id,
        );
      }
      // Nor once a date still to come has started.
      expect(
        nominateScopes(
          detail,
          now: now.add(const Duration(days: 3)),
          view: const OneDateView('soon'),
        ),
        isEmpty,
      );
    });
  });
}
