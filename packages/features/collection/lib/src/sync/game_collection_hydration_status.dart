import 'package:hydration/hydration.dart';

import 'game_collection_hydrator.dart';

/// The collection hydrate's status: what the list reads to tell a cache that
/// is *filling* from one that is *empty* (#44).
///
/// Everything it does is [HydrationStatus]'s. What is the collection's is
/// which outcomes landed rows: a [CollectionHydrateOutcome.complete] pass.
/// Only a [CollectionHydrateOutcome.failed] one did not.
///
/// It never calls `markStale`: nothing on the collection list invalidates the
/// set, because an add (#45) writes to the cache and the list's stream shows
/// it without a pass.
///
/// It is also the key a session scope registers and a screen resolves the
/// status by, so a second feature's status is never mistaken for this one.
final class GameCollectionHydrationStatus
    extends HydrationStatus<CollectionHydrateOutcome> {
  /// [now] defaults to the device clock; see [HydrationStatus].
  GameCollectionHydrationStatus({super.now})
    : super(
        landed: (outcome) => switch (outcome) {
          CollectionHydrateOutcome.complete => true,
          CollectionHydrateOutcome.failed => false,
        },
      );
}
