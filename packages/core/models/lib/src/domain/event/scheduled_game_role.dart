/// What a game is for on an event's lineup (#519).
///
/// Mirrors the backend's `ScheduledGameRole` enum
/// (`prisma/models/event/event-game.prisma` in `board-games-empire-backend`).
enum ScheduledGameRole {
  /// A main game for the event or the date.
  primary,

  /// A quick game while waiting, held to a maximum play time.
  filler,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static ScheduledGameRole fromWire(String name) => switch (name) {
    'Primary' => ScheduledGameRole.primary,
    'Filler' => ScheduledGameRole.filler,
    _ => ScheduledGameRole.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    ScheduledGameRole.primary => 'Primary',
    ScheduledGameRole.filler => 'Filler',
    ScheduledGameRole.unknown => throw StateError(
      'ScheduledGameRole.unknown has no wire name',
    ),
  };
}
