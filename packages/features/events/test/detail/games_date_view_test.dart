import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// Which of an event's dates the Games tab shows (#1042): the row, its
/// default, what the location's `date` names, and the mode of each view
/// (#519).
void main() {
  final now = DateTime.utc(2026, 10, 1, 12);
  final passed = DateTime.utc(2026, 9, 20, 19);
  final soon = DateTime.utc(2026, 10, 3, 19);
  final later = DateTime.utc(2026, 10, 10, 19);

  /// A confirmed date starting at [start], or still to be set where it is
  /// null, [order]th in the event's order of its dates.
  EventOccurrence date(
    String id,
    DateTime? start, {
    int order = 0,
    OccurrenceStatus status = OccurrenceStatus.confirmed,
  }) => confirmed(
    id,
    start ?? now,
    sortOrder: order,
  ).copyWith(startDate: start, status: status);

  EventPolicy policy(GameAdditionMode mode) => EventPolicy(
    id: 'p',
    eventId: 'e',
    allowMemberInvites: true,
    allowGuestInvites: false,
    restrictToGameCategories: false,
    requireHostApprovalToJoin: false,
    allowSpectators: false,
    strictCapacity: false,
    gameAdditionMode: mode,
    restrictToAttendeePool: false,
    voteThresholdType: VoteThresholdType.simpleMajority,
    voteQuorumType: VoteQuorumType.none,
    voteEligibility: VoteEligibility.allAttendees,
    interestedWeight: InterestedWeight.asAbstain,
    createdAt: kItemInstant,
    updatedAt: kItemInstant,
  );

  EventOccurrencePolicy override(String occurrenceId, GameAdditionMode? mode) =>
      EventOccurrencePolicy(
        id: 'op-$occurrenceId',
        occurrenceId: occurrenceId,
        allowedCategoryIds: const [],
        allowedPlatformIds: const [],
        allowedPlatformTypes: const [],
        platformTypesUnrestricted: false,
        platformsUnrestricted: false,
        capacityUnrestricted: false,
        gameAdditionMode: mode,
        createdAt: kItemInstant,
        updatedAt: kItemInstant,
      );

  EventDetail detail(
    List<EventOccurrence> dates, {
    EventPolicy? eventPolicy,
    List<EventOccurrencePolicy>? overrides,
  }) => EventDetail(
    snapshot: EventSnapshot(
      event: item('e').event,
      occurrences: dates,
      policy: eventPolicy,
      occurrencePolicies: overrides,
    ),
  );

  /// Three dates: one passed, then two still to come.
  final threeDates = detail([
    date('passed', passed),
    date('soon', soon, order: 1),
    date('later', later, order: 2),
  ]);

  group('GamesDateView', () {
    test('the location names Every date all, and a date by its id', () {
      expect(const EveryDateView().query, 'all');
      expect(const OneDateView('soon').query, 'soon');
    });

    test('two views are the same where they show the same', () {
      expect(const EveryDateView(), const EveryDateView());
      expect(const OneDateView('soon'), const OneDateView('soon'));
      expect(const OneDateView('soon'), isNot(const OneDateView('later')));
      expect(const OneDateView('all'), isNot(const EveryDateView()));
    });
  });

  test('one date has no row; two have one', () {
    expect(showsDateRow(detail(const []).snapshot), isFalse);
    expect(showsDateRow(detail([date('soon', soon)]).snapshot), isFalse);
    expect(
      showsDateRow(
        detail([date('soon', soon), date('later', later, order: 1)]).snapshot,
      ),
      isTrue,
    );
  });

  group('defaultDateView', () {
    test('the default is the next date still to come', () {
      expect(
        defaultDateView(threeDates, now: now),
        const OneDateView('soon'),
      );
    });

    test('the earliest start opens, whatever the order of the dates', () {
      // As where the 3rd is added after the 10th, and takes the next place.
      final d = detail([
        date('later', later),
        date('soon', soon, order: 1),
      ]);

      expect(defaultDateView(d, now: now), const OneDateView('soon'));
    });

    test('a date still to be set counts as still to come, after those with '
        'a start, in the order of the dates', () {
      final d = detail([
        date('later', later, order: 2),
        date('tbd', null, order: 1),
        date('passed', passed),
      ]);
      expect(defaultDateView(d, now: now), const OneDateView('later'));

      final unset = detail([
        date('tbd-2', null, order: 2),
        date('tbd-1', null, order: 1),
        date('passed', passed),
      ]);
      expect(defaultDateView(unset, now: now), const OneDateView('tbd-1'));
    });

    test('a cancelled date is passed over', () {
      final d = detail([
        date('soon', soon, status: OccurrenceStatus.cancelled),
        date('later', later, order: 1),
      ]);

      expect(defaultDateView(d, now: now), const OneDateView('later'));
    });

    test('every date passed defaults to Every date', () {
      final d = detail([
        date('first', passed),
        date('second', passed.add(const Duration(days: 1)), order: 1),
      ]);

      expect(defaultDateView(d, now: now), const EveryDateView());
    });
  });

  group('dateViewOf', () {
    test('date=all is Every date; an unknown id is the default', () {
      expect(dateViewOf('all', threeDates, now: now), const EveryDateView());
      expect(
        dateViewOf('gone', threeDates, now: now),
        const OneDateView('soon'),
      );
    });

    test('a date of the event opens that date, a passed one too', () {
      expect(
        dateViewOf('later', threeDates, now: now),
        const OneDateView('later'),
      );
      expect(
        dateViewOf('passed', threeDates, now: now),
        const OneDateView('passed'),
      );
    });

    test('none, or an empty one, is the default', () {
      expect(dateViewOf(null, threeDates, now: now), const OneDateView('soon'));
      expect(dateViewOf('', threeDates, now: now), const OneDateView('soon'));
    });

    test('on an event with no row, no date names a view', () {
      final one = detail([date('soon', soon)]);

      expect(dateViewOf(null, one, now: now), isNull);
      expect(dateViewOf('all', one, now: now), isNull);
      expect(dateViewOf('soon', one, now: now), isNull);
      expect(dateViewOf('all', detail(const []), now: now), isNull);
    });
  });

  /// [d] as the screen holds it, with a detail read running where
  /// [reading], one settled with the dates' rules it carried still on their
  /// way to the cache where [arriving], and that one following a failed one
  /// where [afterFailure], an earlier one that carried no dates' rules where
  /// [withheld], and the last one failed where [failed].
  EventDetailReady ready(
    EventDetail d, {
    bool reading = false,
    bool arriving = false,
    bool afterFailure = false,
    bool withheld = false,
    bool failed = false,
  }) => EventDetailReady(
    detail: d,
    actions: const {},
    reading: reading,
    occurrencePoliciesArriving: arriving,
    occurrencePoliciesArrivingAfterFailure: afterFailure,
    occurrencePoliciesWithheld: withheld,
    refreshFailed: failed,
  );

  group('scopeMode (#1063)', () {
    final twoDates = [date('d-1', soon), date('d-2', later, order: 1)];

    test("a date's mode is unknown while its rules are unread and a read "
        'runs', () {
      final d = ready(
        detail(twoDates, eventPolicy: policy(GameAdditionMode.direct)),
        reading: true,
      );

      expect(scopeMode(d, 'd-1'), isNull);
      expect(viewMode(d, const OneDateView('d-1')), isNull);
    });

    test("a date's mode is unknown while a read's rules are on their way to "
        'the cache', () {
      final d = ready(
        detail(twoDates, eventPolicy: policy(GameAdditionMode.direct)),
        arriving: true,
      );

      expect(scopeMode(d, 'd-1'), isNull);
      expect(viewMode(d, const OneDateView('d-1')), isNull);
      // The whole event's is known all the same.
      expect(scopeMode(d, null), GameAdditionMode.direct);
    });

    test("a date's own mode once its rules are read", () {
      final d = ready(
        detail(
          twoDates,
          eventPolicy: policy(GameAdditionMode.direct),
          overrides: [override('d-1', GameAdditionMode.hostOnly)],
        ),
        reading: true,
      );

      expect(scopeMode(d, 'd-1'), GameAdditionMode.hostOnly);
      expect(
        viewMode(d, const OneDateView('d-1')),
        GameAdditionMode.hostOnly,
      );
    });

    test("unread rules with no read running fall back to the event's "
        'mode', () {
      final unread = detail(
        twoDates,
        eventPolicy: policy(GameAdditionMode.direct),
      );

      // None started, and one that failed.
      for (final d in [ready(unread), ready(unread, failed: true)]) {
        expect(scopeMode(d, 'd-1'), GameAdditionMode.direct);
        expect(
          viewMode(d, const OneDateView('d-1')),
          GameAdditionMode.direct,
        );
      }
    });

    test('a read running for a viewer refused the rules leaves the '
        "event's mode", () {
      final d = ready(
        detail(twoDates, eventPolicy: policy(GameAdditionMode.direct)),
        reading: true,
        withheld: true,
      );

      expect(scopeMode(d, 'd-1'), GameAdditionMode.direct);
      expect(viewMode(d, const OneDateView('d-1')), GameAdditionMode.direct);
    });

    test("a read running after one that failed leaves the event's mode, so "
        'the controls the failure left stay through the retry', () {
      final d = ready(
        detail(twoDates, eventPolicy: policy(GameAdditionMode.direct)),
        reading: true,
        failed: true,
      );

      expect(scopeMode(d, 'd-1'), GameAdditionMode.direct);
      expect(viewMode(d, const OneDateView('d-1')), GameAdditionMode.direct);
    });

    test("a retry's rules on their way to the cache after a failure leave "
        "the event's mode, so the controls the failure left stay until they "
        'land', () {
      final d = ready(
        detail(twoDates, eventPolicy: policy(GameAdditionMode.direct)),
        arriving: true,
        afterFailure: true,
      );

      expect(scopeMode(d, 'd-1'), GameAdditionMode.direct);
      expect(viewMode(d, const OneDateView('d-1')), GameAdditionMode.direct);
    });

    test("Every date and no row take the event's mode, even mid-read", () {
      final d = ready(
        detail(twoDates, eventPolicy: policy(GameAdditionMode.hostOnly)),
        reading: true,
      );

      expect(scopeMode(d, null), GameAdditionMode.hostOnly);
      expect(viewMode(d, const EveryDateView()), GameAdditionMode.hostOnly);
      expect(viewMode(d, null), GameAdditionMode.hostOnly);
    });
  });

  group('viewMode', () {
    final dated = ready(
      detail(
        [date('soon', soon), date('later', later, order: 1)],
        eventPolicy: policy(GameAdditionMode.requiresVote),
        overrides: [override('soon', GameAdditionMode.hostOnly)],
      ),
    );

    test('a date that overrides the mode to HostOnly has that mode in its '
        'view', () {
      expect(
        viewMode(dated, const OneDateView('soon')),
        GameAdditionMode.hostOnly,
      );
    });

    test("Every date takes the event's mode", () {
      expect(
        viewMode(dated, const EveryDateView()),
        GameAdditionMode.requiresVote,
      );
    });

    test("a date that overrides nothing takes the event's mode, and so "
        'does no row', () {
      expect(
        viewMode(dated, const OneDateView('later')),
        GameAdditionMode.requiresVote,
      );
      expect(viewMode(dated, null), GameAdditionMode.requiresVote);
    });
  });
}
