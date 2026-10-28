import 'dart:async';

import 'package:hydration/hydration.dart';
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
/// ## What the pass does, and what this decides (#302, #563)
///
/// `HydratePass` is the one place a drain is single-flighted, checked
/// against the session and registered to be re-run; its class doc gives the
/// reasoning. This installer decides only what is the collection's:
///
/// - the pass is registered with the [SessionRehydrator] as `'collection'`,
///   and again as a [GameCollectionRefresher] for the list's retry (#44). The
///   refresher's `refreshAfterChange` waits out a running pass and then runs
///   one that starts after it, for a local write the running pass may have
///   merged the page of already (#190);
/// - the window a completed pass ages out of is [staleAfter]. Without it a
///   session that hydrated at sign-in never saw another device's changes
///   however long it ran, which #300 fixed for households. A re-run after a
///   completed pass usually reads only what changed since, where the
///   household's drains in full (#450); [GameCollectionHydrator] says when
///   it reads everything;
/// - the status is [GameCollectionHydrationStatus], registered in the
///   session scope;
/// - the hydrator is deliberately not registered. Nothing resolves one by
///   type; the pass closes over it.
///
/// Where a collaborator is missing, neither the status nor the refresher is
/// registered. The list reads an absent status as idle and an absent
/// refresher as no retry to offer, which is the truth; a registered pair
/// would claim a hydrate that cannot run.
///
/// ## Whose session a pass reads as (#432)
///
/// The pass asks the [SessionIdentityGuard] once per drain, before its first
/// request, for the household's reason: on web another tab can move the
/// shared cookie to another user, and a pass read then would be that user's
/// collection. A refused pass reads as `failed`. No guard, as on native, is
/// a confirmed session.
class GameCollectionHydrateInstaller implements UserScopeInstaller {
  /// [now] overrides the clock [staleAfter] is measured on. Production
  /// leaves it null, which is the device clock; a test drives it so a
  /// five-minute window does not cost five real minutes.
  const GameCollectionHydrateInstaller({this.now});

  /// How long a completed pass stays current.
  ///
  /// The household's window (#300), taken as the same guess rather than a
  /// measurement. #44 kept it, and so did #450, which made a re-run after a
  /// completed pass usually ask only for what changed since: one request,
  /// unless more than a page has. [GameCollectionHydrator] says when a
  /// re-run reads everything instead.
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
      userId: userId,
    );

    final guard = container.isRegistered<SessionIdentityGuard>()
        ? container.get<SessionIdentityGuard>()
        : null;

    final status = GameCollectionHydrationStatus(now: now);
    container.registerSingleton<GameCollectionHydrationStatus>(
      status,
      // A pass still in flight when the scope tears down then reports into
      // a closed status, which drops the update rather than throwing.
      dispose: (s) => s.close(),
    );

    final pass = HydratePass<CollectionHydrateOutcome>(
      feature: 'Collection',
      drain: hydrator.hydrate,
      status: status,
      failed: CollectionHydrateOutcome.failed,
      userId: userId,
      logger: _log,
      guard: guard,
      context: {'serverId': server.serverId},
    );

    pass.registerRehydrate(container, 'collection', staleAfter: staleAfter);

    container.registerSingleton<GameCollectionRefresher>(
      GameCollectionRefresher(pass.run, afterChange: pass.runAfterSettled),
    );

    // Unawaited, and the status is running before this returns: a list built
    // in that window must not read idle.
    unawaited(pass.run());
  }
}
