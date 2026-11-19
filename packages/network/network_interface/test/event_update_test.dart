import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('EventUpdate', () {
    test('is equal by its fields, with its text trimmed', () {
      // The bloc event that carries it compares by its props (#500).
      expect(
        EventUpdate(title: ' Game night ', clearUrl: true, reach: Reach.public),
        EventUpdate(title: 'Game night', clearUrl: true, reach: Reach.public),
      );
      expect(
        EventUpdate(title: 'Game night').hashCode,
        EventUpdate(title: 'Game night').hashCode,
      );
      expect(EventUpdate(title: 'a'), isNot(EventUpdate(location: 'a')));
    });

    test('a blank value is refused', () {
      expect(() => EventUpdate(title: '  '), throwsArgumentError);
      expect(() => EventUpdate(description: ''), throwsArgumentError);
      expect(() => EventUpdate(location: ' '), throwsArgumentError);
      expect(() => EventUpdate(url: ''), throwsArgumentError);
    });

    test('a value and its own clear flag are refused together', () {
      expect(
        () => EventUpdate(url: 'https://x.test', clearUrl: true),
        throwsArgumentError,
      );
      expect(
        () => EventUpdate(description: 'd', clearDescription: true),
        throwsArgumentError,
      );
      expect(
        () => EventUpdate(location: 'l', clearLocation: true),
        throwsArgumentError,
      );
    });

    test('an unknown type or reach is refused', () {
      expect(() => EventUpdate(type: EventType.unknown), throwsArgumentError);
      expect(() => EventUpdate(reach: Reach.unknown), throwsArgumentError);
    });

    test('isEmpty is true for the bare constructor only', () {
      expect(EventUpdate().isEmpty, isTrue);
      expect(EventUpdate(clearLocation: true).isEmpty, isFalse);
      expect(EventUpdate(reach: Reach.friends).isEmpty, isFalse);
    });
  });

  group('EventPolicyUpdate', () {
    test('is equal by its fields', () {
      expect(
        EventPolicyUpdate(voteThresholdValue: 75, clearVotingWindowHours: true),
        EventPolicyUpdate(voteThresholdValue: 75, clearVotingWindowHours: true),
      );
      expect(
        EventPolicyUpdate(voteQuorumValue: 2).hashCode,
        EventPolicyUpdate(voteQuorumValue: 2).hashCode,
      );
      expect(
        EventPolicyUpdate(voteQuorumValue: 2),
        isNot(EventPolicyUpdate(voteThresholdValue: 2)),
      );
    });

    test('an unknown enum is refused', () {
      expect(
        () => EventPolicyUpdate(gameAdditionMode: GameAdditionMode.unknown),
        throwsArgumentError,
      );
      expect(
        () => EventPolicyUpdate(voteThresholdType: VoteThresholdType.unknown),
        throwsArgumentError,
      );
      expect(
        () => EventPolicyUpdate(voteQuorumType: VoteQuorumType.unknown),
        throwsArgumentError,
      );
    });

    test('a window and its clear flag are refused together', () {
      expect(
        () => EventPolicyUpdate(
          votingWindowHours: 4,
          clearVotingWindowHours: true,
        ),
        throwsArgumentError,
      );
    });

    test('a number below 1 is refused', () {
      expect(
        () => EventPolicyUpdate(voteThresholdValue: 0),
        throwsArgumentError,
      );
      expect(() => EventPolicyUpdate(voteQuorumValue: -1), throwsArgumentError);
      expect(
        () => EventPolicyUpdate(votingWindowHours: 0),
        throwsArgumentError,
      );
    });

    test('isEmpty is true for the bare constructor only', () {
      expect(EventPolicyUpdate().isEmpty, isTrue);
      expect(EventPolicyUpdate(clearVotingWindowHours: true).isEmpty, isFalse);
      expect(EventPolicyUpdate(voteQuorumValue: 1).isEmpty, isFalse);
    });
  });
}
