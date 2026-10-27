/// What a viewer may do in a household, and to another member of it, by their
/// role (#483).
///
/// One table behind every control the household screens offer. The issues that
/// add those controls (#476, #477, #479, #455 and #569 for the household,
/// #480 and #478 for its members) read it rather than each deciding who sees
/// a button, so a role's rights are written down once.
///
/// The table follows the backend README's role table
/// (BoardGamesEmpire/board-games-empire-backend#168), whose columns are the
/// roles and whose rows are the actions. Each set below names the column it
/// comes from and, where it helps, the rows it reads down that column.
///
/// The server stays the authority and answers 403. The table only decides what
/// the client offers, and a role that changed under an open screen shows the
/// server's refusal.
///
/// A role is read by its name. That holds until
/// BoardGamesEmpire/board-games-empire-backend#844 and
/// BoardGamesEmpire/board-games-empire-backend#845 add role variants (#483's
/// 2026-10-22 amendment), after which a name alone may not say what a role may
/// do.
library;

import 'package:models/domain.dart';

/// What a viewer may do in a household, one per action a screen offers.
enum HouseholdAction {
  /// Change the household's name, description and settings (#476).
  edit,

  /// Delete the household (#477).
  delete,

  /// Leave the household (#479).
  leave,

  /// See the household's invites, and cancel or approve them (#455).
  manageInvites,

  /// Send an invite, under the household's member invite policy (#569).
  sendInvite,
}

/// What a viewer may do to another member of a household, one per action a
/// member's row offers.
enum HouseholdMemberAction {
  /// Give the member another role (#480). Never to an owner, whose role
  /// changes only through a transfer (#478).
  changeRole,

  /// Take the member out of the household (#480).
  remove,

  /// Hand the household to the member (#478). Only the owner may.
  makeOwner,
}

/// The actions a viewer holding [role] has in a household with member invite
/// [policy], as an unmodifiable set: a state compares by it, so nothing may
/// change it after.
///
/// For a screen that holds a role and a policy but no [Household]. One that
/// holds the household reads [householdActionsFor].
///
/// [policy] decides only whether a member may send an invite. An owner or
/// admin always may, and a guest never. A null [policy], read before the cache
/// has the household's settings, is no answer, and the server refuses a
/// member a household without settings, so it reads as "may not", as
/// [MemberInvitePolicy.unknown] does.
///
/// A null or unknown role gives nothing.
Set<HouseholdAction> householdRoleActions(
  HouseholdRole? role, {
  MemberInvitePolicy? policy,
}) => switch (role) {
  HouseholdRole.householdOwner => _owner,
  HouseholdRole.householdAdmin => _admin,
  HouseholdRole.householdMember => switch (policy) {
    MemberInvitePolicy.direct ||
    MemberInvitePolicy.needsApproval => _memberWhoMaySend,
    MemberInvitePolicy.off || MemberInvitePolicy.unknown || null => _member,
  },
  HouseholdRole.householdGuest => _guest,
  HouseholdRole.unknown || null => const <HouseholdAction>{},
};

/// The actions a viewer holding [role] has in [household], as an unmodifiable
/// set, under the member invite policy its settings hold.
///
/// Nothing while [Household.isLocalOnly]: the server has not confirmed the
/// household yet, so an action would name an id it never issued (#476).
Set<HouseholdAction> householdActionsFor(
  Household household,
  HouseholdRole? role,
) {
  if (household.isLocalOnly) return const {};

  return householdRoleActions(
    role,
    policy: household.settings?.memberInvitePolicy,
  );
}

// The sets below are the README's role columns, one per role, read down the
// rows that match a [HouseholdAction]: editing and deleting the household,
// leaving it, listing its invites, and inviting. The test asserts each one in
// full.

/// The Owner column: every household action.
const _owner = <HouseholdAction>{
  HouseholdAction.edit,
  HouseholdAction.delete,
  HouseholdAction.leave,
  HouseholdAction.manageInvites,
  HouseholdAction.sendInvite,
};

