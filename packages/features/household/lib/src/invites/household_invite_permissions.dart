import 'package:models/domain.dart';

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

/// Who may do what with a household's invites, by the viewer's role (#455),
/// and for sending, by the household's member invite policy too (#569).
///
/// This decides which controls a screen draws. The server decides what
/// happens, and its refusal is shown when the two disagree, for instance
/// after the viewer's role or the policy changed under an open screen.
///
/// A stand-in for the role table #483 will build, which should replace it.
/// Two of its rules come from the matrix decided on
/// BoardGamesEmpire/board-games-empire-backend#168, which the server does
/// not enforce yet: an admin may not offer Admin, and may not revoke an
/// invite offering Admin. Following them here keeps an admin from doing
/// something the server is about to forbid.
///
/// A third is this helper's own reading. The matrix lets an admin approve
/// any invite awaiting approval, but approving one offering Admin would
/// make someone an admin, which the matrix leaves to the owner. So an admin
/// is not offered that approve either. A member cannot send such an invite,
/// so it should not arise.
abstract final class HouseholdInvitePermissions {
  /// Whether [role] may see the household's invites, and send new ones
  /// whatever the policy.
  static bool mayManage(HouseholdRole? role) =>
      role == HouseholdRole.householdOwner ||
      role == HouseholdRole.householdAdmin;

  /// Whether [role] may send an invite under the household's [policy].
  ///
  /// An owner or admin always may. A member may under `Direct` or
  /// `NeedsApproval`. A null [policy], read before the cache has the
  /// household's settings, is no answer, and the server refuses a member
  /// a household without settings, so it reads as "may not", as
  /// [MemberInvitePolicy.unknown] does. A guest never may.
  static bool maySend(HouseholdRole? role, MemberInvitePolicy? policy) =>
      mayManage(role) ||
      (role == HouseholdRole.householdMember &&
          (policy == MemberInvitePolicy.direct ||
              policy == MemberInvitePolicy.needsApproval));

  /// The roles a viewer with [viewer] may offer in an invite under the
  /// household's [policy], in the order a picker lists them. A member who
  /// may send offers Member or Guest, never Admin, as the server allows.
  static List<HouseholdRole> offerableRoles(
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
    HouseholdRole.householdMember when maySend(viewer, policy) => const [
      HouseholdRole.householdMember,
      HouseholdRole.householdGuest,
    ],
    _ => const [],
  };

  /// The actions [invite]'s row offers the viewer.
  ///
  /// A settled invite offers none. The viewer's own outstanding invite
  /// offers withdrawing it, whatever their role; the server refuses them a
  /// revoke of it. An owner or admin may also approve it while it awaits
  /// approval, as a member promoted since sending it. Someone else's
  /// invite offers an owner or admin revoking it, and approving it while it
  /// awaits approval. An admin is offered neither on an invite offering
  /// Admin.
  static Set<HouseholdInviteRowAction> rowActions({
    required String viewerUserId,
    required HouseholdRole? viewerRole,
    required HouseholdInvite invite,
  }) {
    if (!invite.status.isOutstanding) return const {};
    final own = invite.inviter.id == viewerUserId;
    final authority = switch (viewerRole) {
      HouseholdRole.householdOwner => true,
      HouseholdRole.householdAdmin =>
        invite.role != HouseholdRole.householdAdmin,
      _ => false,
    };
    return {
      if (authority && invite.status == HouseholdInviteStatus.awaitingApproval)
        HouseholdInviteRowAction.approve,
      if (own) HouseholdInviteRowAction.withdraw,
      if (authority && !own) HouseholdInviteRowAction.revoke,
    };
  }

  /// The actions a row of the viewer's sent list offers.
  ///
  /// Takes no role: the server binds the sent list to its sender, so every
  /// row is the viewer's own, and it lets an inviter withdraw their own
  /// outstanding invite whatever their role (#454). A settled or expired
  /// invite offers none. Approving your own invite awaiting approval stays
  /// on the household's invite list, so it is not offered here (#487).
  static Set<HouseholdInviteRowAction> sentRowActions(HouseholdInvite invite) =>
      invite.status.isOutstanding
      ? const {HouseholdInviteRowAction.withdraw}
      : const {};
}
