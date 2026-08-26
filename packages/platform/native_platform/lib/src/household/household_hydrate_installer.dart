import 'dart:async';

import 'package:household/household.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Starts the household hydrate when a user session activates (#267 D1).
///
/// The hydrator itself lives with the household feature; only this wiring is
/// platform code. It has to be: the hydrator needs both a
/// [HouseholdRepository] (registered in the user-session scope by
/// `UserSessionScopeInstaller`) and a [HouseholdRemoteDataSource]
/// (registered per-server by `registerServerNetwork`, resolved here because
/// the user-scope container view falls through to the per-server scope) —
/// and `drift_storage`, where the storage installer lives, does not depend
/// on `network_interface` at all. The composition root is the one place that
/// can see both halves.
///
/// This installer must therefore run **after** `UserSessionScopeInstaller`
/// in [buildNativeUserScopeInstallers]; installers run in list order and may
/// resolve what a predecessor registered.
///
/// ## Nothing here may throw
///
/// A throw from [install] aborts user-session scope activation, and the
/// shell converges that to a **sign-out** — the bootstrap gate does not
/// advance and `AuthSignOutRequested` is dispatched. So:
///
/// - the drain is started **unawaited**, because awaiting it would put the
///   network on the sign-in path (#267 D2). The household list renders
///   reactively off the local cache, so hydration is a refresh, not a
///   precondition for the screen;
/// - a missing [HouseholdRemoteDataSource] is a no-op rather than a
///   resolution failure. Web registers no household client (#137), and a
///   composition without one should sign in normally with a
///   local-cache-only list.
///
/// The hydrator swallows its own failures; the `unawaited` here is
/// deliberate rather than incidental, and the guard below keeps it that way
/// even if that ever changes.
///
/// ## Publishing what the drain is doing (#269 D1)
///
/// The outcome used to be discarded here, which left the household list
/// unable to tell an empty cache that is *filling* from one that is
/// *empty*, or a failed refresh from a successful one — `watchHouseholds()`
/// answers neither. So this registers a [HouseholdHydrationStatus] in the
/// session scope and drives it around the drain.
///
/// Where there is no household client, **nothing is registered**: a reader
/// treats an absent status as idle, which is the truth, whereas a
/// permanently-idle registered one would be a claim the screen cannot see
/// through.
///
/// The status is marked running **synchronously**, before the unawaited
/// drain takes its first turn. The list screen can be built inside that
/// window, and an idle status there would render "no households yet" over
/// a cache that is about to fill — the exact flash this decision exists to
/// prevent.
class HouseholdHydrateInstaller implements UserScopeInstaller {
  const HouseholdHydrateInstaller();

  static final BgeLogger _log = BgeLogger('bge.household.hydrate.install');

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
    String userId,
  ) async {
    if (!container.isRegistered<HouseholdRemoteDataSource>()) {
      _log.debug(
        'No household client on this server; skipping hydrate',
        context: {'serverId': config.bgeServerId},
      );
      return;
    }

    final hydrator = HouseholdHydrator(
      repository: container.get<HouseholdRepository>(),
      remote: container.get<HouseholdRemoteDataSource>(),
    );

    final status = HouseholdHydrationStatus();
    container.registerSingleton<HouseholdHydrationStatus>(
      status,
      // Close-on-teardown, like the repositories this scope registers. A
      // pass still in flight then reports into a closed status, which
      // drops the update rather than throwing — see
      // [HouseholdHydrationStatus].
      dispose: (s) => s.close(),
    );

    // Before the drain's first turn, not inside it: a screen built in that
    // window must not read idle.
    status.started();

    // The hydrator itself is deliberately not registered: nothing resolves
    // one, and it holds no resources to dispose. The drain is bounded by
    // the scope anyway — once the session pops, the repository it writes
    // through is disposed and the next write ends the pass.
    unawaited(
      hydrator
          .hydrate()
          .catchError((Object error, StackTrace stackTrace) {
            // Unreachable by contract — hydrate() reports failure in its
            // return value. Kept because the cost of being wrong is a
            // sign-out.
            _log.error(
              'Household hydrate escaped its own error handling',
              error: error,
              stackTrace: stackTrace,
              context: {'serverId': config.bgeServerId},
            );
            return HydrateOutcome.failed;
          })
          .then(status.finished),
    );
  }
}
