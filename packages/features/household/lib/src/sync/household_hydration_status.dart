import 'dart:async';

import 'household_hydrator.dart';

/// What the household hydrate is doing, as far as a screen needs to know
/// (#269 D1, #269 D2).
///
/// Deliberately coarser than [HydrateOutcome]: the drain's completeness
/// question ([HydrateOutcome.adminScoped]) matters to a purge (#268), not
/// to a list. What a list needs is "is the cache still filling?" and "is
/// what you are reading possibly stale?".
enum HouseholdHydrationState {
  /// No pass has run. Also what an **absent** [HouseholdHydrationStatus]
  /// means to a reader — a container with no household client registers
  /// none (#137), and that must render the empty state rather than an
  /// endless spinner.
  idle,

  /// A pass is in flight. An empty list under this state is unknown, not
  /// empty.
  running,

  /// The last pass landed rows. Includes an admin-scoped truncation: the
  /// set is incomplete, but the cache is more current than it was, and
  /// crying "couldn't refresh" at every admin sign-in would train the
  /// warning away.
  refreshed,

  /// The last pass ended early. The cache holds at least what it held
  /// before — safe to display, possibly stale.
  failed,
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

  final StreamController<HouseholdHydrationState> _changes =
      StreamController<HouseholdHydrationState>.broadcast();

  final DateTime Function() _now;

  HouseholdHydrationState _state = HouseholdHydrationState.idle;

  /// When the last pass that landed rows landed them, or null when none
  /// has — including after [markStale].
  DateTime? _refreshedAt;

  /// Whether [markStale] has been called since the running pass started.
  ///
  /// A create that invalidates the set may reach the server *after* an
  /// in-flight pass has already read from it, so that pass's result
  /// cannot be treated as current. Without this, a create racing the
  /// install-time drain would be papered over for the whole window.
  bool _invalidated = false;

  bool _closed = false;

  /// The current state. [HouseholdHydrationState.idle] until a pass runs.
  HouseholdHydrationState get state => _state;

  /// How long since the last pass that landed rows, or null when none has.
  ///
  /// Null means "no current answer to age", which covers three cases that
  /// want the same treatment from a staleness rule: nothing has run, the
  /// last pass failed, and [markStale] invalidated the last success.
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
  /// Deliberately says nothing about [state]. A pass in flight is reported
  /// against the age of the one before it, because what a running pass
  /// means to a trigger is the trigger's policy -- the installer's registry
  /// entry skips one (#302 D4) without asking about age at all. [window] is
  /// the caller's too: the duration is a composition's choice.
  bool isStaleAfter(Duration window) {
    final since = sinceRefresh;
    return since == null || since >= window;
  }

  /// The current state, then every change.
  ///
  /// The current value is delivered from `onListen`, in the same
  /// synchronous callback that subscribes to the change stream — so a
  /// change landing between "read the current value" and "start
  /// listening" cannot be lost. That window is real here: the pass this
  /// reports on is already running when a screen subscribes.
  Stream<HouseholdHydrationState> watch() {
    late final StreamController<HouseholdHydrationState> out;
    StreamSubscription<HouseholdHydrationState>? subscription;

    out = StreamController<HouseholdHydrationState>(
      onListen: () {
        out.add(_state);
        subscription = _changes.stream.listen(out.add, onDone: out.close);
      },
      onCancel: () => subscription?.cancel(),
    );

    return out.stream;
  }

  /// Marks a drain as in flight.
  void started() {
    _invalidated = false;
    _emit(HouseholdHydrationState.running);
  }

  /// Records how a drain ended, in the terms a screen reads.
  ///
  /// A pass that landed rows also stamps the staleness clock (#300 D8).
  /// The stamp happens **here rather than in [_emit]**, which drops an
  /// update whose state is unchanged — a detail that would otherwise
  /// silently skip the stamp.
  ///
  /// Only the refreshed arm stamps. A failed pass leaves the clock null:
  /// `failed` is already stale by state, and a stamp there would make a
  /// failure look like a success that has yet to age out.
  void finished(HydrateOutcome outcome) {
    if (_closed) return;

    final next = switch (outcome) {
      HydrateOutcome.complete ||
      HydrateOutcome.adminScoped => HouseholdHydrationState.refreshed,
      HydrateOutcome.failed => HouseholdHydrationState.failed,
    };

    if (next == HouseholdHydrationState.refreshed && !_invalidated) {
      _refreshedAt = _now();
    }
    _emit(next);
  }

  /// Declares the cached set no longer current, without claiming a pass is
  /// running (#300 D9).
  ///
  /// Called when a mutation makes the local set stale by definition — a
  /// create today, and the #122 membership mutations when they land. The
  /// **state** is deliberately untouched: the rows on screen are still the
  /// rows we have, and only the claim that they are current goes away, so
  /// the next entry re-hydrates rather than waiting out the window.
  void markStale() {
    if (_closed) return;
    _refreshedAt = null;
    _invalidated = true;
  }

  void _emit(HouseholdHydrationState next) {
    if (_closed || next == _state) return;
    _state = next;
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

  /// Whether any pass has ever landed rows.
  ///
  /// Never goes back to false: a later failure does not un-know an answer
  /// a successful pass already gave us.
  ///
  /// **Not** set by a failed pass. A failure confirms nothing, so an empty
  /// cache only a failure has seen is still unknown, and a pass over it is
  /// #269 D1's spinner (#300 D12). "Ever settled" would have been the
  /// wrong predicate: it destroys that spinner for a first pass that
  /// failed and was retried.
  bool get everRefreshed => _everRefreshed;

  /// Records what the status now reports.
  void absorb(HouseholdHydrationState next) {
    _state = next;
    _everRefreshed |= next == HouseholdHydrationState.refreshed;
  }
}
