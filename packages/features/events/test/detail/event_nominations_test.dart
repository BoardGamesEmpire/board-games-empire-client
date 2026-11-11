import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// The pure rules behind the nominations section (#517).
void main() {
  final at = DateTime.utc(2026, 9, 1, 12);

  EventNominationVote vote(
    String attendeeId,
    VoteType type, {
    bool eligible = true,
  }) => EventNominationVote(
    id: 'v-$attendeeId',
    attendeeId: attendeeId,
    voteType: type,
    eligible: eligible,
  );

  EventNomination nom(
    String id, {
    NominationStatus status = NominationStatus.open,
    String by = 'att-other',
    String supplied = 'o1',
    String? occurrenceId,
    DateTime? deadline,
    List<EventNominationVote> votes = const [],
  }) => EventNomination(
    id: id,
    eventId: 'e',
    occurrenceId: occurrenceId,
    platformGameId: 'pg',
    gameId: 'g',
    title: 'Game $id',
    platformName: 'Physical',
    status: status,
    votingDeadline: deadline,
    nominatedById: by,
    suppliedFromId: supplied,
    votes: votes,
    createdAt: at,
  );

  OfferedGame offered(String id, String attendeeId) => OfferedGame(
    id: id,
    attendeeId: attendeeId,
    collectionId: 'c-$id',
    platformGameId: 'pg',
    gameId: 'g',
    title: 'Game',
    platformName: 'Physical',
  );

  EventPolicy policy({
    GameAdditionMode mode = GameAdditionMode.requiresVote,
    VoteEligibility eligibility = VoteEligibility.allAttendees,
  }) => EventPolicy(
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
    voteThresholdType: VoteThresholdType.unknown,
    voteQuorumType: VoteQuorumType.unknown,
    voteEligibility: eligibility,
    interestedWeight: InterestedWeight.unknown,
    createdAt: at,
    updatedAt: at,
  );

  EventDetailReady ready({
    Set<EventAction> actions = const {EventAction.nominateGame},
    EventParticipationStatus? status = EventParticipationStatus.attending,
    EventPolicy? pol,
    bool localOnly = false,
    EventStatus eventStatus = EventStatus.planning,
    List<EventOccurrence> occurrences = const [],
  }) => EventDetailReady(
    detail: EventDetail(
      snapshot: EventSnapshot(
        event: item(
          'e',
        ).event.copyWith(isLocalOnly: localOnly, status: eventStatus),
        occurrences: occurrences,
        policy: pol,
      ),
      attendance: status == null ? null : attendance(status),
    ),
    actions: actions,
  );

  group('tallyOf', () {
    test("ignores votes that don't count", () {
      final n = nom(
        'a',
        votes: [
          vote('1', VoteType.forGame),
          vote('2', VoteType.forGame, eligible: false),
          vote('3', VoteType.against),
          vote('4', VoteType.interested),
          vote('5', VoteType.unknown),
        ],
      );

      expect(tallyOf(n), (forCount: 1, againstCount: 1, interestedCount: 1));
    });
  });

  group('statusGroupOf', () {
    test('groups statuses and leaves unknown out', () {
      expect(
        statusGroupOf(NominationStatus.open),
        NominationStatusGroup.voting,
      );
      expect(
        statusGroupOf(NominationStatus.quorumNotMet),
        NominationStatusGroup.decided,
      );
      expect(
        statusGroupOf(NominationStatus.paused),
        NominationStatusGroup.paused,
      );
      expect(statusGroupOf(NominationStatus.unknown), isNull);
    });
  });

  group('filterNominations', () {
    final all = [
      nom('a', by: 'att-me', votes: [vote('att-me', VoteType.forGame)]),
      nom('b', occurrenceId: 'd1'),
      nom('c', status: NominationStatus.passed),
      nom('d', status: NominationStatus.unknown),
    ];
    List<String> ids(NominationFilter f, {String? viewer = 'att-me'}) =>
        filterNominations(all, f, viewerId: viewer).map((n) => n.id).toList();

    test('an empty filter keeps everything', () {
      expect(const NominationFilter().narrows, isFalse);
      expect(ids(const NominationFilter()), ['a', 'b', 'c', 'd']);
    });

    test('status groups keep matching nominations; unknown matches none', () {
      expect(
        ids(
          const NominationFilter(statuses: {NominationStatusGroup.decided}),
        ),
        ['c'],
      );
      expect(
        ids(
          NominationFilter(statuses: NominationStatusGroup.values.toSet()),
        ),
        ['a', 'b', 'c'],
      );
    });

    test('scope keeps the whole event or one date', () {
      expect(
        ids(const NominationFilter(scope: WholeEventScope())),
        ['a', 'c', 'd'],
      );
      expect(ids(const NominationFilter(scope: DateScope('d1'))), ['b']);
    });

    test("mine keeps the viewer's, and nothing without a viewer", () {
      expect(ids(const NominationFilter(mine: true)), ['a']);
      expect(ids(const NominationFilter(mine: true), viewer: null), isEmpty);
    });

    test("notVotedYet keeps open nominations the viewer hasn't voted on", () {
      expect(ids(const NominationFilter(notVotedYet: true)), ['b']);
      expect(
        ids(const NominationFilter(notVotedYet: true), viewer: null),
        isEmpty,
      );
    });

    test('criteria apply together', () {
      expect(
        ids(const NominationFilter(mine: true, notVotedYet: true)),
        isEmpty,
      );
    });
  });

  group('sortNominations', () {
    test('newest keeps the input order', () {
      final list = [nom('a'), nom('b')];
      expect(
        sortNominations(list, NominationSort.newest).map((n) => n.id),
        ['a', 'b'],
      );
    });

    test('mostSupport sorts by For among counting votes and is stable', () {
      final list = [
        nom('a', votes: [vote('1', VoteType.forGame)]),
        nom(
          'b',
          votes: [
            vote('1', VoteType.forGame),
            vote('2', VoteType.forGame),
            vote('3', VoteType.forGame, eligible: false),
          ],
        ),
        nom('c', votes: [vote('1', VoteType.forGame)]),
        nom('d', votes: [vote('1', VoteType.forGame, eligible: false)]),
      ];

      expect(
        sortNominations(list, NominationSort.mostSupport).map((n) => n.id),
        ['b', 'a', 'c', 'd'],
      );
    });

    test('soonestDeadline puts nominations without a deadline last', () {
      final list = [
        nom('a'),
        nom('b', deadline: DateTime.utc(2026, 10, 2)),
        nom('c', deadline: DateTime.utc(2026, 10)),
        nom('d'),
      ];

      expect(
        sortNominations(list, NominationSort.soonestDeadline).map((n) => n.id),
        ['c', 'b', 'a', 'd'],
      );
    });
  });

  group('nominateGate', () {
    test('is open for an attending participant', () {
      expect(nominateGate(ready()), NominateGate.open);
      expect(nominateGate(ready(pol: policy())), NominateGate.open);
    });

    test('is hidden under HostOnly', () {
      expect(
        nominateGate(ready(pol: policy(mode: GameAdditionMode.hostOnly))),
        NominateGate.hidden,
      );
    });

    test('is hidden for a guest', () {
      expect(
        nominateGate(ready(actions: const {})),
        NominateGate.hidden,
      );
    });

    test(
      'is hidden with no roster row, local-only or on a cancelled event',
      () {
        expect(nominateGate(ready(status: null)), NominateGate.hidden);
        expect(nominateGate(ready(localOnly: true)), NominateGate.hidden);
        expect(
          nominateGate(ready(eventStatus: EventStatus.cancelled)),
          NominateGate.hidden,
        );
      },
    );
  });

  group('suppliesLive', () {
    final game = offered('o1', 'att-me');

    test('ignores withdrawn and decided nominations', () {
      final all = [
        nom('a', status: NominationStatus.withdrawn),
        nom('b', status: NominationStatus.passed),
        nom('c', supplied: 'o2'),
      ];
      expect(suppliesLive(game, all), isFalse);
      expect(
        suppliesLive(game, [...all, nom('d', status: NominationStatus.paused)]),
        isTrue,
      );
    });

    test('with a scope, needs the same scope', () {
      final all = [nom('a', occurrenceId: 'd1')];
      expect(suppliesLive(game, all, scope: const DateScope('d1')), isTrue);
      expect(suppliesLive(game, all, scope: const DateScope('d2')), isFalse);
      expect(suppliesLive(game, all, scope: const WholeEventScope()), isFalse);
      expect(suppliesLive(game, all), isTrue);
    });
  });

  group('stillSuppliedBy', () {
    const game = 'o1';

    test("names the viewer where every live nomination is the viewer's", () {
      final all = [
        nom('a', by: 'att-me'),
        nom('b', by: 'att-ada', status: NominationStatus.withdrawn),
      ];
      expect(
        stillSuppliedBy(game, all, viewerId: 'att-me'),
        StillSuppliedBy.viewer,
      );
    });

    test('names the viewer and someone else where both hold one', () {
      final all = [nom('a'), nom('b', by: 'att-me')];
      expect(
        stillSuppliedBy(game, all, viewerId: 'att-me'),
        StillSuppliedBy.viewerAndSomeoneElse,
      );
    });

    test('names someone else, or none', () {
      expect(
        stillSuppliedBy(game, [nom('a')], viewerId: 'att-me'),
        StillSuppliedBy.someoneElse,
      );
      expect(
        stillSuppliedBy(game, [nom('a', by: 'att-me')], viewerId: null),
        StillSuppliedBy.someoneElse,
      );
      expect(
        stillSuppliedBy(
          game,
          [nom('a', by: 'att-me', status: NominationStatus.withdrawn)],
          viewerId: 'att-me',
        ),
        StillSuppliedBy.none,
      );
    });
  });

  group('voteHintFor', () {
    test(
      'says countsWhenOffering under PoolParticipants with no own pool rows',
      () {
        final state = ready(
          pol: policy(eligibility: VoteEligibility.poolParticipants),
        );
        expect(
          voteHintFor(state, pool: [offered('o1', 'att-other')]),
          VoteHint.countsWhenOffering,
        );
        expect(voteHintFor(state, pool: [offered('o1', 'att-me')]), isNull);
      },
    );

    test('says countsWhenAttending under ConfirmedOnly until they attend', () {
      final pol = policy(eligibility: VoteEligibility.confirmedOnly);
      expect(
        voteHintFor(
          ready(pol: pol, status: EventParticipationStatus.maybe),
          pool: const [],
        ),
        VoteHint.countsWhenAttending,
      );
      expect(voteHintFor(ready(pol: pol), pool: const []), isNull);
    });

    test('is null with no policy or no attendance', () {
      expect(voteHintFor(ready(), pool: const []), isNull);
      expect(
        voteHintFor(
          ready(
            status: null,
            pol: policy(eligibility: VoteEligibility.confirmedOnly),
          ),
          pool: const [],
        ),
        isNull,
      );
    });
  });

  group('nominatableDates', () {
    final now = DateTime.utc(2026, 9, 10);

    test('leaves out cancelled, declined and past dates', () {
      EventOccurrence occ(
        String id,
        OccurrenceStatus status,
        DateTime? start,
        int order,
      ) => confirmed(
        id,
        start ?? now,
        sortOrder: order,
      ).copyWith(status: status, startDate: start);

      final detail = ready(
        occurrences: [
          occ(
            'later',
            OccurrenceStatus.confirmed,
            DateTime.utc(2026, 9, 20),
            3,
          ),
          occ('tbd', OccurrenceStatus.proposed, null, 1),
          occ(
            'cancelled',
            OccurrenceStatus.cancelled,
            DateTime.utc(2026, 9, 21),
            0,
          ),
          occ(
            'declined',
            OccurrenceStatus.declined,
            DateTime.utc(2026, 9, 22),
            0,
          ),
          occ('past', OccurrenceStatus.confirmed, DateTime.utc(2026, 9), 0),
          occ(
            'unknown',
            OccurrenceStatus.unknown,
            DateTime.utc(2026, 9, 23),
            0,
          ),
        ],
      ).detail;

      expect(
        nominatableDates(detail, now: now).map((o) => o.id),
        ['tbd', 'later'],
      );
    });
  });

  group('nextDeadlinePassing', () {
    final now = DateTime.utc(2026, 10, 1, 12);

    test("is a moment past the soonest open nomination's deadline ahead", () {
      final soon = now.add(const Duration(hours: 1));
      final later = now.add(const Duration(hours: 2));

      expect(
        nextDeadlinePassing([
          nom('later', deadline: later),
          nom('none'),
          nom('soon', deadline: soon),
          // Not open, so no line turns.
          nom(
            'paused',
            status: NominationStatus.paused,
            deadline: now.add(const Duration(minutes: 1)),
          ),
          // Passed already.
          nom('past', deadline: now.subtract(const Duration(minutes: 1))),
        ], now: now),
        soon.add(const Duration(milliseconds: 1)),
      );
    });

    test('a deadline at the clock has not passed yet', () {
      expect(
        nextDeadlinePassing([nom('n', deadline: now)], now: now),
        now.add(const Duration(milliseconds: 1)),
      );
    });

    // On the web a DateTime holds milliseconds, so a microsecond past the
    // deadline would be the deadline itself, and a timer firing on it would
    // leave the line unturned with nothing ahead.
    test('a moment past is a whole millisecond, which the web can hold', () {
      final passing = nextDeadlinePassing([nom('n', deadline: now)], now: now)!;

      expect(passing.difference(now), const Duration(milliseconds: 1));
      expect(
        nextDeadlinePassing([nom('n', deadline: now)], now: passing),
        isNull,
      );
    });

    test('is null with no open deadline ahead', () {
      expect(
        nextDeadlinePassing([
          nom('none'),
          nom('past', deadline: now.subtract(const Duration(seconds: 1))),
          nom(
            'decided',
            status: NominationStatus.passed,
            deadline: now.add(const Duration(hours: 1)),
          ),
        ], now: now),
        isNull,
      );
    });
  });
}
