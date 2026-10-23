import 'package:models/domain.dart';
import 'package:test/test.dart';

/// Registers the wire contract every server enum the event models read shares
/// (#496) as one group of three tests.
///
/// [wireNames] is written out by hand from the backend's own enum, so a
/// `fromWire` or `toWire` arm that is mistyped, or that maps to the wrong value,
/// fails the first test whichever of the two it sits in.
void _wireContract<T extends Enum>({
  required List<String> wireNames,
  required List<T> values,
  required T unknown,
  required T Function(String) fromWire,
  required String Function(T) toWire,
  String unrecognised = 'SomeFutureName',
}) {
  group('$T', () {
    test('fromWire maps every wire name', () {
      for (final wire in wireNames) {
        final value = fromWire(wire);
        expect(
          value,
          isNot(unknown),
          reason: '$T.fromWire("$wire") fell through to unknown',
        );
        expect(
          toWire(value),
          wire,
          reason: '$T.${value.name} should read and write "$wire"',
        );
      }

      // `fromWire` ends in a `_` arm, so a value left out of its switch reads as
      // `unknown` instead of failing to compile. Holding the list to the enum's
      // own values is what turns that miss into a failure here.
      expect(
        wireNames.map(fromWire).toSet(),
        values.where((value) => value != unknown).toSet(),
        reason: 'the wire names should cover every $T but unknown, once each',
      );
    });

    test('an unrecognised name reads as unknown', () {
      expect(fromWire(unrecognised), unknown);
    });

    test('unknown has no wire name', () {
      expect(() => toWire(unknown), throwsStateError);
    });
  });
}

void main() {
  _wireContract<EventStatus>(
    wireNames: const [
      'Archived',
      'Cancelled',
      'Completed',
      'Ongoing',
      'Planning',
      'Scheduled',
    ],
    values: EventStatus.values,
    unknown: EventStatus.unknown,
    fromWire: EventStatus.fromWire,
    toWire: (status) => status.toWire(),
    unrecognised: 'Postponed',
  );

  _wireContract<EventSchedulingMode>(
    wireNames: const ['Fixed', 'Poll', 'MultiDay'],
    values: EventSchedulingMode.values,
    unknown: EventSchedulingMode.unknown,
    fromWire: EventSchedulingMode.fromWire,
    toWire: (mode) => mode.toWire(),
  );

  _wireContract<EventType>(
    wireNames: const [
      'AdultsOnly',
      'CasualGathering',
      'CompetitivePlay',
      'FamilyNight',
      'KidFriendly',
      'LearningSession',
      'LongGameDay',
      'MixedAges',
      'PartyGames',
      'StrategyNight',
    ],
    values: EventType.values,
    unknown: EventType.unknown,
    fromWire: EventType.fromWire,
    toWire: (type) => type.toWire(),
  );

  _wireContract<Reach>(
    wireNames: const ['Friends', 'FriendsOfFriends', 'Private', 'Public'],
    values: Reach.values,
    unknown: Reach.unknown,
    fromWire: Reach.fromWire,
    toWire: (reach) => reach.toWire(),
  );

  _wireContract<OccurrenceStatus>(
    wireNames: const ['Proposed', 'Confirmed', 'Declined', 'Cancelled'],
    values: OccurrenceStatus.values,
    unknown: OccurrenceStatus.unknown,
    fromWire: OccurrenceStatus.fromWire,
    toWire: (status) => status.toWire(),
  );

  _wireContract<EventParticipationStatus>(
    wireNames: const ['Attending', 'Invited', 'Maybe', 'NotAttending'],
    values: EventParticipationStatus.values,
    unknown: EventParticipationStatus.unknown,
    fromWire: EventParticipationStatus.fromWire,
    toWire: (status) => status.toWire(),
  );

  _wireContract<EventRole>(
    wireNames: const [
      'EventHost',
      'EventCoHost',
      'EventOrganizer',
      'EventModerator',
      'EventParticipant',
      'EventGuest',
      'EventSpectator',
    ],
    values: EventRole.values,
    unknown: EventRole.unknown,
    fromWire: EventRole.fromWire,
    toWire: (role) => role.toWire(),
    unrecognised: 'EventScorekeeper',
  );

  _wireContract<GameAdditionMode>(
    wireNames: const ['Direct', 'RequiresVote', 'HostApproval', 'HostOnly'],
    values: GameAdditionMode.values,
    unknown: GameAdditionMode.unknown,
    fromWire: GameAdditionMode.fromWire,
    toWire: (mode) => mode.toWire(),
  );

  _wireContract<VoteThresholdType>(
    wireNames: const [
      'SimpleMajority',
      'Supermajority',
      'Unanimous',
      'FixedCount',
    ],
    values: VoteThresholdType.values,
    unknown: VoteThresholdType.unknown,
    fromWire: VoteThresholdType.fromWire,
    toWire: (type) => type.toWire(),
  );

  _wireContract<VoteQuorumType>(
    wireNames: const ['None', 'PercentOfAttendees', 'FixedCount'],
    values: VoteQuorumType.values,
    unknown: VoteQuorumType.unknown,
    fromWire: VoteQuorumType.fromWire,
    toWire: (type) => type.toWire(),
  );

  _wireContract<VoteEligibility>(
    wireNames: const ['AllAttendees', 'ConfirmedOnly', 'PoolParticipants'],
    values: VoteEligibility.values,
    unknown: VoteEligibility.unknown,
    fromWire: VoteEligibility.fromWire,
    toWire: (eligibility) => eligibility.toWire(),
  );

  _wireContract<InterestedWeight>(
    wireNames: const ['AsFor', 'AsAbstain', 'AsAgainst'],
    values: InterestedWeight.values,
    unknown: InterestedWeight.unknown,
    fromWire: InterestedWeight.fromWire,
    toWire: (weight) => weight.toWire(),
  );
}
