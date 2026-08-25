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

    // Deliberately not registered in the container: nothing resolves a
    // hydrator, and it holds no resources to dispose. The drain is bounded
    // by the scope anyway — once the session pops, the repository it writes
    // through is disposed and the next write ends the pass.
    unawaited(
      hydrator.hydrate().catchError((Object error, StackTrace stackTrace) {
        // Unreachable by contract — hydrate() reports failure in its return
        // value. Kept because the cost of being wrong is a sign-out.
        _log.error(
          'Household hydrate escaped its own error handling',
          error: error,
          stackTrace: stackTrace,
          context: {'serverId': config.bgeServerId},
        );
        return HydrateOutcome.failed;
      }),
    );
  }
}
