import 'dart:async';

import 'package:equatable/equatable.dart';

import 'household_hydrator.dart';

/// What the household hydrate is doing, as far as a screen needs to know
/// (#269 D1, #269 D2).
///
/// Deliberately coarser than [HydrateOutcome]: the drain's completeness
/// question ([HydrateOutcome.drained]) matters to a purge (#268), not
/// to a list. What a list needs is "is the cache still filling?" and "is
/// what you are reading possibly stale?".
enum HouseholdHydrationState {
  /// No pass has run. Also what an **absent** [HouseholdHydrationStatus]
  /// means to a reader — a container with no household client registers
  /// none, and that must render the empty state rather than an endless
  /// spinner. `HouseholdHydrateInstaller` records which compositions those
  /// are; since #125 no shipping one is among them.
  idle,

  /// A pass is in flight. An empty list under this state is unknown, not
  /// empty.
  running,

  /// The last pass landed rows. Includes a drained pass: the set is not one
  /// snapshot, but the cache is more current than it was, and crying
  /// "couldn't refresh" at every sign-in for a user with that many
  /// households, or for a server that sent a short page, would train the
  /// warning away.
  refreshed,

  /// The last pass ended early. The cache holds at least what it held
  /// before — safe to display, possibly stale.
  failed,
}

/// One reading of [HouseholdHydrationStatus]: what the hydrate is doing,
/// and what the passes before it established (#453).
///
/// The history travels with the state because a reader cannot rebuild it
/// from the changes it happens to see. A screen is often opened while a
/// pass is already running (entering the list starts one once the data is
/// stale, and resume, reconnect and the sign-in drain all start one), and
/// a replayed `running` on its own does not say whether an earlier pass
/// confirmed the answer or failed and left stale rows.
final class HouseholdHydration extends Equatable {
  /// The defaults are a status no pass has touched, which is also what an
  /// absent status means to a reader.
  const HouseholdHydration({
    this.state = HouseholdHydrationState.idle,
    this.everRefreshed = false,
    this.lastPassFailed = false,
  });

  /// What the hydrate is doing now.
  final HouseholdHydrationState state;

  /// Whether any pass has ever landed rows.
  ///
  /// Never goes back to false: a later failure does not un-know an answer
  /// a successful pass already gave us.
  ///
  /// **Not** set by a failed pass. A failure confirms nothing, so an empty
  /// cache only a failure has seen is still unknown, and a pass over it is
  /// #269's spinner (#300). "Ever settled" would have been the wrong
  /// predicate: it destroys that spinner for a first pass that failed and
  /// was retried.
  final bool everRefreshed;

  /// Whether the last pass to finish failed. A pass starting does not clear
  /// it: until one lands rows, the rows are still the ones that failure
  /// left.
  final bool lastPassFailed;

  @override
  List<Object?> get props => [state, everRefreshed, lastPassFailed];
}

