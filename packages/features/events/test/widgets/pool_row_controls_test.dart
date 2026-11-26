import 'package:events/events.dart';
import 'package:events/src/detail/nominate_scopes.dart';
import 'package:events/src/widgets/pool_row_controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// What Nominate offers on a pool row (#517), in the date view the row of
/// dates chose (#1042), and under that view's mode (#519).
void main() {
  final now = DateTime.utc(2026, 10, 1, 12);

  /// A confirmed date [days] from [now], [order]th among the event's.
  EventOccurrence date(String id, int days, {int order = 0}) =>
      confirmed(id, now.add(Duration(days: days)), sortOrder: order);

  final passed = date('passed', -3);
  final soon = date('soon', 2, order: 1);
  final later = date('later', 9, order: 2);

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

  /// [occurrenceId]'s own rules: only the hosts add games.
  EventOccurrencePolicy hostOnlyOn(String occurrenceId) =>
      occurrencePolicyOn(occurrenceId, mode: GameAdditionMode.hostOnly);

  /// The event on [dates], its games under [mode], needing a vote unless
  /// it says otherwise, with the dates' own [overrides], as an attending
  /// viewer who may nominate sees it.
  EventDetailReady ready(
    List<EventOccurrence> dates, {
    GameAdditionMode mode = GameAdditionMode.requiresVote,
    List<EventOccurrencePolicy> overrides = const [],
  }) => EventDetailReady(
    detail: EventDetail(
      snapshot: EventSnapshot(
        event: item('e').event,
        occurrences: dates,
        policy: policy(mode),
        occurrencePolicies: overrides,
      ),
      attendance: attendance(EventParticipationStatus.attending),
    ),
    actions: const {EventAction.nominateGame},
  );

  /// What [scopes] are for: null for the whole event, else the date's id.
  List<String?> forWhat(List<NominateScope> scopes) => [
    for (final each in scopes)
      switch (each.scope) {
        WholeEventScope() => null,
        DateScope(:final occurrenceId) => occurrenceId,
      },
  ];

  group('nominateChoicesIn', () {
    test("is null under a view whose mode offers no Nominate, and the view's "
        'choices otherwise', () {
      final detail = ready([soon, later], overrides: [hostOnlyOn('later')]);

      expect(
        nominateChoicesIn(detail, view: const OneDateView('later'), now: now),
        isNull,
      );
      expect(
        forWhat(
          nominateChoicesIn(
            detail,
            view: const OneDateView('soon'),
            now: now,
          )!,
        ),
        ['soon'],
      );
      expect(
        forWhat(
          nominateChoicesIn(detail, view: const EveryDateView(), now: now)!,
        ),
        [null],
      );
    });

    test('is empty, not null, under a date that takes no nomination now', () {
      final detail = ready([passed, soon]);

      expect(
        nominateChoicesIn(detail, view: const OneDateView('passed'), now: now),
        isEmpty,
      );
    });

    test("with no view, Nominate checks the whole event against the event's "
        'rule', () {
      // One date, so no row of dates: Nominate offers the whole event alone
      // (#1062), and a date that would take a vote doesn't open it (#1070).
      final detail = ready(
        [soon],
        mode: GameAdditionMode.hostOnly,
        overrides: [
          occurrencePolicyOn('soon', mode: GameAdditionMode.requiresVote),
        ],
      );

      expect(nominateChoicesIn(detail, view: null, now: now), isNull);
    });
  });
}
