import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/lineup_row_controls.dart';
import 'package:events/src/widgets/pool_row_controls.dart' show NominateScope;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// What a direct add can be for (#519), in the date view the row of dates
/// chose (#1042) and under that view's mode, and the longest a Filler
/// should run by the rules of what it is for.
void main() {
  final now = DateTime.utc(2026, 10, 1, 12);

  /// A confirmed date [days] from [now], [order]th among the event's.
  EventOccurrence date(String id, int days, {int order = 0}) =>
      confirmed(id, now.add(Duration(days: days)), sortOrder: order);

  final started = date('started', -1);
  final soon = date('soon', 2, order: 1);
  final proposed = date(
    'proposed',
    5,
    order: 2,
  ).copyWith(status: OccurrenceStatus.proposed);
  final cancelled = date(
    'cancelled',
    9,
    order: 3,
  ).copyWith(status: OccurrenceStatus.cancelled);
  final declined = date(
    'declined',
    12,
    order: 4,
  ).copyWith(status: OccurrenceStatus.declined);

  EventPolicy policy(GameAdditionMode mode, {int? filler}) => EventPolicy(
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
    fillerMaxPlayTime: filler,
    createdAt: kItemInstant,
    updatedAt: kItemInstant,
  );

  /// [occurrenceId]'s own rules: [mode], and [filler] minutes at most.
  EventOccurrencePolicy rulesOn(
    String occurrenceId, {
    GameAdditionMode? mode,
    int? filler,
  }) => EventOccurrencePolicy(
    id: 'op-$occurrenceId',
    occurrenceId: occurrenceId,
    allowedCategoryIds: const [],
    allowedPlatformIds: const [],
    allowedPlatformTypes: const [],
    platformTypesUnrestricted: false,
    platformsUnrestricted: false,
    capacityUnrestricted: false,
    gameAdditionMode: mode,
    fillerMaxPlayTime: filler,
    createdAt: kItemInstant,
    updatedAt: kItemInstant,
  );

  /// The event on [dates], its games under [mode], with the dates' own
  /// [overrides], as an attending host sees it.
  EventDetailReady ready(
    List<EventOccurrence> dates, {
    GameAdditionMode mode = GameAdditionMode.hostOnly,
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
    actions: const {EventAction.addToLineup},
  );

  /// What [scopes] are for: null for the whole event, else the date's id.
  List<String?> forWhat(List<NominateScope> scopes) => [
    for (final (:scope, date: _) in scopes)
      switch (scope) {
        WholeEventScope() => null,
        DateScope(:final occurrenceId) => occurrenceId,
      },
  ];

  final all = [started, soon, proposed, cancelled, declined];

  group('lineupAddScopes', () {
    test('a date that has started still takes an add, while it is live', () {
      final detail = ready(all).detail;

      for (final id in ['started', 'soon', 'proposed']) {
        expect(
          forWhat(lineupAddScopes(detail, view: OneDateView(id))),
          [id],
          reason: id,
        );
      }
    });

    test('a date called off or declined takes none', () {
      final detail = ready(all).detail;

      for (final id in ['cancelled', 'declined', 'not-a-date']) {
        expect(
          lineupAddScopes(detail, view: OneDateView(id)),
          isEmpty,
          reason: id,
        );
      }
    });

    test('Every date adds to the whole event', () {
      expect(
        forWhat(
          lineupAddScopes(ready(all).detail, view: const EveryDateView()),
        ),
        [null],
      );
    });

    test('with no row, the whole event, then the one date, started or not', () {
      expect(forWhat(lineupAddScopes(ready([started]).detail)), [
        null,
        'started',
      ]);
      expect(forWhat(lineupAddScopes(ready([cancelled]).detail)), [null]);
      expect(forWhat(lineupAddScopes(ready(const []).detail)), [null]);
    });
  });

  group('lineupAddChoicesIn', () {
    test("follows the view's mode: none where it takes no direct add", () {
      final detail = ready(
        [started, soon],
        mode: GameAdditionMode.requiresVote,
        overrides: [rulesOn('soon', mode: GameAdditionMode.hostOnly)],
      );

      expect(
        lineupAddChoicesIn(detail, view: const OneDateView('started')),
        isNull,
      );
      expect(lineupAddChoicesIn(detail, view: const EveryDateView()), isNull);
      expect(
        forWhat(lineupAddChoicesIn(detail, view: const OneDateView('soon'))!),
        ['soon'],
      );
    });
  });

  group('lineupAddClosedReason', () {
    final l10n = lookupEventsLocalizations(const Locale('en'));
    final unread = date('unread', 3).copyWith(status: OccurrenceStatus.unknown);
    final detail = ready([...all, unread]).detail;

    test("a date called off or declined isn't happening", () {
      for (final id in ['cancelled', 'declined']) {
        expect(
          lineupAddClosedReason(l10n, detail, OneDateView(id)),
          "This date isn't happening, so games can't be added to it",
          reason: id,
        );
      }
    });

    test("a date this client can't read says only that nothing can be "
        'added', () {
      expect(
        lineupAddClosedReason(l10n, detail, const OneDateView('unread')),
        "Games can't be added to this date",
      );
      expect(
        lineupAddScopes(detail, view: const OneDateView('unread')),
        isEmpty,
      );
    });
  });

  group('fillerMaxPlayTimeFor', () {
    test("a date's own rule, else the event's", () {
      final snapshot = EventSnapshot(
        event: item('e').event,
        occurrences: [soon, proposed],
        policy: policy(GameAdditionMode.hostOnly, filler: 20),
        occurrencePolicies: [rulesOn('soon', filler: 15)],
      );

      expect(fillerMaxPlayTimeFor(snapshot, null), 20);
      expect(fillerMaxPlayTimeFor(snapshot, 'soon'), 15);
      expect(fillerMaxPlayTimeFor(snapshot, 'proposed'), 20);
      expect(
        fillerMaxPlayTimeFor(snapshot.copyWith(policy: null), 'proposed'),
        isNull,
      );
    });
  });
}
