/// How an event's date is being settled.
///
/// Mirrors the backend's `EventSchedulingMode` enum
/// (`prisma/models/event/event.prisma` in `board-games-empire-backend`).
enum EventSchedulingMode {
  /// One known date: a single confirmed occurrence.
  fixed,

  /// An availability poll is running, and the event's occurrences are
  /// proposals.
  poll,

  /// Several confirmed occurrences, each with its own schedule.
  multiDay,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static EventSchedulingMode fromWire(String name) => switch (name) {
    'Fixed' => EventSchedulingMode.fixed,
    'Poll' => EventSchedulingMode.poll,
    'MultiDay' => EventSchedulingMode.multiDay,
    _ => EventSchedulingMode.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    EventSchedulingMode.fixed => 'Fixed',
    EventSchedulingMode.poll => 'Poll',
    EventSchedulingMode.multiDay => 'MultiDay',
    EventSchedulingMode.unknown => throw StateError(
      'EventSchedulingMode.unknown has no wire name',
    ),
  };
}
