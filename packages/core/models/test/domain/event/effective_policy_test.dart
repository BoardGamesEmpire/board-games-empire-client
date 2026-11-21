import 'package:models/domain.dart';
import 'package:test/test.dart';

final _at = DateTime.utc(2026, 10, 22, 19);

EventPolicy _policy({
  GameAdditionMode mode = GameAdditionMode.requiresVote,
  int? votingWindowHours = 24,
}) => EventPolicy(
  id: 'policy_1',
  eventId: 'event_1',
  allowMemberInvites: true,
  allowGuestInvites: false,
  restrictToGameCategories: false,
  requireHostApprovalToJoin: false,
  allowSpectators: true,
  strictCapacity: false,
  gameAdditionMode: mode,
  restrictToAttendeePool: false,
  voteThresholdType: VoteThresholdType.supermajority,
  voteQuorumType: VoteQuorumType.fixedCount,
  voteEligibility: VoteEligibility.allAttendees,
  interestedWeight: InterestedWeight.asFor,
  createdAt: _at,
  updatedAt: _at,
  voteThresholdValue: 66,
  voteQuorumValue: 3,
  votingWindowHours: votingWindowHours,
);

EventOccurrencePolicy _override({
  String occurrenceId = 'occ_1',
  GameAdditionMode? mode,
}) => EventOccurrencePolicy(
  id: 'opolicy_$occurrenceId',
  occurrenceId: occurrenceId,
  allowedCategoryIds: const [],
  allowedPlatformIds: const [],
  allowedPlatformTypes: const [],
  platformTypesUnrestricted: false,
  platformsUnrestricted: false,
  capacityUnrestricted: false,
  gameAdditionMode: mode,
  createdAt: _at,
  updatedAt: _at,
);

EventSnapshot _snapshot({
  EventPolicy? policy,
  List<EventOccurrencePolicy>? overrides,
}) => EventSnapshot(
  event: Event(
    id: 'event_1',
    title: 'Friday night',
    createdById: 'user_1',
    type: EventType.casualGathering,
    reach: Reach.friends,
    status: EventStatus.scheduled,
    schedulingMode: EventSchedulingMode.fixed,
    createdAt: _at,
    updatedAt: _at,
  ),
  occurrences: const [],
  policy: policy,
  occurrencePolicies: overrides,
);

void main() {
  group('effectiveGamePolicy', () {
    test('a date that sets the mode overrides the event', () {
      final p = effectiveGamePolicy(
        _policy(),
        _override(mode: GameAdditionMode.hostOnly),
      );

      expect(p.gameAdditionMode, GameAdditionMode.hostOnly);
    });

    test("a date that sets nothing takes the event's values", () {
      final p = effectiveGamePolicy(_policy(), _override());

      expect(p.gameAdditionMode, GameAdditionMode.requiresVote);
      expect(p.voteThresholdType, VoteThresholdType.supermajority);
      expect(p.voteThresholdValue, 66);
      expect(p.voteQuorumType, VoteQuorumType.fixedCount);
      expect(p.voteQuorumValue, 3);
      expect(p.voteEligibility, VoteEligibility.allAttendees);
      expect(p.interestedWeight, InterestedWeight.asFor);
      expect(p.votingWindowHours, 24);
    });

    test('a date that sets a vote field overrides only that field', () {
      final date = _override().copyWith(
        voteThresholdType: VoteThresholdType.unanimous,
        votingWindowHours: 2,
      );
      final p = effectiveGamePolicy(_policy(), date);

      expect(p.voteThresholdType, VoteThresholdType.unanimous);
      expect(p.votingWindowHours, 2);
      expect(p.voteQuorumValue, 3);
    });

    test('no event policy and no override gives the server defaults', () {
      final p = effectiveGamePolicy(null, null);

      expect(p.gameAdditionMode, GameAdditionMode.direct);
      expect(p.voteThresholdType, VoteThresholdType.simpleMajority);
      expect(p.voteThresholdValue, isNull);
      expect(p.voteQuorumType, VoteQuorumType.none);
      expect(p.voteQuorumValue, isNull);
      expect(p.voteEligibility, VoteEligibility.confirmedOnly);
      expect(p.interestedWeight, InterestedWeight.asAbstain);
      expect(p.votingWindowHours, isNull);
    });
  });

  group('EventSnapshotGamePolicy', () {
    test("gamePolicyFor(null) is the event's, and a date without an "
        'override is too', () {
      final snapshot = _snapshot(
        policy: _policy(),
        overrides: [_override(mode: GameAdditionMode.hostOnly)],
      );

      expect(
        snapshot.gamePolicyFor(null).gameAdditionMode,
        GameAdditionMode.requiresVote,
      );
      expect(
        snapshot.gamePolicyFor('occ_other').gameAdditionMode,
        GameAdditionMode.requiresVote,
      );
    });

    test("a date's override is read from occurrencePolicies", () {
      final snapshot = _snapshot(
        policy: _policy(),
        overrides: [_override(mode: GameAdditionMode.hostOnly)],
      );

      expect(
        snapshot.gamePolicyFor('occ_1').gameAdditionMode,
        GameAdditionMode.hostOnly,
      );
    });

    test('a read that carried no override list folds to the event', () {
      expect(
        _snapshot(policy: _policy()).gamePolicyFor('occ_1').gameAdditionMode,
        GameAdditionMode.requiresVote,
      );
    });
  });
}
