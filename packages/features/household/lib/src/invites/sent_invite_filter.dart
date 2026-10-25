import 'package:models/domain.dart';

/// Which of the viewer's sent invites the sent list asks the server for
/// (#487), in the order the filter menu lists them.
enum SentInviteFilter {
  /// Invites still waiting, and those that ran out. What the server lists
  /// when no status is asked for.
  openAndExpired,

  /// Sent and waiting on the invitee.
  pending,

  /// Waiting on an owner or admin to approve it.
  awaitingApproval,

  /// Ran out before the invitee answered.
  expired,

  /// Taken up by the invitee.
  accepted,

  /// Turned down by the invitee.
  declined,

  /// Taken back by the viewer.
  withdrawn,

  /// Cancelled: by an owner or admin, or by the server when the household's
  /// invite policy no longer allowed it.
  revoked;

  /// The status to send the server, or null to leave it out, which lists
  /// [openAndExpired].
  HouseholdInviteStatus? get status => switch (this) {
    openAndExpired => null,
    pending => HouseholdInviteStatus.pending,
    awaitingApproval => HouseholdInviteStatus.awaitingApproval,
    expired => HouseholdInviteStatus.expired,
    accepted => HouseholdInviteStatus.accepted,
    declined => HouseholdInviteStatus.declined,
    withdrawn => HouseholdInviteStatus.withdrawn,
    revoked => HouseholdInviteStatus.revoked,
  };

  /// Whether [invite] still belongs under this filter.
  ///
  /// This judges only a row the client itself just changed, such as the
  /// answer to a withdraw, which may have moved out from under the filter.
  /// It never decides what a page shows: the server already filtered every
  /// row it sent, so nothing should run this over a page.
  bool admits(HouseholdInvite invite) {
    final status = this.status;
    if (status != null) return invite.status == status;
    return invite.status.isOutstanding ||
        invite.status == HouseholdInviteStatus.expired;
  }
}
