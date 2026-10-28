import 'package:hydration/hydration.dart';

import 'event_hydrator.dart';

/// The event hydrate's status: what the event screens read to tell a cache
/// that is *filling* from one that is *empty*, and rows that are current from
/// rows a failed pass left behind (#496).
///
/// Everything it does is [HydrationStatus]'s. What is the events' is which
/// outcomes landed rows: [EventHydrateOutcome.complete], and the
/// [EventHydrateOutcome.windowed] and [EventHydrateOutcome.drained] passes,
/// which cached every page the server sent while vouching for less of what
/// the purge removed. Only an [EventHydrateOutcome.failed] pass did not.
///
/// Unlike the household's, nothing marks it stale: the event screens do not
/// invalidate the cache, because a create (#499) caches the server's event
/// itself once it is acknowledged.
///
/// It is also the key a session scope registers and a screen resolves the
/// status by, so a second feature's status is never mistaken for this one.
final class EventHydrationStatus extends HydrationStatus<EventHydrateOutcome> {
  /// [now] defaults to the device clock; see [HydrationStatus].
  EventHydrationStatus({super.now})
    : super(
        landed: (outcome) => switch (outcome) {
          EventHydrateOutcome.complete ||
          EventHydrateOutcome.windowed ||
          EventHydrateOutcome.drained => true,
          EventHydrateOutcome.failed => false,
        },
      );
}
