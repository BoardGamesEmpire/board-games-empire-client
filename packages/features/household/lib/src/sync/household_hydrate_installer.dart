import 'dart:async';

import 'package:hydration/hydration.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'household_hydration_status.dart';
import 'household_hydrator.dart';
import 'household_refresher.dart';

/// Starts the household hydrate when a user session activates (#267).
///
/// Lives beside the hydrator it drives, and is shared by both composition
/// roots — `buildNativeUserScopeInstallers` and `buildWebUserScopeInstallers`
/// each hold this same installer rather than a platform copy of it (#125).
///
/// It sat in `native_platform` until #125, on the reasoning that only a
/// composition root can see both halves of what the hydrator needs: a
/// [HouseholdRepository] (registered in the user-session scope by
/// `UserSessionScopeInstaller`) and a [HouseholdRemoteDataSource] (registered
/// per-server by the network installer, resolved here because the user-scope
/// container view falls through to the per-server scope). The constraint was
/// real but it was `drift_storage`'s — that package does not depend on
/// `network_interface` at all. This one does, and on `interfaces` besides, so
/// it can see both halves without a platform package's help.
///
/// This installer must run **after** `UserSessionScopeInstaller` in whichever
/// list holds it; installers run in list order and may resolve what a
/// predecessor registered.
///
/// ## Nothing here may throw
///
/// A throw from [install] aborts user-session scope activation, and the
/// shell converges that to a **sign-out** — the bootstrap gate does not
/// advance and `AuthSignOutRequested` is dispatched. So:
///
/// - the drain is started **unawaited**, because awaiting it would put the
///   network on the sign-in path (#267). The household list renders
///   reactively off the local cache, so hydration is a refresh, not a
///   precondition for the screen;
/// - a missing [HouseholdRemoteDataSource] is a no-op rather than a
///   resolution failure.
///
/// ## Which compositions reach that guard (#125)
///
/// This is the canonical statement; the readers of an absent
/// [HouseholdHydrationStatus] cite it rather than restating it.
///
/// [install] runs only where a composition supplied user installers, and the
/// guard fires only when the user tier registered a [HouseholdRepository]
/// while no [HouseholdRemoteDataSource] is reachable. Since #125 both network
/// installers register the remote unconditionally — `registerServerNetwork`
/// and `registerServerNetworkWeb` alike — so **no shipping composition
/// reaches it**: a container that has a user tier has a network stack too.
/// What reaches it is a container assembled by hand without one, which in
/// practice means a test scope.
///
/// Note which case is *not* this one. A composition with the network stack
/// and no user tier — the storage-less web bootstrap, and either platform
/// between sign-outs — has the remote and no repository, and never calls
/// [install] at all.
///
/// The guard stays regardless: a throw here converges to a sign-out, so the
/// cost of being wrong about the above is a user who cannot sign in.
///
/// The hydrator swallows its own failures; the `unawaited` here is
/// deliberate rather than incidental, and `HydratePass` keeps it that way
/// even if that ever changes: it catches whatever a drain throws.
///
/// ## Publishing what the drain is doing (#269)
///
/// The outcome used to be discarded here, which left the household list
/// unable to tell an empty cache that is *filling* from one that is
/// *empty*, or a failed refresh from a successful one — `watchHouseholds()`
/// answers neither. So this registers a [HouseholdHydrationStatus] in the
/// session scope, and a `HydratePass` drives it around the drain.
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
///
/// ## What this decides (#302, #563)
///
/// `HydratePass` is the one place a drain is single-flighted, checked against
/// the session and registered to be re-run; its class doc gives the
/// reasoning. This installer decides only what is the household's:
///
/// - the pass is registered with the session's [SessionRehydrator] as
///   `'household'`, and again as a [HouseholdRefresher] for the retry on the
///   list's and detail screen's refresh banners (#300). It publishes no
///   second status — it drives the one the list is already watching, so the
///   banner clears with nothing added to any screen (#270);
/// - the window a `refreshed` pass ages out of is [staleAfter] (#300).
///   **This widens what every trigger does, deliberately** (#300): after
///   this an app resume or a connectivity edge finding a cache that refreshed
///   longer ago than the window re-drains it, not only the list's own entry
///   trigger;
/// - the hydrator is deliberately not registered. Nothing resolves one by
///   type and it holds no resources to dispose; the pass closes over it. The
///   drain is bounded by the scope anyway — once the session pops, the
///   repository it writes through is disposed and the next write ends the
///   pass.
///
/// An absent [SessionRehydrator] is a no-op, on the same reasoning as an
/// absent household client: a composition without the seam must still sign
/// in normally.
///
/// ## Whose session a pass reads as (#432)
///
/// The pass asks the [SessionIdentityGuard] once per drain, before its first
/// request, and the hydrator asks again before writing each page it reads;
/// this builds that per-page closure from the same guard. On web another tab
/// can move the shared cookie to another user under a tab still presenting
/// the first, and a pass read then would cache the other user's households as
/// this user's. A refused pass reads as `failed`, so the next trigger tries
/// again; by then the shell has usually switched users and this scope is
/// gone. No guard, as on native, is a confirmed session.
class HouseholdHydrateInstaller implements UserScopeInstaller {
  /// [now] overrides the clock the published [HouseholdHydrationStatus]
  /// stamps [staleAfter] against. Production leaves it null, which is the
  /// device clock; a test drives it so a five-minute window does not cost
  /// five real minutes.
  const HouseholdHydrateInstaller({this.now});

