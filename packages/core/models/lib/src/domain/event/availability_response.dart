/// How an attendee answered a proposed date (#507).
///
/// Mirrors the backend's `AvailabilityResponse` enum
/// (`prisma/models/event/event-availability-vote.prisma` in
/// `board-games-empire-backend`).
enum AvailabilityResponse {
  /// The attendee can make this date.
  available,

  /// The attendee might be able to make this date.
  maybe,

  /// The attendee cannot make this date.
  unavailable,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole summary.
  static AvailabilityResponse fromWire(String name) => switch (name) {
    'Available' => AvailabilityResponse.available,
    'Maybe' => AvailabilityResponse.maybe,
    'Unavailable' => AvailabilityResponse.unavailable,
    _ => AvailabilityResponse.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    AvailabilityResponse.available => 'Available',
    AvailabilityResponse.maybe => 'Maybe',
    AvailabilityResponse.unavailable => 'Unavailable',
    AvailabilityResponse.unknown => throw StateError(
      'AvailabilityResponse.unknown has no wire name',
    ),
  };
}
