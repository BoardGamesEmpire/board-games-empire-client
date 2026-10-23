import 'household_hydration_status.dart';
import 'household_refresher.dart';

/// Brings a household the user just joined onto the device (#455).
///
/// Accepting an invite creates the membership on the server and nothing
/// locally; the household arrives through the ordinary hydrate pass, not a
/// cache write of its own. So this marks the cached set stale and runs a
/// pass.
///
/// Two passes when one was already running. [HouseholdRefresher.refresh]
/// joins a running pass rather than starting another, and that pass may
/// have read the list before the join. The stale mark stops it from
/// stamping the set fresh; the second pass reads it again.
Future<void> refreshAfterJoin(
  HouseholdRefresher refresher,
  HouseholdHydrationStatus? status,
) async {
  final wasRunning = status?.state == HouseholdHydrationState.running;
  status?.markStale();
  await refresher.refresh();
  if (wasRunning) await refresher.refresh();
}
