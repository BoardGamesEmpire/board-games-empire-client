/// The kind of gathering an event is, such as a family night or a competitive
/// session.
///
/// Mirrors the backend's `EventType` enum
/// (`prisma/models/event/event-type.prisma` in `board-games-empire-backend`).
enum EventType {
  adultsOnly,
  casualGathering,
  competitivePlay,
  familyNight,
  kidFriendly,
  learningSession,
  longGameDay,
  mixedAges,
  partyGames,
  strategyNight,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static EventType fromWire(String name) => switch (name) {
    'AdultsOnly' => EventType.adultsOnly,
    'CasualGathering' => EventType.casualGathering,
    'CompetitivePlay' => EventType.competitivePlay,
    'FamilyNight' => EventType.familyNight,
    'KidFriendly' => EventType.kidFriendly,
    'LearningSession' => EventType.learningSession,
    'LongGameDay' => EventType.longGameDay,
    'MixedAges' => EventType.mixedAges,
    'PartyGames' => EventType.partyGames,
    'StrategyNight' => EventType.strategyNight,
    _ => EventType.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    EventType.adultsOnly => 'AdultsOnly',
    EventType.casualGathering => 'CasualGathering',
    EventType.competitivePlay => 'CompetitivePlay',
    EventType.familyNight => 'FamilyNight',
    EventType.kidFriendly => 'KidFriendly',
    EventType.learningSession => 'LearningSession',
    EventType.longGameDay => 'LongGameDay',
    EventType.mixedAges => 'MixedAges',
    EventType.partyGames => 'PartyGames',
    EventType.strategyNight => 'StrategyNight',
    EventType.unknown => throw StateError('EventType.unknown has no wire name'),
  };
}