/// The observable half of the household hydrate (#269 D1).
///
/// `HouseholdHydrator` reports its outcome in a return value, and until
/// this existed the installer discarded it — so a screen could not tell an
/// empty cache that is *filling* from one that is *empty*, and could not
/// tell a failed refresh from a successful one. `watchHouseholds()` cannot
/// answer either question: both are an empty list.
///
/// ## Who writes, who reads
///
/// [started] and [finished] belong to whoever runs the drain — today
/// `HouseholdHydrateInstaller`, on user-session scope activation. Screens
/// read [state] and [watch]. They are one class rather than a written
/// interface and a read interface because there is exactly one writer and
/// it lives one package away; a split would be ceremony around a single
/// call site.
///
/// [watch] delivers [HouseholdHydration] readings, which carry what earlier
/// passes established along with the state, so a screen that subscribes
/// mid-pass is replayed the history too (#453).
///
/// ## The staleness clock (#300 D8)
///
/// [isStaleAfter] is how the household list's re-hydrate-on-entry policy
/// (#300 D1) asks whether the cache has aged out; [sinceRefresh] is the
/// raw age behind it. The window is the caller's, so a composition can
/// pick its own, but the comparison lives here with the stamp and the
/// null-means-stale rule it depends on -- `StoredSession.isExpiredAt`
/// divides the same way. The timestamp lives
/// here rather than in the `SessionRehydrator`'s registry entry, which is
/// #302 D4's explicit constraint: a registry holding its own copy would
/// be a second answer free to drift from the one the screen reads.
///
/// The clock is an injected `DateTime Function()` — the shape
/// `ClockSkewInterceptor` and `AuthRepositoryImpl` already use — and not
/// `ClockService`. That service is per-server, skew-corrected, and its own
/// doc scopes it to **consensus-relevant** timestamps: tombstone ordering,
/// sync-queue bookkeeping. A staleness window is local elapsed time and
/// has no consensus meaning.
///
/// ## Writes after [close] are dropped, not thrown
///
/// This is the ordering that actually happens rather than a defensive
/// nicety. The drain is started **unawaited** (#267 D2), so a pass can
/// still be in flight when the session ends and the scope disposes this.
/// A `StateError` from a closed controller would surface as an unhandled
/// async error on the one path — sign-in — where a throw signs the user
/// out. So a closed status ignores updates.
class HouseholdHydrationStatus {
  /// [now] defaults to the device clock. Injected so a five-minute window
  /// is testable without waiting five real minutes.
  HouseholdHydrationStatus({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final StreamController<HouseholdHydration> _changes =
      StreamController<HouseholdHydration>.broadcast();

  final DateTime Function() _now;

  HouseholdHydration _current = const HouseholdHydration();

  /// When the last pass that landed rows landed them, or null when none
  /// has — including after [markStale].
  DateTime? _refreshedAt;

  /// Whether [markStale] has been called since the running pass started.
  ///
  /// A create that invalidates the set may reach the server *after* an
  /// in-flight pass has already read from it, so that pass's result
  /// cannot be treated as current. Without this, a create racing the
  /// install-time drain would be papered over for the whole window.
  ///
  /// Reset only when [_passes] goes from none to one, not when [started] is
  /// called again while a pass is out (#453). A later call may be handed
  /// the drain in flight, which is the one that was invalidated, or start
  /// a fresh drain after it, which is then conservatively left unstamped
  /// too; the cost of that is one more pass.
  bool _invalidated = false;

  /// How many [started] calls have yet to be [finished].
  ///
  /// The status reads running until all of them have. Each `pass()` calls
  /// [started] before it awaits the session guard, so two calls can
  /// overlap without sharing a drain: the second one's confirmation can
  /// come back after the first one's drain has settled, and it then starts
  /// a drain of its own. Ending the running state at the first [finished]
  /// would show a drain in flight as settled, and a [markStale] in that
  /// window would see nothing running and be forgiven by the next
  /// [started].
  int _passes = 0;

  bool _closed = false;

  /// The current state. [HouseholdHydrationState.idle] until a pass runs.
  HouseholdHydrationState get state => _current.state;

  /// How long since the last pass that landed rows, or null when none has.
  ///
  /// Null means "no rows to age": nothing has ever landed any, or
  /// [markStale] invalidated the set that did (#300 D9). Both want the same
  /// treatment from a staleness rule, which is what [isStaleAfter] gives
  /// them.
  ///
  /// A **failed** pass does not clear this. The rows on screen are still
  /// the ones the last success landed, and that is genuinely how old they
  /// are; a failure lands nothing, so it has nothing to date. What makes a
  /// failure stale is [state] — read first by every caller, and answered
  /// without consulting age at all.
  Duration? get sinceRefresh {
    final at = _refreshedAt;
    return at == null ? null : _now().difference(at);
  }

  /// Whether the last pass that landed rows is at least [window] old --
  /// the question a re-hydrate policy asks of this status (#300 D1, D2, D8).
  ///
  /// True whenever there is no age at all, for the reasons [sinceRefresh]
  /// gives: a status with no current answer has nothing to age, and every
  /// one of those cases wants another pass. That is what stops a create
  /// from waiting out the remaining minutes (#300 D9).
  ///
  /// Inclusive at the boundary: at exactly [window] the answer is already
  /// that many minutes old.
  ///
  /// A negative age is stale too (#453): the device clock went back past
  /// the stamp, so the real age is unknown. Read as fresh, it would let the
  /// entry, reconnect and resume triggers all skip the pass until the clock
  /// caught up; read as stale, it costs one pass, which stamps again.
  ///
  /// The age is wall-clock time even so, not a monotonic `Stopwatch`'s
  /// (#453). Dart's monotonic clock on Android is `CLOCK_MONOTONIC`, which
  /// stops while the device is suspended, so a phone left overnight would
  /// read as fresh.
  ///
  /// Deliberately says nothing about [state]. A pass in flight is reported
  /// against the age of the one before it, because what a running pass
  /// means to a trigger is the trigger's policy -- the installer's registry
  /// entry skips one (#302 D4) without asking about age at all. [window] is
  /// the caller's too: the duration is a composition's choice.
  bool isStaleAfter(Duration window) {
    final since = sinceRefresh;
    return since == null || since.isNegative || since >= window;
  }

  /// The current reading, then every change.
  ///
  /// The current value is delivered from `onListen`, in the same
  /// synchronous callback that subscribes to the change stream — so a
  /// change landing between "read the current value" and "start
  /// listening" cannot be lost. That window is real here: the pass this
  /// reports on is already running when a screen subscribes.
  Stream<HouseholdHydration> watch() {
    late final StreamController<HouseholdHydration> out;
    StreamSubscription<HouseholdHydration>? subscription;

    out = StreamController<HouseholdHydration>(
      onListen: () {
        out.add(_current);
        subscription = _changes.stream.listen(out.add, onDone: out.close);
      },
      onCancel: () => subscription?.cancel(),
    );

    return out.stream;
  }

  /// Marks a drain as in flight. What earlier passes established carries
  /// over.
  ///
  /// A start that arrives while a pass is already running joins it: the
  /// installer calls this on every pass it is asked for, and the hydrator
  /// hands the second caller the drain in flight, so a retry press can land
  /// mid-pass (#453). It is the same pass, and it read the set before the
  /// [markStale] that came since, so it must not forgive that call. Only a
  /// start with no other pass out resets the invalidation (see [_passes]).
  void started() {
    if (_passes++ == 0) _invalidated = false;
    _emit(
      HouseholdHydration(
        state: HouseholdHydrationState.running,
        everRefreshed: _current.everRefreshed,
        lastPassFailed: _current.lastPassFailed,
      ),
    );
  }

  /// Records how a drain ended, in the terms a screen reads.
  ///
  /// A pass that landed rows also stamps the staleness clock (#300 D8).
  /// The stamp happens **here rather than in [_emit]**, which drops a
  /// reading equal to the current one — a detail that would otherwise
  /// silently skip the stamp.
  ///
  /// A pass that [markStale] invalidated mid-flight still reads
  /// `refreshed`, sets [HouseholdHydration.everRefreshed] and clears
  /// [HouseholdHydration.lastPassFailed] (#453). It landed rows, so what it
  /// read is an answer a screen can show. It goes unstamped, because the
  /// change that invalidated the set may have reached the server after the
  /// pass read from it, so [isStaleAfter] keeps asking for another pass.
  ///
  /// Only the refreshed arm stamps. A failed pass lands no rows, so there
  /// is nothing new to date, and a stamp there would make a failure look
  /// like a success that has yet to age out.
  ///
  /// It does not *clear* the stamp either. After a success and then a
  /// failure the screen is still showing the successful pass's rows, and
  /// their age has not changed — so [sinceRefresh] keeps reporting it.
  /// Clearing it would be #300 D19's mistake moved from the latch to the
  /// clock: a failure un-knowing what a success established. `failed` is
  /// stale by state instead, which is how the installer's registry entry
  /// answers it.
  ///
  /// While another [started] call is still out, the reading keeps the
  /// running state and takes only this pass's history: the rows it landed
  /// are an answer a screen can show now, but the hydrate is not done.
  void finished(HydrateOutcome outcome) {
    if (_closed) return;

    if (_passes > 0) _passes--;
    final settled = _passes == 0;

    switch (outcome) {
      case HydrateOutcome.complete || HydrateOutcome.drained:
        if (!_invalidated) _refreshedAt = _now();
        _emit(
          HouseholdHydration(
            state: settled
                ? HouseholdHydrationState.refreshed
                : HouseholdHydrationState.running,
            everRefreshed: true,
          ),
        );
      case HydrateOutcome.failed:
        _emit(
          HouseholdHydration(
            state: settled
                ? HouseholdHydrationState.failed
                : HouseholdHydrationState.running,
            everRefreshed: _current.everRefreshed,
            lastPassFailed: true,
          ),
        );
    }
  }

  /// Declares the cached set no longer current, without claiming a pass is
  /// running (#300 D9).
  ///
  /// Called when a mutation makes the local set stale by definition — a
  /// create, a join (#455), and a member's role change or removal (#480).
  /// The last two call it through `refreshAfterMembershipChange`. The
  /// **state** is deliberately untouched: the rows on screen are still the
  /// rows we have, and only the claim that they are current goes away, so
  /// the next entry re-hydrates rather than waiting out the window.
  void markStale() {
    if (_closed) return;
    _refreshedAt = null;
    _invalidated = true;
  }

  void _emit(HouseholdHydration next) {
    if (_closed || next == _current) return;
    _current = next;
    _changes.add(next);
  }

  /// Releases the change stream. Idempotent; wired as the registration's
  /// `dispose:` callback so the session scope tears it down.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _changes.close();
  }
}

/// What a screen remembers about the hydrate, beyond its latest state
/// (#300 D16).
///
/// [HouseholdHydrationStatus] reports what is happening now. Two screens
/// need one thing more: whether a pass has **ever** reached
/// [HouseholdHydrationState.refreshed]. That is what turns an empty list
/// or an absent household from unverified into an answer — and once
/// re-checking a known answer is routine (#300 D1, D15), a re-check must
/// not un-render the screen that is already showing it.
///
/// One type rather than a latch in each bloc, because the rule has to hold
/// identically on both surfaces (#300 D12 binds them), and two copies of
/// one rule is what #165 cost.
class HouseholdHydrationMemory {
  HouseholdHydrationState _state = HouseholdHydrationState.idle;
  bool _everRefreshed = false;

  /// The latest state reported. Idle until a pass runs, which is also what
  /// an absent status means to a reader.
  HouseholdHydrationState get state => _state;

  /// Whether any pass has ever landed rows, by the rule
  /// [HouseholdHydration.everRefreshed] states.
  bool get everRefreshed => _everRefreshed;

  /// Records what the status now reports.
  void absorb(HouseholdHydrationState next) {
    _state = next;
    _everRefreshed |= next == HouseholdHydrationState.refreshed;
  }
}
