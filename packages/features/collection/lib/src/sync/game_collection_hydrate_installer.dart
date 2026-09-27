import 'dart:async';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'game_collection_hydrator.dart';

/// Starts the collection hydrate when a user session activates (#259, #44).
///
/// Shared by both composition roots, `buildNativeUserScopeInstallers` and
/// `buildWebUserScopeInstallers`, as `HouseholdHydrateInstaller` is. It lives
/// in a feature package because the hydrate needs a repository and a remote,
/// and `drift_storage` cannot see `network_interface`. This package sees both.
///
/// What it resolves, and from where:
///
/// - [GameCollectionRepository], registered in the user-session scope by
///   `UserSessionScopeInstaller`;
/// - [GameRepository], registered per server by the storage installer, and
///   reached because the user-scope container view falls through to it;
/// - [GameCollectionRemoteDataSource], registered per server by the network
///   installer, reached the same way.
///
/// So it must run **after** `UserSessionScopeInstaller` in whichever list
/// holds it, and after `SessionRehydratorInstaller` too, whose registry it
/// joins.
///
/// ## Nothing here may throw
///
/// A throw from [install] aborts activation, and the shell converges that to
/// a sign-out. So the hydrate is started **unawaited**, keeping the network
/// off the sign-in path; the list renders from the cache regardless. And a
/// missing collaborator is a no-op rather than a resolution failure.
/// `HouseholdHydrateInstaller` records which compositions can reach that
/// guard; since #125 and #368 no shipping one does.
///
/// ## Re-run when it did not finish, or has aged
///
/// The install-time pass is otherwise the only one a session gets. One that
/// started offline would leave the collection unhydrated until the next
/// sign-in, which is the problem the [SessionRehydrator] exists for (#302).
/// So the pass is registered with it, and a later trigger (a connectivity
/// edge, an app resume) re-runs it.
///
/// It reports itself stale until a pass completes, after one fails, and
/// once a completed pass is [staleAfter] old. Without that window a session
/// that hydrated at sign-in never saw another device's changes however long
/// it ran, which #300 fixed for households. Each re-run is a full drain, as
/// the household's is. A trigger arriving while a pass is running is
/// dropped rather than joined, as the household entry does.
///
/// Nothing publishes the pass's state yet. The list screen (#44) is the
/// first reader that would need one.
class GameCollectionHydrateInstaller implements UserScopeInstaller {
  /// [now] overrides the clock [staleAfter] is measured on. Production
  /// leaves it null, which is the device clock; a test drives it so a
  /// five-minute window does not cost five real minutes.
  const GameCollectionHydrateInstaller({this.now});

  /// How long a completed pass stays current.
  ///
  /// The household's window (#300), taken as the same guess rather than a
  /// measurement. Whether the collection list wants another is #44's call.
  static const Duration staleAfter = Duration(minutes: 5);

  static final BgeLogger _log = BgeLogger('bge.collection.hydrate.install');

  /// See the constructor. Null is the device clock.
  final DateTime Function()? now;

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    if (!container.isRegistered<GameCollectionRemoteDataSource>() ||
        !container.isRegistered<GameCollectionRepository>() ||
        !container.isRegistered<GameRepository>()) {
      _log.debug(
        'No collection client or cache on this server; skipping hydrate',
        context: {'serverId': server.serverId},
      );
      return;
    }

    final hydrator = GameCollectionHydrator(
      collection: container.get<GameCollectionRepository>(),
      games: container.get<GameRepository>(),
      remote: container.get<GameCollectionRemoteDataSource>(),
    );

    final clock = now ?? DateTime.now;
    var running = false;
    // When the last pass completed. Null until one does, and again after
    // one fails: either way another pass is worth running.
    DateTime? completedAt;

    /// One pass, shared by the install-time call and every re-run. Never
    /// throws.
    Future<void> pass() async {
      running = true;
      try {
        final outcome = await hydrator.hydrate();
        completedAt = outcome == CollectionHydrateOutcome.complete
            ? clock()
            : null;
      } on Object catch (error, stackTrace) {
        // Unreachable by contract: hydrate() reports failure in its return
        // value. Kept because the cost of being wrong is a sign-out.
        _log.error(
          'Collection hydrate escaped its own error handling',
          error: error,
          stackTrace: stackTrace,
          context: {'serverId': server.serverId},
        );
      } finally {
        running = false;
      }
    }

    /// Inclusive at the boundary, as the household's is: at exactly
    /// [staleAfter] the pass is already that old.
    bool isStale() {
      if (running) return false;
      final at = completedAt;
      return at == null || clock().difference(at) >= staleAfter;
    }

    if (container.isRegistered<SessionRehydrator>()) {
      container.get<SessionRehydrator>().register(
        'collection',
        isStale: isStale,
        run: pass,
      );
    }

    // The hydrator is deliberately not registered: nothing resolves one by
    // type. The re-hydrate entry closes over this instance, which keeps its
    // single-flight guard meaningful. Once the session pops, the
    // repositories it writes through are disposed and the next write ends
    // the pass.
    unawaited(pass());
  }
}
