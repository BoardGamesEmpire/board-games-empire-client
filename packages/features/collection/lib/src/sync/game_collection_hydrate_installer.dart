import 'dart:async';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'game_collection_hydration_status.dart';
import 'game_collection_hydrator.dart';
import 'game_collection_refresher.dart';

/// Starts the collection hydrate when a user session activates (#259, #44).
///
/// Shared by both composition roots, `buildNativeUserScopeInstallers` and
/// `buildWebUserScopeInstallers`, as `HouseholdHydrateInstaller` is. It lives
/// in a feature package because the hydrate needs a repository and a remote,
/// and `drift_storage` cannot see `network_interface`. This package sees both.
///
/// What it resolves, and from where:
///
/// - [GameCollectionRepository] and [GameRepository], both registered in
///   the user-session scope by `UserSessionScopeInstaller`, so the
///   summaries a page writes are recorded for this session's user (#434);
/// - [GameCollectionRemoteDataSource], registered per server by the network
///   installer, and reached because the user-scope container view falls
///   through to it.
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
/// the household's is (#450 is the delta pass). A trigger arriving while a
/// pass is running is dropped rather than joined, as the household entry
/// does.
///
/// ## Publishing what the pass is doing (#44)
///
/// The list has to tell a cache that is filling from one that is empty, and
/// show when the last pass failed. So this registers a
/// [GameCollectionHydrationStatus] in the session scope and drives it around
/// every pass. The rehydrator entry answers `isStale` from that same status,
/// so the registry holds no staleness of its own to drift from what the
/// list reads (#302).
///
/// It also registers a [GameCollectionRefresher] over the same pass, for the
/// list's retry. A press is not a trigger: it is not filtered by staleness,
/// and it is not dropped while a pass runs. Overlap is safe because the
/// hydrator single-flights.
///
/// Where a collaborator is missing, neither is registered. The list reads an
/// absent status as idle and an absent refresher as no retry to offer, which
/// is the truth; a registered pair would claim a hydrate that cannot run.
class GameCollectionHydrateInstaller implements UserScopeInstaller {
  /// [now] overrides the clock [staleAfter] is measured on. Production
  /// leaves it null, which is the device clock; a test drives it so a
  /// five-minute window does not cost five real minutes.
  const GameCollectionHydrateInstaller({this.now});

  /// How long a completed pass stays current.
  ///
  /// The household's window (#300), taken as the same guess rather than a
  /// measurement. #44 kept it: a collection under one page costs one request
  /// to re-run, and the cost for larger ones is #450's to remove.
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

    final status = GameCollectionHydrationStatus(now: now);
    container.registerSingleton<GameCollectionHydrationStatus>(
      status,
      // A pass still in flight when the scope tears down then reports into
      // a closed status, which drops the update rather than throwing.
      dispose: (s) => s.close(),
    );

    /// One pass, shared by the install-time call, every re-run and the
    /// retry. Never throws.
    Future<void> pass() async {
      status.started();
      final outcome = await hydrator.hydrate().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        // Unreachable by contract: hydrate() reports failure in its return
        // value. Kept because the cost of being wrong is a sign-out.
        _log.error(
          'Collection hydrate escaped its own error handling',
          error: error,
          stackTrace: stackTrace,
          context: {'serverId': server.serverId},
        );
        return CollectionHydrateOutcome.failed;
      });
      status.finished(outcome);
    }

    if (container.isRegistered<SessionRehydrator>()) {
      container.get<SessionRehydrator>().register(
        'collection',
        isStale: () => switch (status.state) {
          GameCollectionHydrationState.idle ||
          GameCollectionHydrationState.failed => true,
          GameCollectionHydrationState.running => false,
          GameCollectionHydrationState.refreshed => status.isStaleAfter(
            staleAfter,
          ),
        },
        run: pass,
      );
    }

    container.registerSingleton<GameCollectionRefresher>(
      GameCollectionRefresher(pass),
    );

    // The hydrator is deliberately not registered: nothing resolves one by
    // type. The re-hydrate entry and the refresher close over this instance,
    // which keeps its single-flight guard meaningful. Once the session pops,
    // the repositories it writes through are disposed and the next write
    // ends the pass.
    //
    // `pass()` marks the status running before its first await, so the
    // status reads running before this method returns. A list built in that
    // window must not read idle.
    unawaited(pass());
  }
}