/// The Admin column: every household action but `delete`, which is the owner's
/// alone.
const _admin = <HouseholdAction>{
  HouseholdAction.edit,
  HouseholdAction.leave,
  HouseholdAction.manageInvites,
  HouseholdAction.sendInvite,
};

/// The Member column where the household's policy keeps members from sending
/// (the invite rows under `Off`): they leave and nothing else.
const _member = <HouseholdAction>{HouseholdAction.leave};

/// The Member column under `Direct` or `NeedsApproval`: they leave and send
/// invites. Under `NeedsApproval` an owner or admin approves each one first,
/// which is the invite row's business and not this table's.
const _memberWhoMaySend = <HouseholdAction>{
  HouseholdAction.leave,
  HouseholdAction.sendInvite,
};

/// The Guest column: they leave and nothing else, whatever the policy.
const _guest = <HouseholdAction>{HouseholdAction.leave};

/// The actions [viewerRole] has on [target], as an unmodifiable set.
///
/// [isSelf] says [target] is the viewer's own membership. It gives nothing:
/// nobody changes their own role or removes themself, and leaving is
/// [HouseholdAction.leave].
///
/// An owner acts on every other member. Another owner is removed and nothing
/// else, because an owner's role changes only through a transfer, and a
/// household owner may remove another owner where an admin may not. A target
/// whose role is null or unknown, one this client cannot read, is acted on as
/// any member who is not an owner; the server decides what it is.
///
/// An admin acts only on members and guests. A target the client cannot read
/// is not known to rank below Admin, so an admin gets nothing on it.
///
/// A member, a guest, and a viewer whose role is null or unknown act on no
/// one.
Set<HouseholdMemberAction> householdMemberActionsFor({
  required HouseholdRole? viewerRole,
  required bool isSelf,
  required HouseholdMember target,
}) {
  if (isSelf) return const {};

  return switch (viewerRole) {
    HouseholdRole.householdOwner =>
      target.role == HouseholdRole.householdOwner
          ? _onOwner
          : _onAnyoneButOwner,
    HouseholdRole.householdAdmin => switch (target.role) {
      HouseholdRole.householdMember ||
      HouseholdRole.householdGuest => _onMemberOrGuest,
      HouseholdRole.householdOwner ||
      HouseholdRole.householdAdmin ||
      HouseholdRole.unknown ||
      null => const <HouseholdMemberAction>{},
    },
    HouseholdRole.householdMember ||
    HouseholdRole.householdGuest ||
    HouseholdRole.unknown ||
    null => const <HouseholdMemberAction>{},
  };
}

/// The roles a viewer holding [viewerRole] may give a member, in the order a
/// picker lists them, and none for anyone who may not change a role.
///
/// Never Owner: an owner is made only by a transfer (#478). These are the
/// three roles the change-role route accepts (#480).
List<HouseholdRole> assignableMemberRoles(HouseholdRole? viewerRole) =>
    switch (viewerRole) {
      HouseholdRole.householdOwner => const [
        HouseholdRole.householdAdmin,
        HouseholdRole.householdMember,
        HouseholdRole.householdGuest,
      ],
      HouseholdRole.householdAdmin => const [
        HouseholdRole.householdMember,
        HouseholdRole.householdGuest,
      ],
      HouseholdRole.householdMember ||
      HouseholdRole.householdGuest ||
      HouseholdRole.unknown ||
      null => const [],
    };

// What each viewer may do to another member, read down the README's role
// columns at its rows on changing someone's household role, removing someone
// and transferring ownership.

/// The Owner column, on an owner: remove them ("Remove another household
/// owner"), and nothing else.
const _onOwner = <HouseholdMemberAction>{HouseholdMemberAction.remove};

/// The Owner column, on any other target: change their role, remove them, or
/// make them owner ("Transfer ownership").
const _onAnyoneButOwner = <HouseholdMemberAction>{
  HouseholdMemberAction.changeRole,
  HouseholdMemberAction.remove,
  HouseholdMemberAction.makeOwner,
};

