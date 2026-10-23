import 'dart:async';

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
/// Its pass and re-run entry copy the collection installer's, five-minute
/// window included. #407 is where the copies would become one, and events
/// are its third consumer.
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
/// ## Re-run when it did not finish, or has aged
///
/// The install-time pass is otherwise the only one a session gets. One that
/// started offline would leave the events unhydrated until the next sign-in,
/// which is the problem the [SessionRehydrator] exists for (#302). So the pass
/// is registered with it, under the key `'events'`, and a later trigger (a
/// connectivity edge, an app resume) re-runs it.
///
/// The entry reports itself stale when no pass has completed or the last one
/// failed, and once a completed pass is [staleAfter] old. A pass in flight is
/// not stale: a trigger arriving while one runs is dropped rather than
/// joined, as the household entry does. Without the window a session that
/// hydrated at sign-in never saw another device's changes however long it
/// ran, which #300 fixed for households. Each re-run is a full drain, as the
/// household's is.
///
/// A pass that ended `windowed` or `drained` counts as completed here, since
/// [EventHydrationStatus.finished] reads it as refreshed.
///
/// ## Publishing what the pass is doing
///
/// The event screens have to tell a cache that is filling from one that is
/// empty, and show when the last pass failed. So this registers an
/// [EventHydrationStatus] in the session scope and drives it around every
/// pass. The rehydrator entry answers `isStale` from that same status, so the
/// registry holds no staleness of its own to drift from what the screens read
/// (#302).
///
/// It also registers an [EventRefresher] over the same pass, for a screen's
/// retry. A press is not a trigger: it is not filtered by staleness, and it is
/// not dropped while a pass runs. Overlap is safe because the hydrator
/// single-flights.
///
/// Where a collaborator is missing, neither is registered. A screen reads an
/// absent status as idle and an absent refresher as no retry to offer, which
/// is the truth; a registered pair would claim a hydrate that cannot run.
///
/// ## Whose session a pass reads as (#432)
///
/// Every pass first asks the [SessionIdentityGuard] whether the session is
/// still this scope's user, as the household's does, and the hydrator asks
/// again after each page it reads, before it writes it. On web another tab can
/// move the shared cookie to another user, and a page read then holds that
/// user's events, with nothing on the rows to say whose list they are. The
/// first question keeps a refused pass from sending anything; the second
/// catches a session that changes hands mid-drain. A refused pass reads as
/// `failed`, so the next trigger tries again. No guard, as on native, is a
/// confirmed session.
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

    /// One pass, shared by the install-time call, every re-run and the retry.
    /// Never throws.
    Future<void> pass() async {
      status.started();
      final answer = await guard?.confirm(userId);
      if (answer != null && answer != SessionConfirmation.confirmed) {
        _log.info(
          'Event hydrate held off: the session could not be confirmed as this '
          'scope\'s user',
          context: {'serverId': server.serverId, 'answer': answer.name},
        );
        status.finished(EventHydrateOutcome.failed);
        return;
      }
      final outcome = await hydrator.hydrate().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        // Unreachable by contract: hydrate() reports failure in its return
        // value. Kept because the cost of being wrong is a sign-out.
        _log.error(
          'Event hydrate escaped its own error handling',
          error: error,
          stackTrace: stackTrace,
          context: {'serverId': server.serverId},
        );
        return EventHydrateOutcome.failed;
      });
      status.finished(outcome);
    }

    if (container.isRegistered<SessionRehydrator>()) {
      container.get<SessionRehydrator>().register(
        'events',
        isStale: () => switch (status.state) {
          EventHydrationState.idle || EventHydrationState.failed => true,
          EventHydrationState.running => false,
          EventHydrationState.refreshed => status.isStaleAfter(staleAfter),
        },
        run: pass,
      );
    }

    container.registerSingleton<EventRefresher>(EventRefresher(pass));

    // The hydrator is deliberately not registered: nothing resolves one by
    // type. The re-hydrate entry and the refresher close over this instance,
    // which keeps its single-flight guard meaningful. Once the session pops,
    // the repository it writes through is disposed and the next write ends the
    // pass.
    //
    // `pass()` marks the status running before its first await, so the status
    // reads running before this method returns. A screen built in that window
    // must not read idle.
    unawaited(pass());
  }
}
