/// Where a household invite stands (#455).
///
/// Mirrors the server's `InviteStatus` enum. An invite from a sender who
/// may not add members directly starts at [awaitingApproval] and becomes
/// [pending] once an owner or admin approves it; only a [pending] invite
/// can be accepted.
///
/// See: `prisma/models/household/household-invite.prisma` in
/// `board-games-empire-backend`.
enum HouseholdInviteStatus {
  pending,
  awaitingApproval,
  accepted,
  declined,
  expired,
  revoked,
  withdrawn,

  /// A status this client does not know. Never sent back to the server.
  unknown;

  /// Resolves a server status name, degrading to [unknown] for a name this
  /// client does not know — the same rule as `HouseholdRole.fromWire`, so a
  /// status added server-side shows as a settled row rather than failing
  /// the whole page.
  static HouseholdInviteStatus fromWire(String name) => switch (name) {
    'Pending' => HouseholdInviteStatus.pending,
    'AwaitingApproval' => HouseholdInviteStatus.awaitingApproval,
    'Accepted' => HouseholdInviteStatus.accepted,
    'Declined' => HouseholdInviteStatus.declined,
    'Expired' => HouseholdInviteStatus.expired,
    'Revoked' => HouseholdInviteStatus.revoked,
    'Withdrawn' => HouseholdInviteStatus.withdrawn,
    _ => HouseholdInviteStatus.unknown,
  };

  /// The server's name for this status, for a list filter.
  ///
  /// Throws [StateError] for [unknown]: there is no name to send.
  String toWire() => switch (this) {
    HouseholdInviteStatus.pending => 'Pending',
    HouseholdInviteStatus.awaitingApproval => 'AwaitingApproval',
    HouseholdInviteStatus.accepted => 'Accepted',
    HouseholdInviteStatus.declined => 'Declined',
    HouseholdInviteStatus.expired => 'Expired',
    HouseholdInviteStatus.revoked => 'Revoked',
    HouseholdInviteStatus.withdrawn => 'Withdrawn',
    HouseholdInviteStatus.unknown => throw StateError(
      'HouseholdInviteStatus.unknown has no wire name',
    ),
  };

  /// Still waiting on someone: the invitee, or an approver. Only these can
  /// be withdrawn, revoked or answered.
  bool get isOutstanding =>
      this == HouseholdInviteStatus.pending ||
      this == HouseholdInviteStatus.awaitingApproval;
}
