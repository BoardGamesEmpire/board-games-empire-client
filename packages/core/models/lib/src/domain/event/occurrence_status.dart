/// Where one occurrence of an event stands.
///
/// Mirrors the backend's `OccurrenceStatus` enum
/// (`prisma/models/event/event-occurrence.prisma` in
/// `board-games-empire-backend`).
enum OccurrenceStatus {
  /// A poll candidate, open for availability votes.
  proposed,

  /// Locked in: it has, or will have, a concrete start date.
  confirmed,

  /// A proposed date the host did not select.
  declined,

  /// A confirmed occurrence that was cancelled afterwards.
  cancelled,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static OccurrenceStatus fromWire(String name) => switch (name) {
    'Proposed' => OccurrenceStatus.proposed,
    'Confirmed' => OccurrenceStatus.confirmed,
    'Declined' => OccurrenceStatus.declined,
    'Cancelled' => OccurrenceStatus.cancelled,
    _ => OccurrenceStatus.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    OccurrenceStatus.proposed => 'Proposed',
    OccurrenceStatus.confirmed => 'Confirmed',
    OccurrenceStatus.declined => 'Declined',
    OccurrenceStatus.cancelled => 'Cancelled',
    OccurrenceStatus.unknown => throw StateError(
      'OccurrenceStatus.unknown has no wire name',
    ),
  };
}
