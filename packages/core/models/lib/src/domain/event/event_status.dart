/// Where an event stands in its life, as the server records it.
///
/// Mirrors the backend's `EventStatus` enum (`prisma/models/event/event.prisma`
/// in `board-games-empire-backend`). backend#795 will change this set, so a
/// status this client does not know is an expected outcome rather than
/// corruption: it reads as [unknown], and the event stays readable (#496).
enum EventStatus {
  archived,
  cancelled,
  completed,
  ongoing,
  planning,
  scheduled,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static EventStatus fromWire(String name) => switch (name) {
    'Archived' => EventStatus.archived,
    'Cancelled' => EventStatus.cancelled,
    'Completed' => EventStatus.completed,
    'Ongoing' => EventStatus.ongoing,
    'Planning' => EventStatus.planning,
    'Scheduled' => EventStatus.scheduled,
    _ => EventStatus.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    EventStatus.archived => 'Archived',
    EventStatus.cancelled => 'Cancelled',
    EventStatus.completed => 'Completed',
    EventStatus.ongoing => 'Ongoing',
    EventStatus.planning => 'Planning',
    EventStatus.scheduled => 'Scheduled',
    EventStatus.unknown => throw StateError(
      'EventStatus.unknown has no wire name',
    ),
  };
}
