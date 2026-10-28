import 'dart:async';

import 'package:hydration/hydration.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'event_hydration_status.dart';
import 'event_hydrator.dart';
import 'event_refresher.dart';

/// Starts the event hydrate when a user session activates (#496).
///
/// Shared by both composition roots, `buildNativeUserScopeInstallers` and
/// `buildWebUserScopeInstallers`, as `GameCollectionHydrateInstaller` is. It
/// lives in a feature package because the hydrate needs a repository and a
/// remote, and `drift_storage` cannot see `network_interface`. This package
/// sees both.
///
/// Its pass is `HydratePass`, as the collection's and the household's are
/// (#407), with the same five-minute window.
///
/// What it resolves, and from where:
///
/// - [EventRepository], registered in the user-session scope by
///   `UserSessionScopeInstaller`, so the events a page writes are cached for
///   this session's user;
/// - [EventRemoteDataSource], registered per server by the network installer
///   (`registerServerNetwork` on native, `registerServerNetworkWeb` on web),
///   and reached because the user-scope container view falls through to it.
///
/// So it must run **after** `UserSessionScopeInstaller` in whichever list
/// holds it, and after `SessionRehydratorInstaller` too, whose registry it
/// joins.
///
/// ## Nothing here may throw
///
/// A throw from [install] aborts activation, and the shell converges that to
/// a sign-out. So the hydrate is started **unawaited**, keeping the network
/// off the sign-in path; the screens render from the cache regardless. And a
/// missing collaborator is a no-op rather than a resolution failure.
/// `HouseholdHydrateInstaller` records which compositions can reach that
/// guard. Both network installers register the event remote unconditionally
/// (#496), so no shipping one does.
///
/// ## Publishing what the pass is doing
///
/// The event screens have to tell a cache that is filling from one that is
/// empty, and show when the last pass failed. So this registers an
/// [EventHydrationStatus] in the session scope, and a `HydratePass` drives it
/// around every drain. Where a collaborator is missing, nothing is
/// registered: a screen reads an absent status as idle and an absent
/// refresher as no retry to offer, which is the truth; a registered pair
/// would claim a hydrate that cannot run.
///
/// ## What the pass does, and what this decides (#302, #563)
///
/// `HydratePass` is the one place a drain is single-flighted, checked
/// against the session and registered to be re-run; its class doc gives the
/// reasoning. This installer decides only what is the events':
///
/// - the pass is registered with the session's `SessionRehydrator` as
///   `'events'`, and again as an [EventRefresher] for a screen's retry;
/// - the window a `refreshed` pass ages out of is [staleAfter]. A pass that
///   ended `windowed` or `drained` counts as completed, since
///   [EventHydrationStatus] reads it as refreshed;
/// - the hydrator is deliberately not registered: nothing resolves one by
///   type. The pass closes over it. Once the session pops, the repository it
///   writes through is disposed and the next write ends the pass.
///
/// ## Whose session a pass reads as (#432)
///
/// The pass asks the [SessionIdentityGuard] once per drain, and the hydrator
/// asks again after each page it reads, before it writes it; this builds that
/// per-page closure from the same guard. On web another tab can move the
/// shared cookie to another user, and a page read then holds that user's
/// events, with nothing on the rows to say whose list they are. A refused
/// pass reads as `failed`, so the next trigger tries again. No guard, as on
/// native, is a confirmed session.
class EventHydrateInstaller implements UserScopeInstaller {
  /// [now] overrides the clock [staleAfter] is measured on. Production leaves
  /// it null, which is the device clock; a test drives it so a five-minute
  /// window does not cost five real minutes.
  const EventHydrateInstaller({this.now});

  /// How long a completed pass stays current.
  ///
  /// The household's window (#300), taken as the same guess rather than a
  /// measurement. A list that fits one page costs one request to re-run, and a
  /// longer one a request per page.
  static const Duration staleAfter = Duration(minutes: 5);

  static final BgeLogger _log = BgeLogger('bge.events.hydrate.install');

  /// See the constructor. Null is the device clock.
  final DateTime Function()? now;

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    if (!container.isRegistered<EventRemoteDataSource>() ||
        !container.isRegistered<EventRepository>()) {
      _log.debug(
        'No event client or cache on this server; skipping hydrate',
        context: {'serverId': server.serverId},
      );
      return;
    }

    final guard = container.isRegistered<SessionIdentityGuard>()
        ? container.get<SessionIdentityGuard>()
        : null;

    final hydrator = EventHydrator(
      repository: container.get<EventRepository>(),
      remote: container.get<EventRemoteDataSource>(),
      confirmSession: guard == null
          ? null
          : () async =>
                await guard.confirm(userId) == SessionConfirmation.confirmed,
    );

    final status = EventHydrationStatus(now: now);
    container.registerSingleton<EventHydrationStatus>(
      status,
      // A pass still in flight when the scope tears down then reports into a
      // closed status, which drops the update rather than throwing.
      dispose: (s) => s.close(),
    );

    final pass = HydratePass<EventHydrateOutcome>(
      feature: 'Event',
      drain: hydrator.hydrate,
      status: status,
      failed: EventHydrateOutcome.failed,
      userId: userId,
      logger: _log,
      guard: guard,
      context: {'serverId': server.serverId},
    );

    pass.registerRehydrate(container, 'events', staleAfter: staleAfter);

    container.registerSingleton<EventRefresher>(EventRefresher(pass.run));

    // Unawaited, and the status is running before this returns: a screen
    // built in that window must not read idle.
    unawaited(pass.run());
  }
}
