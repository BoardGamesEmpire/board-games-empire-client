/// An attendee's answer to an invitation to an event.
///
/// Mirrors the backend's `EventParticipationStatus` enum
/// (`prisma/models/event/event-participation-status.prisma` in
/// `board-games-empire-backend`). [invited] is where an attendee starts, until
/// they answer.
enum EventParticipationStatus {
  attending,
  invited,
  maybe,
  notAttending,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static EventParticipationStatus fromWire(String name) => switch (name) {
    'Attending' => EventParticipationStatus.attending,
    'Invited' => EventParticipationStatus.invited,
    'Maybe' => EventParticipationStatus.maybe,
    'NotAttending' => EventParticipationStatus.notAttending,
    _ => EventParticipationStatus.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    EventParticipationStatus.attending => 'Attending',
    EventParticipationStatus.invited => 'Invited',
    EventParticipationStatus.maybe => 'Maybe',
    EventParticipationStatus.notAttending => 'NotAttending',
    EventParticipationStatus.unknown => throw StateError(
      'EventParticipationStatus.unknown has no wire name',
    ),
  };
}
