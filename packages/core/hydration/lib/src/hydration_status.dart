import 'dart:async';

import 'package:equatable/equatable.dart';

/// What a feature's hydrate is doing, as far as a screen needs to know
/// (#269, #407).
///
/// Deliberately coarser than the feature's own outcome: whether a drain
/// was complete matters to a purge, not to a list. What a list needs is
/// "is the cache still filling?" and "is what you are reading possibly
/// stale?".
enum HydrationState {
  /// No pass has run. Also what an **absent** [HydrationStatus] means to a
  /// reader: a container with no client for the feature registers none,
  /// and that must render the empty state rather than an endless spinner.
  idle,

  /// A pass is in flight. An empty list under this state is unknown, not
  /// empty.
  running,

  /// The last pass landed rows. Includes a pass the feature counts as
  /// landed without being complete: the set is not one snapshot, but the
  /// cache is more current than it was, and crying "couldn't refresh" at
  /// every sign-in for a user with that many rows, or for a server that
  /// sent a short page, would train the warning away.
  refreshed,

  /// The last pass ended early. The cache holds at least what it held
  /// before — safe to display, possibly stale.
  failed,
}

/// One reading of [HydrationStatus]: what the hydrate is doing, and what
/// the passes before it established (#453).
///
/// The history travels with the state because a reader cannot rebuild it
/// from the changes it happens to see. A screen is often opened while a
/// pass is already running (entering the list starts one once the data is
/// stale, and resume, reconnect and the sign-in drain all start one), and
/// a replayed `running` on its own does not say whether an earlier pass
/// confirmed the answer or failed and left stale rows.
final class Hydration extends Equatable {
  /// The defaults are a status no pass has touched, which is also what an
  /// absent status means to a reader.
  const Hydration({
    this.state = HydrationState.idle,
    this.everRefreshed = false,
    this.lastPassFailed = false,
  });

