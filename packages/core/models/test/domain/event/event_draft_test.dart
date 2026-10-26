import 'package:models/domain.dart';
import 'package:test/test.dart';

const _draft = EventDraft(title: 'Friday night');

/// What [ArgumentError] reports for the field it refused.
Matcher _refusing(String field) =>
    throwsA(isA<ArgumentError>().having((e) => e.name, 'name', field));

void main() {
  group('EventDraft.checkSendable', () {
    test('accepts a draft that sets nothing but its title', () {
      expect(_draft.checkSendable, returnsNormally);
    });

    test('accepts a draft whose every enum is a known value', () {
      final draft = _draft.copyWith(
        type: EventType.casualGathering,
        reach: Reach.friends,
        schedulingMode: EventSchedulingMode.poll,
        policy: const EventPolicyDraft(
          gameAdditionMode: GameAdditionMode.requiresVote,
          voteThresholdType: VoteThresholdType.supermajority,
          voteThresholdValue: 66,
          voteQuorumType: VoteQuorumType.percentOfAttendees,
          voteQuorumValue: 50,
        ),
      );

      expect(draft.checkSendable, returnsNormally);
    });

    group('the vote values', () {
      EventDraft withPolicy(EventPolicyDraft policy) =>
          _draft.copyWith(policy: policy);

      test('refuses a threshold type that takes a value, sent without '
          'one', () {
        for (final type in [
          VoteThresholdType.supermajority,
          VoteThresholdType.fixedCount,
        ]) {
          expect(
            withPolicy(EventPolicyDraft(voteThresholdType: type)).checkSendable,
            _refusing('draft.policy.voteThresholdValue'),
            reason: '$type',
          );
        }
      });

      test('refuses a quorum type that takes a value, sent without one', () {
        for (final type in [
          VoteQuorumType.percentOfAttendees,
          VoteQuorumType.fixedCount,
        ]) {
          expect(
            withPolicy(EventPolicyDraft(voteQuorumType: type)).checkSendable,
            _refusing('draft.policy.voteQuorumValue'),
            reason: '$type',
          );
        }
      });

      test('refuses a value below 1 where the type takes one', () {
        expect(
          withPolicy(
            const EventPolicyDraft(
              voteThresholdType: VoteThresholdType.fixedCount,
              voteThresholdValue: 0,
            ),
          ).checkSendable,
          _refusing('draft.policy.voteThresholdValue'),
        );
        expect(
          withPolicy(
            const EventPolicyDraft(
              voteQuorumType: VoteQuorumType.fixedCount,
              voteQuorumValue: 0,
            ),
          ).checkSendable,
          _refusing('draft.policy.voteQuorumValue'),
        );
      });

      test('ignores a value the type does not take, as the server does', () {
        // Its validators run only for the types that read the value.
        final draft = withPolicy(
          const EventPolicyDraft(
            voteThresholdType: VoteThresholdType.simpleMajority,
            voteThresholdValue: 0,
            voteQuorumType: VoteQuorumType.none,
            voteQuorumValue: 0,
          ),
        );

        expect(draft.checkSendable, returnsNormally);
      });

      test('refuses a voting window below 1, and accepts none', () {
        expect(
          withPolicy(const EventPolicyDraft(votingWindowHours: 0))
              .checkSendable,
          _refusing('draft.policy.votingWindowHours'),
        );
        expect(
          withPolicy(const EventPolicyDraft(votingWindowHours: 1))
              .checkSendable,
          returnsNormally,
        );
        expect(
          withPolicy(const EventPolicyDraft()).checkSendable,
          returnsNormally,
        );
      });
    });

    group('refuses an unknown', () {
      test('type', () {
        final draft = _draft.copyWith(type: EventType.unknown);

        expect(draft.checkSendable, _refusing('draft.type'));
      });

      test('reach', () {
        final draft = _draft.copyWith(reach: Reach.unknown);

        expect(draft.checkSendable, _refusing('draft.reach'));
      });

      test('schedulingMode', () {
        final draft = _draft.copyWith(
          schedulingMode: EventSchedulingMode.unknown,
        );

        expect(draft.checkSendable, _refusing('draft.schedulingMode'));
      });

      test('policy.gameAdditionMode', () {
        final draft = _draft.copyWith(
          policy: const EventPolicyDraft(
            gameAdditionMode: GameAdditionMode.unknown,
          ),
        );

        expect(draft.checkSendable, _refusing('draft.policy.gameAdditionMode'));
      });

      test('policy.voteThresholdType', () {
        final draft = _draft.copyWith(
          policy: const EventPolicyDraft(
            voteThresholdType: VoteThresholdType.unknown,
          ),
        );

        expect(
          draft.checkSendable,
          _refusing('draft.policy.voteThresholdType'),
        );
      });

      test('policy.voteQuorumType', () {
        final draft = _draft.copyWith(
          policy: const EventPolicyDraft(
            voteQuorumType: VoteQuorumType.unknown,
          ),
        );

        expect(draft.checkSendable, _refusing('draft.policy.voteQuorumType'));
      });
    });

    group('the invitee ceiling', () {
      List<String> invitees(int count) => [
        for (var i = 0; i < count; i++) 'user_$i',
      ];

      test('allows exactly ${EventDraft.maxInvitees}', () {
        final draft = _draft.copyWith(
          inviteUserIds: invitees(EventDraft.maxInvitees),
        );

        expect(draft.checkSendable, returnsNormally);
      });

      test('refuses one more', () {
        final draft = _draft.copyWith(
          inviteUserIds: invitees(EventDraft.maxInvitees + 1),
        );

        expect(draft.checkSendable, _refusing('draft.inviteUserIds'));
      });
    });
  });
}
