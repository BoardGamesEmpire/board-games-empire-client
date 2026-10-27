import 'household_hydration_status.dart';
import 'household_refresher.dart';

/// Runs the hydrate pass that follows a change to a household's
/// membership.
///
/// Two callers, for different reasons:
///
/// - A join (#455). Accepting an invite creates the membership on the
///   server and nothing locally; the household arrives through the
///   ordinary hydrate pass, not a cache write of its own.
/// - A role change or removal (#480). The server's answer is already
///   cached by then. The pass catches a hydrate that read the roster
///   before the change and would write the old one back.
///
/// Both mark the cached set stale (#300) and run a pass.
///
/// Two passes when one was already running. [HouseholdRefresher.refresh]
/// joins a running pass rather than starting another, and that pass may
/// have read the list before the change. The stale mark stops it from
/// stamping the set fresh; the second pass reads it again.
Future<void> refreshAfterMembershipChange(
  HouseholdRefresher refresher,
  HouseholdHydrationStatus? status,
) async {
  final wasRunning = status?.state == HouseholdHydrationState.running;
  status?.markStale();
  await refresher.refresh();
  if (wasRunning) await refresher.refresh();
}
