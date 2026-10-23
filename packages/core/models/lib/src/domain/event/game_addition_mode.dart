/// How a game gets onto an event's lineup.
///
/// Mirrors the backend's `GameAdditionMode` enum
/// (`prisma/models/event/event-game-nomination.prisma` in
/// `board-games-empire-backend`).
enum GameAdditionMode {
  /// Attendees add straight to the lineup, with no process.
  direct,

  /// A nomination has to pass a vote before it joins the lineup.
  requiresVote,

  /// A nomination goes to the host before it joins the lineup.
  hostApproval,

  /// Only the host or a co-host can add games.
  hostOnly,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static GameAdditionMode fromWire(String name) => switch (name) {
    'Direct' => GameAdditionMode.direct,
    'RequiresVote' => GameAdditionMode.requiresVote,
    'HostApproval' => GameAdditionMode.hostApproval,
    'HostOnly' => GameAdditionMode.hostOnly,
    _ => GameAdditionMode.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    GameAdditionMode.direct => 'Direct',
    GameAdditionMode.requiresVote => 'RequiresVote',
    GameAdditionMode.hostApproval => 'HostApproval',
    GameAdditionMode.hostOnly => 'HostOnly',
    GameAdditionMode.unknown => throw StateError(
      'GameAdditionMode.unknown has no wire name',
    ),
  };
}
