import 'package:hydration/hydration.dart';
import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';

import 'household_events_hydrator.dart';

/// One household's pass and the status a screen reads it by.
typedef _HouseholdPass = ({
  HydrationStatus<HouseholdEventsOutcome> status,
  HydratePass<HouseholdEventsOutcome> pass,
});

/// The household events passes of one session: one per household, for the
/// household screen that lists a household's events from the cache (#503).
///
/// `EventHydrateInstaller` registers one in the user's session scope, which
/// closes it when the session ends.
///
/// ## Read on open, not in the hydrate
///
/// It is **not** registered with the `SessionRehydrator`, and nothing runs a
/// pass at sign-in. Only the household screen reads: its open and its retry
/// call [refresh], and its coming back into view calls [refreshAfterChange].
/// A hydrate would read every household's events at each sign-in,
/// one call per household, for a screen the user may never open, and the
/// rehydrator's triggers would re-read households nobody is looking at.
/// Offline, the screen shows what is cached.
///
/// ## One pass and one status per household
///
/// Each household gets its own `HydratePass` and [HydrationStatus], made the
/// first time [watch] or [refresh] names it and kept until [close]. The pass
/// runs one drain at a time, so a [refresh] while that household's pass runs
/// joins it, which is what a retry pressed during the open's pass wants.
/// [refreshAfterChange] waits that pass out and runs another instead: the
/// running one may have read the list before the change the caller has just
/// seen made, such as an event created from the screen. Two households' passes run side by side: each purges only its own
/// household's rows. And each status is its household's own, so a failure on
/// one household's screen never reads as another's.
///
/// Every outcome but [HouseholdEventsOutcome.failed] reads as refreshed. A
/// drained pass cached every page it was sent, and a household found missing
/// lists nothing: its section empties when the 404 came on page 1, and keeps
/// the rows an earlier page wrote until the next pass when it came later.
///
/// The pass asks the session's guard before it starts, and the hydrator asks
/// again before writing each answer, for the reason `EventHydrateInstaller`
/// gives. A refused pass reads as failed, so the screen offers its retry.
///
/// ## After [close]
///
/// [refresh] and [refreshAfterChange] run nothing and return, and [watch] delivers the household's
/// last reading, idle for one it never named, and ends: what a closed
/// [HydrationStatus] gives a new watcher. No status is made after close, so
/// none is left open. A pass still in flight at close reports into its
/// closed status, which drops the update, and a [refreshAfterChange] waiting
/// it out starts no other.
class HouseholdEventsSync {
  /// [userId] is the session's user, whom [guard] is asked about; no guard,
  /// as on native, is a confirmed session. [now] is the statuses' clock, the
  /// device's when null.
  HouseholdEventsSync({
    required this._hydrator,
    required this._userId,
    this._guard,
    this._now,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.events.household.sync');

  final HouseholdEventsHydrator _hydrator;
  final String _userId;
  final SessionIdentityGuard? _guard;
  final DateTime Function()? _now;
  final BgeLogger _logger;

  final Map<String, _HouseholdPass> _passes = {};

  bool _closed = false;

  /// [householdId]'s current reading, then every change, as
  /// [HydrationStatus.watch] gives them. Idle until its first [refresh].
  Stream<Hydration> watch(String householdId) {
    if (_closed) {
      return _passes[householdId]?.status.watch() ??
          Stream.value(const Hydration());
    }
    return _passFor(householdId).status.watch();
  }

  /// Runs a pass over [householdId], or joins the one running, and completes
  /// when it ends. Never throws: the pass reports failure through the
  /// household's status.
  ///
  /// The status reads running before this returns, so a screen that calls it
  /// unawaited and builds at once does not read idle.
  Future<void> refresh(String householdId) async {
    if (_closed) return;
    await _passFor(householdId).pass.run();
  }

  /// Runs a pass over [householdId] that starts after this call, waiting out
  /// the one running, and completes when it ends. Never throws.
  ///
  /// For the household screen coming back into view (#503): [refresh] would
  /// join a pass begun before the user left it, whose answer may predate an
  /// event they made meanwhile, and that pass landing would leave the event
  /// out with no retry to press.
  ///
  /// A [close] while it waits starts nothing after the wait: the session's
  /// reads are over, so it returns once the running pass ends.
  Future<void> refreshAfterChange(String householdId) async {
    if (_closed) return;
    // `settled` then `run` rather than `runAfterSettled`, so the close
    // check can sit between the two.
    final pass = _passFor(householdId).pass;
    await pass.settled;
    if (_closed) return;
    await pass.run();
  }

  /// Closes every household's status. Idempotent; wired as the registration's
  /// `dispose:` callback so the session scope tears it down.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait([for (final held in _passes.values) held.status.close()]);
  }

  _HouseholdPass _passFor(String householdId) =>
      _passes.putIfAbsent(householdId, () {
        final status = HydrationStatus<HouseholdEventsOutcome>(
          landed: (outcome) => switch (outcome) {
            HouseholdEventsOutcome.complete ||
            HouseholdEventsOutcome.drained ||
            HouseholdEventsOutcome.notFound => true,
            HouseholdEventsOutcome.failed => false,
          },
          now: _now,
        );
        return (
          status: status,
          pass: HydratePass<HouseholdEventsOutcome>(
            feature: 'Household events',
            drain: () => _hydrator.hydrate(householdId),
            status: status,
            failed: HouseholdEventsOutcome.failed,
            userId: _userId,
            logger: _logger,
            guard: _guard,
            context: {'householdId': householdId},
          ),
        );
      });
}
