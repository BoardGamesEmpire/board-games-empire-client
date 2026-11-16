import 'package:analytics/analytics.dart';
import 'package:models/domain.dart';

/// Exactly one instance of every event in the catalog, for the tests that
/// check each event's name and properties and the catalog snapshot.
final List<AnalyticsEvent> catalogSamples = [
  CollectionGameAdded(
    platformGameId: 'tz4a98xxat96iws9zmbrgj3a',
    medium: GameMedium.physical,
  ),
  CollectionGameRemoved(
    platformGameId: 'tz4a98xxat96iws9zmbrgj3a',
    medium: GameMedium.physical,
  ),
  const HouseholdCreated(),
  HouseholdInviteAccepted(role: HouseholdRole.householdMember),
  EventCreated(
    type: EventType.familyNight,
    schedulingMode: EventSchedulingMode.fixed,
  ),
  EventRsvpChanged(status: EventParticipationStatus.attending),
  const EventGameNominated(),
];

/// The area an event belongs to, from its class rather than its name.
///
/// The switch is exhaustive with no default, so a new catalog event fails to
/// compile here until it gets a case. It also needs a sample in
/// [catalogSamples], which the governance test checks against the classes
/// declared in the catalog's source.
String areaOf(AnalyticsEvent event) => switch (event) {
  CollectionGameAdded() || CollectionGameRemoved() => 'collection',
  HouseholdCreated() || HouseholdInviteAccepted() => 'household',
  EventCreated() || EventRsvpChanged() || EventGameNominated() => 'event',
};
