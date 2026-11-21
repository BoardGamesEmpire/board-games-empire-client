/// How far a date's own rules may depart from its event's restrictions: the
/// allowed platform types, platforms and categories, and capacity (#1009).
///
/// Mirrors the backend's `OccurrenceOverrideScope` enum. It is an event policy
/// field: the event's host sets how much a date may override. It covers only
/// those restrictions. A date's other rules, such as its game addition mode
/// and voting rules, may override the event's whatever the scope.
enum OccurrenceOverrideScope {
  /// A date may not override the event's restrictions.
  none,

  /// A date may override a restriction only to make it stricter.
  tightenOnly,

  /// A date may override a restriction either way, or lift it.
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
