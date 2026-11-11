/// How an attendee voted on an event game nomination (#517).
///
/// Mirrors the backend's `VoteType` enum
/// (`prisma/models/event/event-game-vote.prisma` in
/// `board-games-empire-backend`).
enum VoteType {
  /// In favour. Named `forGame` because `for` is a Dart keyword; the wire
  /// name is `For`.
  forGame,

  /// Opposed.
  against,

  /// Interested in the game without backing the nomination outright.
  interested,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static VoteType fromWire(String name) => switch (name) {
    'For' => VoteType.forGame,
    'Against' => VoteType.against,
    'Interested' => VoteType.interested,
    _ => VoteType.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    VoteType.forGame => 'For',
    VoteType.against => 'Against',
    VoteType.interested => 'Interested',
    VoteType.unknown => throw StateError('VoteType.unknown has no wire name'),
  };
}
