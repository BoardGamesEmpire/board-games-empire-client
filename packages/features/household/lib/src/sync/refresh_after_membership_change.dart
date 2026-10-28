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
/// The pass starts after any drain in flight ends, through
/// [HouseholdRefresher.refreshAfterChange], because that drain may have
/// read the list before the change. The stale mark stops it from stamping
/// the set fresh, and holds until the next drain starts; the pass run here
/// is that drain, and reads the set again.
Future<void> refreshAfterMembershipChange(
  HouseholdRefresher refresher,
  HouseholdHydrationStatus? status,
) async {
  status?.markStale();
  await refresher.refreshAfterChange();
}