/// The Admin column, on a member or guest: change their role or remove them
/// ("Change the household role of someone with the member or guest role",
/// "Remove someone with the member or guest role"). An admin makes no one
/// owner.
const _onMemberOrGuest = <HouseholdMemberAction>{
  HouseholdMemberAction.changeRole,
  HouseholdMemberAction.remove,
};

/// What one row of a household's invite list lets the viewer do.
enum HouseholdInviteRowAction {
  /// Take back an invite the viewer sent.
  withdraw,

  /// Cancel someone else's invite, as an owner or admin. On an invite
  /// awaiting approval this is turning it down.
  revoke,

  /// Let an invite awaiting approval go to its invitee.
  approve,
}

/// The roles a viewer with [viewer] may offer in an invite under the
/// household's [policy], in the order a picker lists them. A member who
/// may send offers Member or Guest, never Admin, as the server allows.
///
/// An admin is not offered Admin either, by the matrix described on
/// [householdInviteRowActions].
List<HouseholdRole> offerableInviteRoles(
  HouseholdRole? viewer,
  MemberInvitePolicy? policy,
) => switch (viewer) {
  HouseholdRole.householdOwner => const [
    HouseholdRole.householdAdmin,
    HouseholdRole.householdMember,
    HouseholdRole.householdGuest,
  ],
  HouseholdRole.householdAdmin => const [
    HouseholdRole.householdMember,
    HouseholdRole.householdGuest,
  ],
  HouseholdRole.householdMember
      when householdRoleActions(
        viewer,
        policy: policy,
      ).contains(HouseholdAction.sendInvite) =>
    const [HouseholdRole.householdMember, HouseholdRole.householdGuest],
  _ => const [],
};

/// The actions [invite]'s row offers the viewer, as an unmodifiable set.
///
/// This decides which controls a screen draws. The server decides what
/// happens, and its refusal is shown when the two disagree, for instance
/// after the viewer's role or the policy changed under an open screen.
///
/// Two of its rules come from the matrix decided on
/// BoardGamesEmpire/board-games-empire-backend#168, which the server
/// enforces: an admin may not offer Admin, and may not revoke an invite
/// offering Admin. Following them here keeps an admin from being offered
/// what the server would refuse.
///
/// A third is this helper's own reading. The matrix lets an admin approve
/// any invite awaiting approval, but approving one offering Admin would
/// make someone an admin, which the matrix leaves to the owner. So an admin
/// is not offered that approve either. A member cannot send such an invite,
/// so it should not arise.
///
/// A settled invite offers none. The viewer's own outstanding invite
/// offers withdrawing it, whatever their role; the server refuses them a
/// revoke of it. An owner or admin may also approve it while it awaits
/// approval, as a member promoted since sending it. Someone else's
/// invite offers an owner or admin revoking it, and approving it while it
/// awaits approval. An admin is offered neither on an invite offering
/// Admin.
Set<HouseholdInviteRowAction> householdInviteRowActions({
  required String viewerUserId,
  required HouseholdRole? viewerRole,
  required HouseholdInvite invite,
}) {
  if (!invite.status.isOutstanding) return const {};
  final own = invite.inviter.id == viewerUserId;
  final authority = switch (viewerRole) {
    HouseholdRole.householdOwner => true,
    HouseholdRole.householdAdmin => invite.role != HouseholdRole.householdAdmin,
    _ => false,
  };
  return Set.unmodifiable({
    if (authority && invite.status == HouseholdInviteStatus.awaitingApproval)
      HouseholdInviteRowAction.approve,
    if (own) HouseholdInviteRowAction.withdraw,
    if (authority && !own) HouseholdInviteRowAction.revoke,
  });
}

/// The actions a row of the viewer's sent list offers.
///
/// Takes no role: the server binds the sent list to its sender, so every
/// row is the viewer's own, and it lets an inviter withdraw their own
/// outstanding invite whatever their role (#454). A settled or expired
/// invite offers none. Approving your own invite awaiting approval stays
/// on the household's invite list, so it is not offered here (#487).
Set<HouseholdInviteRowAction> sentInviteRowActions(HouseholdInvite invite) =>
    invite.status.isOutstanding
    ? const {HouseholdInviteRowAction.withdraw}
    : const {};
