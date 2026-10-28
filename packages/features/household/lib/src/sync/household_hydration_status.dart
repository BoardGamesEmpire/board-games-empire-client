import 'package:hydration/hydration.dart';

import 'household_hydrator.dart';

/// The household hydrate's status: what a list screen reads to tell a cache
/// that is *filling* from one that is *empty* (#269).
///
/// Everything it does is [HydrationStatus]'s. What is the household's is
/// which outcomes landed rows: a [HydrateOutcome.complete] pass, and a
/// [HydrateOutcome.drained] one, which cached every household the server sent
/// without being a snapshot a purge could trust (#268). Only a
/// [HydrateOutcome.failed] pass did not.
///
/// The household is the one feature that calls [markStale], because its
/// mutations make the cached set stale by definition: a create does, from
/// the shell's create route (#300), and so do a join (#455) and a member's
/// role change or removal (#480), the last two through
/// `refreshAfterMembershipChange`.
///
/// It is also the key a session scope registers and a screen resolves the
/// status by, so a second feature's status is never mistaken for this one.
final class HouseholdHydrationStatus extends HydrationStatus<HydrateOutcome> {
  /// [now] defaults to the device clock; see [HydrationStatus].
  HouseholdHydrationStatus({super.now})
    : super(
        landed: (outcome) => switch (outcome) {
          HydrateOutcome.complete || HydrateOutcome.drained => true,
          HydrateOutcome.failed => false,
        },
      );
}
