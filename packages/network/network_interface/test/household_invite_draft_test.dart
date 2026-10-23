import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('HouseholdInviteDraft', () {
    test('defaults to offering Member', () {
      final draft = HouseholdInviteDraft(invitee: const InviteeUser('u_2'));

      expect(draft.role, HouseholdRole.householdMember);
      expect(draft.inviteeName, isNull);
      expect(draft.message, isNull);
    });

    test('stores a name or message of only whitespace as null', () {
      final draft = HouseholdInviteDraft(
        invitee: const InviteeUser('u_2'),
        inviteeName: '   ',
        message: '\n\t ',
      );

      expect(draft.inviteeName, isNull);
      expect(draft.message, isNull);
    });

    test('trims the name and the message', () {
      final draft = HouseholdInviteDraft(
        invitee: const InviteeUser('u_2'),
        inviteeName: '  Ana ',
        message: ' Come play \n',
      );

      expect(draft.inviteeName, 'Ana');
      expect(draft.message, 'Come play');
    });

    test('trims the address', () {
      final draft = HouseholdInviteDraft(invitee: InviteeEmail('  a@b.c '));

      expect((draft.invitee as InviteeEmail).email, 'a@b.c');
    });

    test('accepts a name of exactly 100 and a message of exactly 1000', () {
      final draft = HouseholdInviteDraft(
        invitee: const InviteeUser('u_2'),
        inviteeName: 'n' * 100,
        message: 'm' * 1000,
      );

      expect(draft.inviteeName, hasLength(100));
      expect(draft.message, hasLength(1000));
    });

    test('refuses a name over 100 characters', () {
      expect(
        () => HouseholdInviteDraft(
          invitee: const InviteeUser('u_2'),
          inviteeName: 'n' * 101,
        ),
        throwsArgumentError,
      );
    });

    test('refuses a message over 1000 characters', () {
      expect(
        () => HouseholdInviteDraft(
          invitee: const InviteeUser('u_2'),
          message: 'm' * 1001,
        ),
        throwsArgumentError,
      );
    });

    test('refuses to offer Owner or a role it does not know', () {
      for (final role in [
        HouseholdRole.householdOwner,
        HouseholdRole.unknown,
      ]) {
        expect(
          () => HouseholdInviteDraft(
            invitee: const InviteeUser('u_2'),
            role: role,
          ),
          throwsArgumentError,
          reason: role.name,
        );
      }
    });

    test('offers Admin, Member or Guest', () {
      for (final role in [
        HouseholdRole.householdAdmin,
        HouseholdRole.householdMember,
        HouseholdRole.householdGuest,
      ]) {
        expect(
          HouseholdInviteDraft(
            invitee: const InviteeUser('u_2'),
            role: role,
          ).role,
          role,
        );
      }
    });

    test('refuses an empty user id or an empty address', () {
      expect(
        () => HouseholdInviteDraft(invitee: const InviteeUser('')),
        throwsArgumentError,
      );
      expect(
        () => HouseholdInviteDraft(invitee: InviteeEmail('   ')),
        throwsArgumentError,
      );
    });
  });
}
