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
///
/// ## Registering to be re-run (#302 D2)
///
/// The install-time pass used to be the only one there would ever be: a
/// session that started while the server was unreachable never asked
/// again, and the user's only route back was signing out and in (#302).
/// So the hydrator is now kept and registered with the session's
/// [SessionRehydrator], which a later trigger drives.
///
/// ## The retry the screens call (#300 D5)
///
/// The same `pass()` is registered a second time, as a
/// [HouseholdRefresher], for the retry on the household list's and detail
/// screen's refresh banners. A press is not a trigger: it is not filtered
/// by staleness and it is not dropped while a pass is running, because
/// someone is waiting to see it do something. Overlap is safe because the
/// hydrator single-flights (#302 D3).
///
/// Two things this deliberately does not do. It does not decide **when** to
/// re-run — a connectivity edge and app resume live in the shell, and the
/// household feature learns nothing about either. And it does not publish a
/// second status: the re-run drives the same [HouseholdHydrationStatus] the
/// list is already watching, so the banner clears with nothing added to any
/// screen (#270 D5).
///
/// Staleness is answered from that same status rather than remembered by
/// the registry (#302 D4): `failed` or `idle` is worth another pass,
/// `running` is one already happening, and `refreshed` — including the
/// admin-scoped truncation, which updated the cache — is not, until it
/// ages out. A registry holding its own copy of that would be a second
/// answer free to drift from the one the screen reads.
///
/// ## The window a refreshed pass ages out of (#300 D1, D2, D8)
///
/// [staleAfter] is what lets a `refreshed` entry go stale at all. Without
/// it a session that hydrated once at sign-in never asked again however
/// long it ran, which is half of what #300 was filed for; the other half
/// is the manual retry above.
///
/// **This widens what every trigger does, deliberately** (#300 D15). The
/// registry consults this one closure, so after this an app resume or a
/// connectivity edge finding a cache that refreshed longer ago than the
/// window will re-drain it — not only the household list's own entry
/// trigger. #302 D4's actual constraint is intact: the registry still
/// holds no staleness state of its own, and the timestamp lives on the
/// status the screen reads.
///
/// A trigger that lands while a pass is `running` is therefore **dropped,
/// not queued**. Joining it would change nothing — the joined caller gets
/// the doomed pass's own outcome, not a fresh request — so the case worth
/// naming is a slow failure: a drain hanging on a socket timeout can
/// swallow the one connectivity edge the transport produces, and the list
/// stays at `failed` afterwards with nothing left to re-trigger it. That
/// is a failure-driven retry (#311), not something a staleness rule can
/// answer; #300's manual retry covers it in the meantime.
///
/// An absent [SessionRehydrator] is a no-op, on the same reasoning as an
/// absent household client: compositions without the seam (web until #137,
/// shell tests) must still sign in normally.
class HouseholdHydrateInstaller implements UserScopeInstaller {
  /// [now] overrides the clock the published [HouseholdHydrationStatus]
  /// stamps [staleAfter] against. Production leaves it null, which is the
  /// device clock; a test drives it so a five-minute window does not cost
  /// five real minutes.
  const HouseholdHydrateInstaller({this.now});

  /// How long a successful pass stays current (#300 D2).
  ///
  /// Long enough that flipping between screens does not hit the network on
  /// every visit; short enough that "I fixed the server, let me go look"
  /// works without a restart.
  ///
  /// **Recorded as a guess rather than a measurement.** D2 put the figure
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

    final status = HouseholdHydrationStatus(now: now);
    container.registerSingleton<HouseholdHydrationStatus>(
      status,
      // Close-on-teardown, like the repositories this scope registers. A
      // pass still in flight then reports into a closed status, which
      // drops the update rather than throwing — see
      // [HouseholdHydrationStatus].
      dispose: (s) => s.close(),
    );

    /// One pass: drive the status around the drain, and never throw.
    ///
    /// Shared by the install-time call below and every #302 re-run, so a
    /// triggered pass cannot report differently from the first one.
    Future<void> pass() async {
      status.started();
      final outcome = await hydrator.hydrate().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
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
      });
      status.finished(outcome);
    }

    _registerRehydrate(container, status, pass);

    // The same pass, reachable by the screens (#300 D5). Registered rather
    // than routed through the [SessionRehydrator]: that seam skips an
    // entry a pass is already running for (#302 D4), which is right for a
    // trigger and wrong for a button someone is waiting on.
    //
    // It closes over the same hydrator the rehydrate entry does, so its
    // single-flight guard (#302 D3) still means something — a second
    // instance would have its own.
    container.registerSingleton<HouseholdRefresher>(HouseholdRefresher(pass));

    // The hydrator itself is deliberately not registered: nothing resolves
    // one by type, and it holds no resources to dispose. The re-hydrate
    // entry above closes over it instead, which keeps its single-flight
    // guard (#302 D3) meaningful — a second instance would have its own.
    //
    // The drain is bounded by the scope anyway — once the session pops, the
    // repository it writes through is disposed and the next write ends the
    // pass.
    //
    // The #269 D1 window is unchanged by moving `status.started()` into
    // `pass()`: an async function body runs synchronously up to its first
    // await, so the status is running before this method returns — before
    // the drain's first turn, not inside it. A screen built in that window
    // must not read idle.
    unawaited(pass());
  }

  /// Registers the household drain as re-runnable for this session (#302).
  ///
  /// A composition without the seam is a no-op rather than a resolution
  /// failure, for the same reason a missing household client is: a throw
  /// here aborts activation, and the shell converges that to a sign-out.
  static void _registerRehydrate(
    DependencyContainer container,
    HouseholdHydrationStatus status,
    Future<void> Function() pass,
  ) {
    if (!container.isRegistered<SessionRehydrator>()) return;

    container.get<SessionRehydrator>().register(
      'household',
      isStale: () => switch (status.state) {
        HouseholdHydrationState.idle || HouseholdHydrationState.failed => true,
        HouseholdHydrationState.running => false,
        // The window is this composition's to choose; whether the stamp
        // has aged past it is the status's own question to answer
        // (#300 D8).
        HouseholdHydrationState.refreshed => status.isStaleAfter(staleAfter),
      },
      run: pass,
    );
  }
}
