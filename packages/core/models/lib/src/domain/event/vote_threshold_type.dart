/// How many votes in favour a nominated game needs to join the lineup.
///
/// Mirrors the backend's `VoteThresholdType` enum
/// (`prisma/models/event/event-game-vote.prisma` in
/// `board-games-empire-backend`). Only meaningful when the event's
/// `GameAdditionMode` is `requiresVote`; `EventPolicy.voteThresholdValue`
/// carries the number [supermajority] and [fixedCount] need.
enum VoteThresholdType {
  /// More than half of the votes cast are in favour.
  simpleMajority,

  /// A set percentage of the votes cast are in favour, such as 66 or 75.
  supermajority,

  /// Every eligible voter is in favour.
  unanimous,

  /// A set number of votes in favour, whatever the size of the pool.
  fixedCount,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static VoteThresholdType fromWire(String name) => switch (name) {
    'SimpleMajority' => VoteThresholdType.simpleMajority,
    'Supermajority' => VoteThresholdType.supermajority,
    'Unanimous' => VoteThresholdType.unanimous,
    'FixedCount' => VoteThresholdType.fixedCount,
    _ => VoteThresholdType.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    VoteThresholdType.simpleMajority => 'SimpleMajority',
    VoteThresholdType.supermajority => 'Supermajority',
    VoteThresholdType.unanimous => 'Unanimous',
    VoteThresholdType.fixedCount => 'FixedCount',
    VoteThresholdType.unknown => throw StateError(
      'VoteThresholdType.unknown has no wire name',
    ),
  };
}
