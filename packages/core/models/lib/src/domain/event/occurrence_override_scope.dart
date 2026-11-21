/// How far a date's own rules may depart from its event's (#1009).
///
/// Mirrors the backend's `OccurrenceOverrideScope` enum. It is an event policy
/// field: the event's host sets how much a date may override.
enum OccurrenceOverrideScope {
  /// A date takes the event's rules and may not override them.
  none,

  /// A date may override a rule only to make it stricter.
  tightenOnly,

  /// A date may override any rule.
  any,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static OccurrenceOverrideScope fromWire(String name) => switch (name) {
    'None' => OccurrenceOverrideScope.none,
    'TightenOnly' => OccurrenceOverrideScope.tightenOnly,
    'Any' => OccurrenceOverrideScope.any,
    _ => OccurrenceOverrideScope.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    OccurrenceOverrideScope.none => 'None',
    OccurrenceOverrideScope.tightenOnly => 'TightenOnly',
    OccurrenceOverrideScope.any => 'Any',
    OccurrenceOverrideScope.unknown => throw StateError(
      'OccurrenceOverrideScope.unknown has no wire name',
    ),
  };
}
