import 'package:test/test.dart';
import 'package:models/domain.dart';

void main() {
  group('MemberInvitePolicy', () {
    test('fromWire maps every wire name', () {
      const expectations = <String, MemberInvitePolicy>{
        'Direct': MemberInvitePolicy.direct,
        'NeedsApproval': MemberInvitePolicy.needsApproval,
        'Off': MemberInvitePolicy.off,
      };

      for (final entry in expectations.entries) {
        final policy = MemberInvitePolicy.fromWire(entry.key);
        expect(policy, equals(entry.value));
        expect(policy.toWire(), equals(entry.key));
      }
    });

    test('an unrecognised name reads as unknown', () {
      expect(
        MemberInvitePolicy.fromWire('Invite'),
        equals(MemberInvitePolicy.unknown),
      );
    });

    test('unknown has no wire name', () {
      expect(MemberInvitePolicy.unknown.toWire, throwsStateError);
    });

    test('HouseholdSettings JSON agrees with the wire names', () {
      // fromWire/toWire transcribe the wire names a second time, beside the
      // @JsonValue annotations the cache's JSON uses. This ties the two.
      for (final policy in MemberInvitePolicy.values) {
        if (policy == MemberInvitePolicy.unknown) continue;
        final json = HouseholdSettings(memberInvitePolicy: policy).toJson();
        expect(json['memberInvitePolicy'], equals(policy.toWire()));
        expect(
          HouseholdSettings.fromJson(json).memberInvitePolicy,
          equals(policy),
        );
      }
    });

    test('HouseholdSettings JSON reads an unrecognised name as unknown', () {
      final settings = HouseholdSettings.fromJson(const {
        'memberInvitePolicy': 'Invite',
      });
      expect(settings.memberInvitePolicy, equals(MemberInvitePolicy.unknown));
    });
  });
}
