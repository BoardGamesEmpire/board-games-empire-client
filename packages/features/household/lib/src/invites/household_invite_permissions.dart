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

/// Who may do what with a household's invites, by the viewer's role (#455).
///
/// This decides which controls a screen draws. The server decides what
/// happens, and its refusal is shown when the two disagree, for instance
/// after the viewer's role changed under an open screen.
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
  /// Whether [role] may see the household's invites and send new ones.
  static bool mayManage(HouseholdRole? role) =>
      role == HouseholdRole.householdOwner ||
      role == HouseholdRole.householdAdmin;

  /// The roles a viewer with [viewer] may offer in an invite, in the order a
  /// picker lists them.
  static List<HouseholdRole> offerableRoles(HouseholdRole? viewer) =>
      switch (viewer) {
        HouseholdRole.householdOwner => const [
          HouseholdRole.householdAdmin,
          HouseholdRole.householdMember,
          HouseholdRole.householdGuest,
        ],
        HouseholdRole.householdAdmin => const [
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
}
