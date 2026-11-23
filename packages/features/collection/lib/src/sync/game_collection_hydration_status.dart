import 'package:game_collection/src/sync/game_collection_hydrator.dart';
import 'package:hydration/hydration.dart';

/// The collection hydrate's status: what the list reads to tell a cache that
/// is *filling* from one that is *empty* (#44).
///
/// Everything it does is [HydrationStatus]'s. What is the collection's is
/// which outcomes landed rows, [landsRows]: a
/// [CollectionHydrateOutcome.complete] pass. Only a
/// [CollectionHydrateOutcome.failed] one did not.
///
/// It never calls `markStale`: nothing on the collection list invalidates the
/// set, because an add (#45) writes to the cache and the list's stream shows
/// it without a pass.
///
/// It is also the key a session scope registers and a screen resolves the
/// status by, so a second feature's status is never mistaken for this one.
final class GameCollectionHydrationStatus
    extends HydrationStatus<CollectionHydrateOutcome> {
  /// [now] defaults to the device clock, and `confirmedBefore` is what the
  /// user's refresh marker said when the session started (#771); see
  /// [HydrationStatus].
  GameCollectionHydrationStatus({super.now, super.confirmedBefore})
    : super(landed: landsRows);

  /// Whether a pass that ended in [outcome] put rows in the cache.
  ///
  /// The one definition: the status reads a pass as landed by it, and
  /// `GameCollectionHydrateInstaller` records the refresh marker by it
  /// (#771), so an outcome added later cannot land rows without the marker.
  static bool landsRows(CollectionHydrateOutcome outcome) => switch (outcome) {
    CollectionHydrateOutcome.complete => true,
    CollectionHydrateOutcome.failed => false,
  };
}
