import 'package:analytics/src/analytics_value.dart';
import 'package:models/domain.dart';

/// A "user did X" fact from the analytics catalog (#17).
///
/// The catalog is closed by `sealed`: an event can only be declared in this
/// library, so adding one means adding it here, where review and the
/// catalog snapshot test see it.
///
/// There are no pre-auth events. Recipients and consent exist only after
/// sign-in, so an event from before it could only be delivered by buffering
/// it first, and that is collecting before consent (#17). Play sessions are
/// left out until they ship.
sealed class AnalyticsEvent {
  const AnalyticsEvent();

  /// The event's name, `area.verb_past` in snake case.
  String get name;

  /// The event's properties, keyed in camelCase. The map is unmodifiable,
  /// so one recorder cannot rewrite what another sees.
  Map<String, AnalyticsValue> get properties;
}

/// The user added a game to their collection.
final class CollectionGameAdded extends AnalyticsEvent {
  /// Throws [ArgumentError] when [platformGameId] isn't an opaque id.
  CollectionGameAdded({required this.platformGameId, required this.medium})
    : properties = Map.unmodifiable(<String, AnalyticsValue>{
        'platformGameId': AnalyticsId(platformGameId),
        'medium': AnalyticsToken(medium, vocabulary: GameMedium.values),
      });

  /// The server id of the platform game the entry is for.
  final String platformGameId;

  /// Whether the copy is physical or digital.
  final GameMedium medium;

  @override
  String get name => 'collection.game_added';

  @override
  final Map<String, AnalyticsValue> properties;
}

/// The user removed a game from their collection.
final class CollectionGameRemoved extends AnalyticsEvent {
  /// Throws [ArgumentError] when [platformGameId] isn't an opaque id.
  CollectionGameRemoved({required this.platformGameId, required this.medium})
    : properties = Map.unmodifiable(<String, AnalyticsValue>{
        'platformGameId': AnalyticsId(platformGameId),
        'medium': AnalyticsToken(medium, vocabulary: GameMedium.values),
      });

  /// The server id of the platform game the entry was for.
  final String platformGameId;

  /// Whether the copy was physical or digital.
  final GameMedium medium;

  @override
  String get name => 'collection.game_removed';

  @override
  final Map<String, AnalyticsValue> properties;
}

/// The user created a household.
final class HouseholdCreated extends AnalyticsEvent {
  const HouseholdCreated();

  @override
  String get name => 'household.created';

  @override
  Map<String, AnalyticsValue> get properties => const {};
}

/// The user accepted an invitation to a household.
final class HouseholdInviteAccepted extends AnalyticsEvent {
  HouseholdInviteAccepted({required this.role})
    : properties = Map.unmodifiable(<String, AnalyticsValue>{
        'role': AnalyticsToken(role, vocabulary: HouseholdRole.values),
      });

  /// The role the user joined with.
  final HouseholdRole role;

  @override
  String get name => 'household.invite_accepted';

  @override
  final Map<String, AnalyticsValue> properties;
}

/// The user created an event.
final class EventCreated extends AnalyticsEvent {
  EventCreated({required this.type, required this.schedulingMode})
    : properties = Map.unmodifiable(<String, AnalyticsValue>{
        'type': AnalyticsToken(type, vocabulary: EventType.values),
        'schedulingMode': AnalyticsToken(
          schedulingMode,
          vocabulary: EventSchedulingMode.values,
        ),
      });

  /// The kind of gathering.
  final EventType type;

  /// How the event's date is being settled.
  final EventSchedulingMode schedulingMode;

  @override
  String get name => 'event.created';

  @override
  final Map<String, AnalyticsValue> properties;
}

/// The user changed their answer to an event invitation.
final class EventRsvpChanged extends AnalyticsEvent {
  EventRsvpChanged({required this.status})
    : properties = Map.unmodifiable(<String, AnalyticsValue>{
        'status': AnalyticsToken(
          status,
          vocabulary: EventParticipationStatus.values,
        ),
      });

  /// The new answer.
  final EventParticipationStatus status;

  @override
  String get name => 'event.rsvp_changed';

  @override
  final Map<String, AnalyticsValue> properties;
}

/// The user nominated a game for an event.
final class EventGameNominated extends AnalyticsEvent {
  const EventGameNominated();

  @override
  String get name => 'event.game_nominated';

  @override
  Map<String, AnalyticsValue> get properties => const {};
}