  /// How long a successful pass stays current (#300).
  ///
  /// Long enough that flipping between screens does not hit the network on
  /// every visit; short enough that "I fixed the server, let me go look"
  /// works without a restart.
  ///
  /// **Recorded as a guess rather than a measurement.** #300 put the figure
  /// in writing precisely so it would be cheaper to argue with than to
  /// reverse-engineer from a constant. If it turns out wrong, this is the
  /// one place it is wrong in.
  static const Duration staleAfter = Duration(minutes: 5);

  static final BgeLogger _log = BgeLogger('bge.household.hydrate.install');

  /// See the constructor. Null is the device clock.
  final DateTime Function()? now;

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    if (!container.isRegistered<HouseholdRemoteDataSource>()) {
      _log.debug(
        'No household client on this server; skipping hydrate',
        context: {'serverId': server.serverId},
      );
      return;
    }

    final guard = container.isRegistered<SessionIdentityGuard>()
        ? container.get<SessionIdentityGuard>()
        : null;

    final hydrator = HouseholdHydrator(
      repository: container.get<HouseholdRepository>(),
      remote: container.get<HouseholdRemoteDataSource>(),
      confirmSession: guard == null
          ? null
          : () async =>
                await guard.confirm(userId) == SessionConfirmation.confirmed,
    );

    final status = HouseholdHydrationStatus(now: now);
    container.registerSingleton<HouseholdHydrationStatus>(
      status,
      // Close-on-teardown, like the repositories this scope registers. A
      // pass still in flight then reports into a closed status, which
      // drops the update rather than throwing — see
      // [HouseholdHydrationStatus].
      dispose: (s) => s.close(),
    );

    final pass = HydratePass<HydrateOutcome>(
      feature: 'Household',
      drain: hydrator.hydrate,
      status: status,
      failed: HydrateOutcome.failed,
      userId: userId,
      logger: _log,
      guard: guard,
      context: {'serverId': server.serverId},
    );

    pass.registerRehydrate(container, 'household', staleAfter: staleAfter);

    // The same pass, reachable by the screens (#300). Registered rather
    // than routed through the [SessionRehydrator]: that seam skips an
    // entry a pass is already running for, which is right for a trigger and
    // wrong for a button someone is waiting on.
    container.registerSingleton<HouseholdRefresher>(
      HouseholdRefresher(pass.run, afterChange: pass.runAfterSettled),
    );

    // Unawaited, and the status is running before this returns: see the
    // class doc.
    unawaited(pass.run());
  }
}
