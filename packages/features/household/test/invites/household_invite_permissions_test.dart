import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';

const _me = 'u_me';
const _other = 'u_other';

HouseholdInvite _invite({
  String inviterId = _other,
  HouseholdInviteStatus status = HouseholdInviteStatus.pending,
  HouseholdRole? role = HouseholdRole.householdMember,
}) => HouseholdInvite(
  id: 'i_1',
  status: status,
  inviter: UserSummary(id: inviterId, username: inviterId),
  role: role,
  expiresAt: DateTime.utc(2026, 10, 26),
  createdAt: DateTime.utc(2026, 10, 19),
);

Set<HouseholdInviteRowAction> _actions(
  HouseholdRole? viewer,
  HouseholdInvite invite,
) => HouseholdInvitePermissions.rowActions(
  viewerUserId: _me,
  viewerRole: viewer,
  invite: invite,
);

void main() {
  const owner = HouseholdRole.householdOwner;
  const admin = HouseholdRole.householdAdmin;
  const member = HouseholdRole.householdMember;
  const guest = HouseholdRole.householdGuest;

  group('mayManage', () {
    test('is true only for an owner or an admin', () {
      expect(HouseholdInvitePermissions.mayManage(owner), isTrue);
      expect(HouseholdInvitePermissions.mayManage(admin), isTrue);
      expect(HouseholdInvitePermissions.mayManage(member), isFalse);
      expect(HouseholdInvitePermissions.mayManage(guest), isFalse);
      expect(
        HouseholdInvitePermissions.mayManage(HouseholdRole.unknown),
        isFalse,
      );
      expect(HouseholdInvitePermissions.mayManage(null), isFalse);
    });
  });

  group('offerableRoles', () {
    test('an owner may offer Admin, Member or Guest', () {
      expect(HouseholdInvitePermissions.offerableRoles(owner), [
        admin,
        member,
        guest,
      ]);
    });

    test('an admin may offer Member or Guest, not Admin', () {
      expect(HouseholdInvitePermissions.offerableRoles(admin), [member, guest]);
    });

    test('anyone else may offer nothing', () {
      for (final role in [member, guest, HouseholdRole.unknown, null]) {
        expect(
          HouseholdInvitePermissions.offerableRoles(role),
          isEmpty,
          reason: '$role',
        );
      }
    });
  });

  group('rowActions', () {
    test('a settled invite offers nothing', () {
      for (final status in [
        HouseholdInviteStatus.accepted,
        HouseholdInviteStatus.declined,
        HouseholdInviteStatus.expired,
        HouseholdInviteStatus.revoked,
        HouseholdInviteStatus.withdrawn,
        HouseholdInviteStatus.unknown,
      ]) {
        expect(
          _actions(owner, _invite(status: status, inviterId: _me)),
          isEmpty,
          reason: status.name,
        );
      }
    });

    test('the viewer\'s own outstanding invite offers withdraw, whatever '
        'their role', () {
      for (final role in [owner, admin, member, guest, null]) {
        expect(_actions(role, _invite(inviterId: _me)), {
          HouseholdInviteRowAction.withdraw,
        }, reason: '$role');
      }
      for (final role in [member, guest, null]) {
        expect(
          _actions(
            role,
            _invite(
              inviterId: _me,
              status: HouseholdInviteStatus.awaitingApproval,
            ),
          ),
          {HouseholdInviteRowAction.withdraw},
          reason: '$role, awaiting approval',
        );
      }
    });

    test('an owner or admin may approve an invite they sent awaiting '
        'approval, as a member promoted since', () {
      for (final role in [owner, admin]) {
        expect(
          _actions(
            role,
            _invite(
              inviterId: _me,
              status: HouseholdInviteStatus.awaitingApproval,
            ),
          ),
          {HouseholdInviteRowAction.approve, HouseholdInviteRowAction.withdraw},
          reason: '$role',
        );
      }
    });

    test('an owner may revoke someone else\'s pending invite', () {
      expect(_actions(owner, _invite()), {HouseholdInviteRowAction.revoke});
    });

    test('an owner may approve or turn down an invite awaiting approval', () {
      expect(
        _actions(
          owner,
          _invite(status: HouseholdInviteStatus.awaitingApproval),
        ),
        {HouseholdInviteRowAction.approve, HouseholdInviteRowAction.revoke},
      );
    });

    test('an owner may revoke an invite offering Admin', () {
      expect(_actions(owner, _invite(role: admin)), {
        HouseholdInviteRowAction.revoke,
      });
    });

    test('an admin may revoke or approve an invite offering Member', () {
      expect(
        _actions(
          admin,
          _invite(status: HouseholdInviteStatus.awaitingApproval),
        ),
        {HouseholdInviteRowAction.approve, HouseholdInviteRowAction.revoke},
      );
    });

    test('an admin may do nothing with someone else\'s invite offering '
        'Admin', () {
      expect(_actions(admin, _invite(role: admin)), isEmpty);
      expect(
        _actions(
          admin,
          _invite(role: admin, status: HouseholdInviteStatus.awaitingApproval),
        ),
        isEmpty,
      );
    });

    test('a member or guest may do nothing with someone else\'s invite', () {
      for (final role in [member, guest, null]) {
        expect(_actions(role, _invite()), isEmpty, reason: '$role');
      }
    });
  });

  group('sentRowActions', () {
    test('an outstanding invite offers withdraw', () {
      for (final status in [
        HouseholdInviteStatus.pending,
        HouseholdInviteStatus.awaitingApproval,
      ]) {
        expect(
          HouseholdInvitePermissions.sentRowActions(_invite(status: status)),
          {HouseholdInviteRowAction.withdraw},
          reason: '$status',
        );
      }
    });

    test('a settled or expired invite offers nothing', () {
      for (final status in [
        HouseholdInviteStatus.expired,
        HouseholdInviteStatus.accepted,
        HouseholdInviteStatus.declined,
        HouseholdInviteStatus.withdrawn,
        HouseholdInviteStatus.revoked,
        HouseholdInviteStatus.unknown,
      ]) {
        expect(
          HouseholdInvitePermissions.sentRowActions(_invite(status: status)),
          isEmpty,
          reason: '$status',
        );
      }
    });
  });
}
