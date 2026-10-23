/// Which attendees may vote on a nominated game.
///
/// Mirrors the backend's `VoteEligibility` enum
/// (`prisma/models/event/event-game-vote.prisma` in
/// `board-games-empire-backend`). Under every rule, an attendee who has been
/// removed from the event or is not attending does not count.
enum VoteEligibility {
  /// Every attendee still in the event.
  allAttendees,

  /// Only those who are attending.
  confirmedOnly,

  /// Only attendees who have added games to their list.
  poolParticipants,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static VoteEligibility fromWire(String name) => switch (name) {
    'AllAttendees' => VoteEligibility.allAttendees,
    'ConfirmedOnly' => VoteEligibility.confirmedOnly,
    'PoolParticipants' => VoteEligibility.poolParticipants,
    _ => VoteEligibility.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    VoteEligibility.allAttendees => 'AllAttendees',
    VoteEligibility.confirmedOnly => 'ConfirmedOnly',
    VoteEligibility.poolParticipants => 'PoolParticipants',
    VoteEligibility.unknown => throw StateError(
      'VoteEligibility.unknown has no wire name',
    ),
  };
}
