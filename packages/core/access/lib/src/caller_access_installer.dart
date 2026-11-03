import 'dart:async';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'caller_access_reader.dart';

/// Registers the session's [CallerAccessRepository] and starts its first ask
/// when a user session activates (#456).
///
/// Per user, not per server, because the answer is the user's role: a
/// sign-out pops this scope, and the next user on the same server is asked
/// afresh.
///
/// Shared by both composition roots, like `HouseholdHydrateInstaller`, and
/// for the same reason: it needs only `interfaces`, `models`,
/// `network_interface` and `observability`. The [UserRemoteDataSource] it
/// resolves is registered per server by the network installer and reached
/// because the user-scope container view falls through to the per-server
/// scope, and so is the web's [SessionIdentityGuard].
///
/// ## Nothing here may throw or wait
///
/// A throw from [install] aborts the session's activation, and the shell
/// converges that to a sign-out. So the first ask runs unawaited, and a
/// container with no user client, or an empty [resourceTypes], registers
/// nothing, which every reader treats as "no answer": every control that
/// needs access stays hidden.
///
/// ## Asking again
///
/// The reader is registered with the session's [SessionRehydrator] as
/// `'caller_access'`, stale whenever no ask is in flight, so every trigger of
/// a pass asks again: a connectivity edge, an app resume, and the user
/// entering the household list, the collection or the events. A role can
/// change at any time, and the answer is one small request. A composition
/// without the rehydrator skips that, and the screens' own refreshes still
/// keep the answer current.
///
/// The entry starts the ask and returns without waiting for it. A pass runs
/// its entries one after another, and this one is stale whenever no ask is
/// out, so waiting would hold every entry after it, the sync drain included,
/// behind the round trip, and behind the two-second recheck of an all-none
/// answer. The reader runs one ask at a time, and the entry isn't stale while
/// one is out, so a pass that comes meanwhile leaves it to land.
class CallerAccessInstaller implements UserScopeInstaller {
  const CallerAccessInstaller({
    required this.resourceTypes,
    this.noneRecheckDelay = CallerAccessReader.defaultNoneRecheckDelay,
  });

  /// The types the session asks about. Each feature that reads the answer
  /// adds its own.
  final Set<ResourceType> resourceTypes;

  /// Passed to [CallerAccessReader.noneRecheckDelay].
  final Duration noneRecheckDelay;

  static final BgeLogger _log = BgeLogger('bge.access.install');

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    if (resourceTypes.isEmpty) {
      // The server answers an ask about no types with a 400.
      _log.debug(
        'No resource types to ask about; skipping the caller access reader',
        context: {'serverId': server.serverId},
      );
      return;
    }
    if (!container.isRegistered<UserRemoteDataSource>()) {
      _log.debug(
        'No user client on this server; skipping the caller access reader',
        context: {'serverId': server.serverId},
      );
      return;
    }

    final reader = CallerAccessReader(
      remote: container.get<UserRemoteDataSource>(),
      resourceTypes: resourceTypes,
      userId: userId,
      guard: container.isRegistered<SessionIdentityGuard>()
          ? container.get<SessionIdentityGuard>()
          : null,
      noneRecheckDelay: noneRecheckDelay,
    );
    container.registerSingleton<CallerAccessRepository>(
      reader,
      dispose: (_) => reader.dispose(),
    );

    if (container.isRegistered<SessionRehydrator>()) {
      container.get<SessionRehydrator>().register(
        'caller_access',
        isStale: () => !reader.isAsking,
        run: () async => unawaited(reader.refresh()),
      );
    }

    unawaited(reader.refresh());
  }
}
