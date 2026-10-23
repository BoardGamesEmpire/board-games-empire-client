/// How an "interested" vote counts toward a nominated game's result.
///
/// Mirrors the backend's `InterestedWeight` enum
/// (`prisma/models/event/event-game-vote.prisma` in
/// `board-games-empire-backend`).
enum InterestedWeight {
  /// Counts as a vote in favour.
  asFor,

  /// Left out of the count, so it neither helps nor hurts the nomination.
  asAbstain,

  /// Counts as a vote against.
  asAgainst,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static InterestedWeight fromWire(String name) => switch (name) {
    'AsFor' => InterestedWeight.asFor,
    'AsAbstain' => InterestedWeight.asAbstain,
    'AsAgainst' => InterestedWeight.asAgainst,
    _ => InterestedWeight.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    InterestedWeight.asFor => 'AsFor',
    InterestedWeight.asAbstain => 'AsAbstain',
    InterestedWeight.asAgainst => 'AsAgainst',
    InterestedWeight.unknown => throw StateError(
      'InterestedWeight.unknown has no wire name',
    ),
  };
}
