/// An attendee's role on an event.
///
/// Maps to the server-side `Role.name` string behind an attendee's role
/// binding. The wire names mirror the event-prefixed entries of the backend's
/// `SystemRole` enum (`prisma/models/permissions/role.prisma` in
/// `board-games-empire-backend`) and keep the `Event` prefix (`EventHost`); the
/// Dart names drop it, because the type already says whose role it is.
///
/// A deployment is free to define roles beyond those, so a name this client
/// does not know is a supported outcome rather than an error: it reads as
/// [unknown] instead of failing the attendee's row (#496).
enum EventRole {
  host,
  coHost,
  organizer,
  moderator,
  participant,
  guest,
  spectator,

  /// A role name this client does not know. Never sent.
  unknown;

  /// Resolves a server role **name** to its binding, degrading to [unknown]
  /// for a name this client does not know rather than failing the whole row.
  ///
  /// Callers reading the embedded role projection unwrap it to the name first:
  /// handing this anything else would turn a shape mismatch into a
  /// plausible-looking [unknown].
  static EventRole fromWire(String name) => switch (name) {
    'EventHost' => EventRole.host,
    'EventCoHost' => EventRole.coHost,
    'EventOrganizer' => EventRole.organizer,
    'EventModerator' => EventRole.moderator,
    'EventParticipant' => EventRole.participant,
    'EventGuest' => EventRole.guest,
    'EventSpectator' => EventRole.spectator,
    _ => EventRole.unknown,
  };

  /// The backend's role name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    EventRole.host => 'EventHost',
    EventRole.coHost => 'EventCoHost',
    EventRole.organizer => 'EventOrganizer',
    EventRole.moderator => 'EventModerator',
    EventRole.participant => 'EventParticipant',
    EventRole.guest => 'EventGuest',
    EventRole.spectator => 'EventSpectator',
    EventRole.unknown => throw StateError('EventRole.unknown has no wire name'),
  };
}
