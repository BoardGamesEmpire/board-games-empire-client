import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

const _me = 'u_me';
const _other = 'u_other';

Household _household({bool isLocalOnly = false, MemberInvitePolicy? policy}) =>
    Household(
      id: 'hh_1',
      name: 'Den',
      settings: policy == null
          ? null
          : HouseholdSettings(memberInvitePolicy: policy),
      isDirty: isLocalOnly,
      isLocalOnly: isLocalOnly,
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: DateTime.utc(2026, 10, 1),
    );

HouseholdMember _target(HouseholdRole? role) => HouseholdMember(
  id: 'm_target',
  userId: 'u_target',
  householdId: 'hh_1',
  role: role,
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
);

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

Set<HouseholdInviteRowAction> _rowActions(
  HouseholdRole? viewer,
  HouseholdInvite invite,
) => householdInviteRowActions(
  viewerUserId: _me,
  viewerRole: viewer,
  invite: invite,
);

Set<HouseholdMemberAction> _onTarget(
  HouseholdRole? viewer,
  HouseholdRole? target, {
  bool isSelf = false,
}) => householdMemberActionsFor(
  viewerRole: viewer,
  isSelf: isSelf,
  target: _target(target),
);

/// The role table (#483): what each role may do in a household and to another
/// member, asserted set by set. The expectations are written out here rather
/// than derived from the implementation, so the table can't drift without a
/// test saying so.
void main() {
  const owner = HouseholdRole.householdOwner;
  const admin = HouseholdRole.householdAdmin;
  const member = HouseholdRole.householdMember;
  const guest = HouseholdRole.householdGuest;

  // Every role the client can read, then no role at all.
  const roles = <HouseholdRole?>[null, ...HouseholdRole.values];
  const policies = <MemberInvitePolicy?>[null, ...MemberInvitePolicy.values];

  group('householdRoleActions', () {
    /// Each role's row, under a policy that lets a member send. A role missing
    /// from here fails the test below, so adding one to [HouseholdRole] means
    /// deciding what it may do.
    const byRole = <HouseholdRole, Set<HouseholdAction>>{
      owner: {
        HouseholdAction.edit,
        HouseholdAction.delete,
        HouseholdAction.leave,
        HouseholdAction.manageInvites,
        HouseholdAction.sendInvite,
      },
      admin: {
        HouseholdAction.edit,
        HouseholdAction.leave,
        HouseholdAction.manageInvites,
        HouseholdAction.sendInvite,
      },
      member: {HouseholdAction.leave, HouseholdAction.sendInvite},
      guest: {HouseholdAction.leave},
      HouseholdRole.unknown: {},
    };

    test('every role has a row in the table', () {
      expect(byRole.keys, unorderedEquals(HouseholdRole.values));
    });

    test('each role gets its row of the table', () {
      for (final role in HouseholdRole.values) {
        expect(
          householdRoleActions(role, policy: MemberInvitePolicy.direct),
          byRole[role],
          reason: role.name,
        );
      }
    });

    test('no role gets nothing', () {
      for (final policy in policies) {
        expect(householdRoleActions(null, policy: policy), isEmpty);
      }
    });

    test('an owner or admin is dealt the same whatever the policy', () {
      for (final role in [owner, admin]) {
        for (final policy in policies) {
          expect(
            householdRoleActions(role, policy: policy),
            byRole[role],
            reason: '$role, $policy',
          );
        }
      }
    });

    test('a member sends only under Direct or NeedsApproval', () {
      const canSend = {HouseholdAction.leave, HouseholdAction.sendInvite};
      const cannotSend = {HouseholdAction.leave};

      expect(
        householdRoleActions(member, policy: MemberInvitePolicy.direct),
        canSend,
      );
      expect(
        householdRoleActions(member, policy: MemberInvitePolicy.needsApproval),
        canSend,
      );
      expect(
        householdRoleActions(member, policy: MemberInvitePolicy.off),
        cannotSend,
      );
      expect(
        householdRoleActions(member, policy: MemberInvitePolicy.unknown),
        cannotSend,
      );
      // The policy is unread: the cache has no settings for the household yet.
      expect(householdRoleActions(member), cannotSend);
    });

    test('a guest or an unknown role never sends', () {
      for (final role in [guest, HouseholdRole.unknown, null]) {
        for (final policy in policies) {
          expect(
            householdRoleActions(role, policy: policy),
            isNot(contains(HouseholdAction.sendInvite)),
            reason: '$role, $policy',
          );
        }
      }
    });

    test('manageInvites is for an owner or an admin alone', () {
      for (final role in roles) {
        expect(
          householdRoleActions(role, policy: MemberInvitePolicy.direct),
          role == owner || role == admin
              ? contains(HouseholdAction.manageInvites)
              : isNot(contains(HouseholdAction.manageInvites)),
          reason: '$role',
        );
      }
    });

    test('edit is for an owner or an admin alone', () {
      for (final role in roles) {
        expect(
          householdRoleActions(role),
          role == owner || role == admin
              ? contains(HouseholdAction.edit)
              : isNot(contains(HouseholdAction.edit)),
          reason: '$role',
        );
      }
    });

    test('is the owner alone who may delete', () {
      final who = [
        for (final role in HouseholdRole.values)
          if (householdRoleActions(role).contains(HouseholdAction.delete)) role,
      ];

      expect(who, [owner]);
    });

    test('answers a set nothing can change', () {
      // A screen state compares by it, so it must not change under one.
      for (final role in roles) {
        for (final policy in policies) {
          final actions = householdRoleActions(role, policy: policy);

          expect(
            () => actions.add(HouseholdAction.delete),
            throwsUnsupportedError,
            reason: '$role, $policy',
          );
        }
      }
    });
  });

  group('householdActionsFor', () {
    test('answers the role\'s row under the household\'s own policy', () {
      for (final role in roles) {
        for (final policy in policies) {
          expect(
            householdActionsFor(_household(policy: policy), role),
            householdRoleActions(role, policy: policy),
            reason: '$role, $policy',
          );
        }
      }
    });

    test('a member sends under the policy the settings hold', () {
      expect(
        householdActionsFor(
          _household(policy: MemberInvitePolicy.direct),
          member,
        ),
        contains(HouseholdAction.sendInvite),
      );
      expect(
        householdActionsFor(_household(policy: MemberInvitePolicy.off), member),
        isNot(contains(HouseholdAction.sendInvite)),
      );
    });

    test('a member is not offered sending before the cache has settings', () {
      expect(
        householdActionsFor(_household(), member),
        isNot(contains(HouseholdAction.sendInvite)),
      );
    });

    test('owners and admins may edit', () {
      expect(
        householdActionsFor(_household(), owner),
        contains(HouseholdAction.edit),
      );
      expect(
        householdActionsFor(_household(), admin),
        contains(HouseholdAction.edit),
      );
    });

    test('members, guests, unknown and no role may not edit', () {
      for (final role in [member, guest, HouseholdRole.unknown, null]) {
        expect(
          householdActionsFor(_household(), role),
          isNot(contains(HouseholdAction.edit)),
          reason: '$role',
        );
      }
    });

    test('a household the server has not confirmed offers nothing', () {
      // Its edit would name an id the server never issued (#476).
      expect(
        householdActionsFor(_household(isLocalOnly: true), owner),
        isEmpty,
      );
      for (final role in roles) {
        expect(
          householdActionsFor(
            _household(isLocalOnly: true, policy: MemberInvitePolicy.direct),
            role,
          ),
          isEmpty,
          reason: '$role',
        );
      }
    });

    test('answers a set nothing can change', () {
      final confirmed = householdActionsFor(_household(), owner);
      final unconfirmed = householdActionsFor(
        _household(isLocalOnly: true),
        owner,
      );

      expect(() => confirmed.add(HouseholdAction.edit), throwsUnsupportedError);
      expect(
        () => unconfirmed.add(HouseholdAction.edit),
        throwsUnsupportedError,
      );
    });
  });

  group('offerableInviteRoles', () {
    test('an owner may offer Admin, Member or Guest', () {
      expect(offerableInviteRoles(owner, MemberInvitePolicy.off), [
        admin,
        member,
        guest,
      ]);
    });

    test('an admin may offer Member or Guest, not Admin', () {
      expect(offerableInviteRoles(admin, MemberInvitePolicy.off), [
        member,
        guest,
      ]);
    });

    test('a member who may send may offer Member or Guest', () {
      for (final policy in [
        MemberInvitePolicy.direct,
        MemberInvitePolicy.needsApproval,
      ]) {
        expect(offerableInviteRoles(member, policy), [
          member,
          guest,
        ], reason: '$policy');
      }
    });

    test('a member under Off offers nothing', () {
      expect(offerableInviteRoles(member, MemberInvitePolicy.off), isEmpty);
    });

    test('a member under an unknown or missing policy offers nothing', () {
      expect(offerableInviteRoles(member, MemberInvitePolicy.unknown), isEmpty);
      expect(offerableInviteRoles(member, null), isEmpty);
    });

    test('anyone else may offer nothing', () {
      for (final role in [guest, HouseholdRole.unknown, null]) {
        expect(
          offerableInviteRoles(role, MemberInvitePolicy.direct),
          isEmpty,
          reason: '$role',
        );
      }
    });

    test('answers a list nothing can change', () {
      for (final role in roles) {
        final offered = offerableInviteRoles(role, MemberInvitePolicy.direct);

        expect(() => offered.add(admin), throwsUnsupportedError);
      }
    });

    // The picker and the invite draft each list the roles. If they drift,
    // the picker offers a role the draft refuses.
    test('offers only roles an invite draft accepts', () {
      for (final role in roles) {
        for (final policy in policies) {
          expect(
            HouseholdInviteDraft.offerableRoles,
            containsAll(offerableInviteRoles(role, policy)),
            reason: '$role, $policy',
          );
        }
      }
    });
  });

  group('householdInviteRowActions', () {
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
          _rowActions(owner, _invite(status: status, inviterId: _me)),
          isEmpty,
          reason: status.name,
        );
      }
    });

    test('the viewer\'s own outstanding invite offers withdraw, whatever '
        'their role', () {
      for (final role in [owner, admin, member, guest, null]) {
        expect(_rowActions(role, _invite(inviterId: _me)), {
          HouseholdInviteRowAction.withdraw,
        }, reason: '$role');
      }
      for (final role in [member, guest, null]) {
        expect(
          _rowActions(
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
          _rowActions(
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
      expect(_rowActions(owner, _invite()), {HouseholdInviteRowAction.revoke});
    });

    test('an owner may approve or turn down an invite awaiting approval', () {
      expect(
        _rowActions(
          owner,
          _invite(status: HouseholdInviteStatus.awaitingApproval),
        ),
        {HouseholdInviteRowAction.approve, HouseholdInviteRowAction.revoke},
      );
    });

    test('an owner may revoke an invite offering Admin', () {
      expect(_rowActions(owner, _invite(role: admin)), {
        HouseholdInviteRowAction.revoke,
      });
    });

    test('an admin may revoke or approve an invite offering Member', () {
      expect(
        _rowActions(
          admin,
          _invite(status: HouseholdInviteStatus.awaitingApproval),
        ),
        {HouseholdInviteRowAction.approve, HouseholdInviteRowAction.revoke},
      );
    });

    test('an admin may do nothing with someone else\'s invite offering '
        'Admin', () {
      expect(_rowActions(admin, _invite(role: admin)), isEmpty);
      expect(
        _rowActions(
          admin,
          _invite(role: admin, status: HouseholdInviteStatus.awaitingApproval),
        ),
        isEmpty,
      );
    });

    test('a member or guest may do nothing with someone else\'s invite', () {
      for (final role in [member, guest, null]) {
        expect(_rowActions(role, _invite()), isEmpty, reason: '$role');
      }
    });

    test('answers a set nothing can change', () {
      final some = _rowActions(owner, _invite());
      final none = _rowActions(
        owner,
        _invite(status: HouseholdInviteStatus.accepted),
      );

      expect(
        () => some.add(HouseholdInviteRowAction.approve),
        throwsUnsupportedError,
      );
      expect(
        () => none.add(HouseholdInviteRowAction.approve),
        throwsUnsupportedError,
      );
    });
  });

  group('sentInviteRowActions', () {
    test('an outstanding invite offers withdraw', () {
      for (final status in [
        HouseholdInviteStatus.pending,
        HouseholdInviteStatus.awaitingApproval,
      ]) {
        expect(sentInviteRowActions(_invite(status: status)), {
          HouseholdInviteRowAction.withdraw,
        }, reason: '$status');
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
          sentInviteRowActions(_invite(status: status)),
          isEmpty,
          reason: '$status',
        );
      }
    });

    test('answers a set nothing can change', () {
      final some = sentInviteRowActions(_invite());
      final none = sentInviteRowActions(
        _invite(status: HouseholdInviteStatus.accepted),
      );

      expect(
        () => some.add(HouseholdInviteRowAction.approve),
        throwsUnsupportedError,
      );
      expect(
        () => none.add(HouseholdInviteRowAction.approve),
        throwsUnsupportedError,
      );
    });
  });

  group('householdMemberActionsFor', () {
    test('an owner acts on everyone but themself', () {
      const onAnyoneElse = {
        HouseholdMemberAction.changeRole,
        HouseholdMemberAction.remove,
        HouseholdMemberAction.makeOwner,
      };

      for (final target in [
        admin,
        member,
        guest,
        HouseholdRole.unknown,
        null,
      ]) {
        expect(_onTarget(owner, target), onAnyoneElse, reason: '$target');
      }
      // Another owner's role changes only through transfer, so they are
      // removed and nothing else.
      expect(_onTarget(owner, owner), {HouseholdMemberAction.remove});
      expect(_onTarget(owner, owner, isSelf: true), isEmpty);
      for (final target in roles) {
        expect(
          _onTarget(owner, target, isSelf: true),
          isEmpty,
          reason: 'self, $target',
        );
      }
    });

    test('an admin acts only on members and guests', () {
      const onMemberOrGuest = {
        HouseholdMemberAction.changeRole,
        HouseholdMemberAction.remove,
      };

      expect(_onTarget(admin, member), onMemberOrGuest);
      expect(_onTarget(admin, guest), onMemberOrGuest);
      for (final target in [admin, owner, HouseholdRole.unknown, null]) {
        expect(_onTarget(admin, target), isEmpty, reason: '$target');
      }
      for (final target in roles) {
        expect(
          _onTarget(admin, target, isSelf: true),
          isEmpty,
          reason: 'self, $target',
        );
      }
    });

    test('members, guests and unknown roles act on no one', () {
      for (final viewer in [member, guest, HouseholdRole.unknown, null]) {
        for (final target in roles) {
          expect(
            _onTarget(viewer, target),
            isEmpty,
            reason: '$viewer on $target',
          );
          expect(
            _onTarget(viewer, target, isSelf: true),
            isEmpty,
            reason: '$viewer on themself as $target',
          );
        }
      }
    });

    test('is the owner alone who may make someone owner', () {
      final who = [
        for (final viewer in HouseholdRole.values)
          if (roles.any(
            (target) => _onTarget(
              viewer,
              target,
            ).contains(HouseholdMemberAction.makeOwner),
          ))
            viewer,
      ];

      expect(who, [owner]);
    });

    test('answers a set nothing can change', () {
      final some = _onTarget(owner, member);
      final none = _onTarget(member, member);

      expect(
        () => some.add(HouseholdMemberAction.makeOwner),
        throwsUnsupportedError,
      );
      expect(
        () => none.add(HouseholdMemberAction.makeOwner),
        throwsUnsupportedError,
      );
    });
  });

  group('assignableMemberRoles', () {
    test('an owner may assign Admin, Member or Guest', () {
      expect(assignableMemberRoles(owner), [admin, member, guest]);
    });

    test('an admin may assign Member or Guest, not Admin', () {
      expect(assignableMemberRoles(admin), [member, guest]);
    });

    test('anyone else may assign nothing', () {
      for (final role in [member, guest, HouseholdRole.unknown, null]) {
        expect(assignableMemberRoles(role), isEmpty, reason: '$role');
      }
    });

    test('never offers Owner, which only a transfer grants', () {
      for (final role in roles) {
        expect(assignableMemberRoles(role), isNot(contains(owner)));
      }
    });

    test('answers a list nothing can change', () {
      for (final role in roles) {
        expect(
          () => assignableMemberRoles(role).add(admin),
          throwsUnsupportedError,
        );
      }
    });

    // The picker and the member client each list the roles. If they drift,
    // the picker offers a role the client refuses.
    test('offers only roles the member client accepts', () {
      for (final role in roles) {
        expect(
          HouseholdMemberRemoteDataSource.assignableRoles,
          containsAll(assignableMemberRoles(role)),
          reason: '$role',
        );
      }
    });
  });
}
