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
          voteQuorumType: VoteQuorumType.percentOfAttendees,
        ),
      );

      expect(draft.checkSendable, returnsNormally);
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
