/// How many votes a nomination needs before its result counts.
///
/// Mirrors the backend's `VoteQuorumType` enum
/// (`prisma/models/event/event-game-vote.prisma` in
/// `board-games-empire-backend`). `EventPolicy.voteQuorumValue` carries the
/// number [percentOfAttendees] and [fixedCount] need.
enum VoteQuorumType {
  /// No minimum: any number of votes counts.
  none,

  /// A set percentage of the eligible voters must vote.
  percentOfAttendees,

  /// A set number of votes must be cast.
  fixedCount,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static VoteQuorumType fromWire(String name) => switch (name) {
    'None' => VoteQuorumType.none,
    'PercentOfAttendees' => VoteQuorumType.percentOfAttendees,
    'FixedCount' => VoteQuorumType.fixedCount,
    _ => VoteQuorumType.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    VoteQuorumType.none => 'None',
    VoteQuorumType.percentOfAttendees => 'PercentOfAttendees',
    VoteQuorumType.fixedCount => 'FixedCount',
    VoteQuorumType.unknown => throw StateError(
      'VoteQuorumType.unknown has no wire name',
    ),
  };
}