  /// What the hydrate is doing now.
  final HydrationState state;

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

/// The observable half of a feature's hydrate (#269, #407).
///
/// A hydrator reports its outcome in a return value, and without this the
/// caller would discard it — so a screen could not tell an empty cache that
/// is *filling* from one that is *empty*, and could not tell a failed
/// refresh from a successful one. The feature's `watch` stream cannot
/// answer either question: both are an empty list.
///
/// It is generic over the feature's outcome type [O] and never names a
/// feature. [landed] is the feature's own answer to "did this outcome put
/// rows in the cache?", which is the only thing this class asks of it.
///
/// ## Who writes, who reads
///
/// [started] and [finished] belong to whoever runs the drain — `HydratePass`.
/// Screens read [state] and [watch]. They are one class rather than a
/// written interface and a read interface because there is exactly one
/// writer; a split would be ceremony around a single call site.
///
/// [watch] delivers [Hydration] readings, which carry what earlier passes
/// established along with the state, so a screen that subscribes mid-pass
/// is replayed the history too (#453).
///
/// [started] is called once per drain by `HydratePass`. A call that joins a
/// drain already running doesn't touch the status, so a [markStale] made
/// during a drain holds until the next drain starts (#407).
///
/// ## The staleness clock (#300)
///
/// [isStaleAfter] is how a list's re-hydrate-on-entry policy asks whether
/// the cache has aged out; [sinceRefresh] is the raw age behind it. The
/// window is the caller's, so a composition can pick its own, but the
/// comparison lives here with the stamp and the null-means-stale rule it
/// depends on — `StoredSession.isExpiredAt` divides the same way. The
/// timestamp lives here rather than in the `SessionRehydrator`'s registry
/// entry, which is #302's explicit constraint: a registry holding its own
/// copy would be a second answer free to drift from the one the screen
/// reads.
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
/// nicety. The drain is started **unawaited** (#267), so a pass can still
/// be in flight when the session ends and the scope disposes this. A
/// `StateError` from a closed controller would surface as an unhandled
/// async error on the one path — sign-in — where a throw signs the user
/// out. So a closed status ignores updates.
class HydrationStatus<O extends Object> {
  /// [landed] says whether an outcome put rows in the cache. [now] defaults
  /// to the device clock. Injected so a five-minute window is testable
  /// without waiting five real minutes.
  HydrationStatus({required this._landed, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final bool Function(O outcome) _landed;

  final StreamController<Hydration> _changes =
      StreamController<Hydration>.broadcast();

  final DateTime Function() _now;

  Hydration _current = const Hydration();

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
  /// Reset by every [started]: one call is one drain, so a drain started
  /// after the [markStale] reads the set after the change and may stamp.
  bool _invalidated = false;

  bool _closed = false;

  /// The current state. [HydrationState.idle] until a pass runs.
  HydrationState get state => _current.state;

  /// How long since the last pass that landed rows, or null when none has.
  ///
  /// Null means "no rows to age": nothing has ever landed any, or
  /// [markStale] invalidated the set that did (#300). Both want the same
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

  /// Whether the last pass that landed rows is at least [window] old —
  /// the question a re-hydrate policy asks of this status (#300).
  ///
  /// True whenever there is no age at all, for the reasons [sinceRefresh]
  /// gives: a status with no current answer has nothing to age, and every
  /// one of those cases wants another pass. That is what stops a create
  /// from waiting out the remaining minutes (#300).
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
  /// means to a trigger is the trigger's policy —
  /// `HydratePass.registerRehydrate` skips one (#302) without asking about age
  /// at all. [window] is the caller's too: the duration is a composition's
  /// choice.
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
  Stream<Hydration> watch() {
    late final StreamController<Hydration> out;
    StreamSubscription<Hydration>? subscription;

    out = StreamController<Hydration>(
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
  /// Clears any [markStale] made before it: a drain that starts now reads
  /// the set after that change, so its result may be stamped.
  void started() {
    _invalidated = false;
    _emit(
      Hydration(
        state: HydrationState.running,
        everRefreshed: _current.everRefreshed,
        lastPassFailed: _current.lastPassFailed,
      ),
    );
  }

  /// Records how a drain ended, in the terms a screen reads.
  ///
  /// A pass that landed rows also stamps the staleness clock (#300). The
  /// stamp happens **here rather than in [_emit]**, which drops a reading
  /// equal to the current one — a detail that would otherwise silently
  /// skip the stamp.
  ///
  /// A pass that [markStale] invalidated mid-flight still reads
  /// `refreshed`, sets [Hydration.everRefreshed] and clears
  /// [Hydration.lastPassFailed] (#453). It landed rows, so what it read is
  /// an answer a screen can show. It goes unstamped, because the change
  /// that invalidated the set may have reached the server after the pass
  /// read from it, so [isStaleAfter] keeps asking for another pass.
  ///
  /// Only the refreshed arm stamps. A failed pass lands no rows, so there
  /// is nothing new to date, and a stamp there would make a failure look
  /// like a success that has yet to age out.
  ///
  /// It does not *clear* the stamp either. After a success and then a
  /// failure the screen is still showing the successful pass's rows, and
  /// their age has not changed — so [sinceRefresh] keeps reporting it.
  /// Clearing it would be #300's mistake moved from the latch to the
  /// clock: a failure un-knowing what a success established. `failed` is
  /// stale by state instead, which is how `HydratePass.registerRehydrate`
  /// answers it.
  void finished(O outcome) {
    if (_closed) return;

    if (_landed(outcome)) {
      if (!_invalidated) _refreshedAt = _now();
      _emit(
        const Hydration(state: HydrationState.refreshed, everRefreshed: true),
      );
    } else {
      _emit(
        Hydration(
          state: HydrationState.failed,
          everRefreshed: _current.everRefreshed,
          lastPassFailed: true,
        ),
      );
    }
  }

  /// Declares the cached set no longer current, without claiming a pass is
  /// running (#300).
  ///
  /// Called when a mutation makes the local set stale by definition: the
  /// rows we hold predate it, however recently they landed. It holds until
  /// the next drain starts. The **state** is deliberately untouched: the
  /// rows on screen are still the rows we have, and only the claim that
  /// they are current goes away, so the next entry re-hydrates rather than
  /// waiting out the window.
  void markStale() {
    if (_closed) return;
    _refreshedAt = null;
    _invalidated = true;
  }

  void _emit(Hydration next) {
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
