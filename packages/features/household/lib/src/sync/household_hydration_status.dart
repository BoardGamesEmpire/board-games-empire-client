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
/// ## Writes after [close] are dropped, not thrown
///
/// This is the ordering that actually happens rather than a defensive
/// nicety. The drain is started **unawaited** (#267 D2), so a pass can
/// still be in flight when the session ends and the scope disposes this.
/// A `StateError` from a closed controller would surface as an unhandled
/// async error on the one path — sign-in — where a throw signs the user
/// out. So a closed status ignores updates.
class HouseholdHydrationStatus {
  HouseholdHydrationStatus();

  final StreamController<HouseholdHydrationState> _changes =
      StreamController<HouseholdHydrationState>.broadcast();

  HouseholdHydrationState _state = HouseholdHydrationState.idle;
  bool _closed = false;

  /// The current state. [HouseholdHydrationState.idle] until a pass runs.
  HouseholdHydrationState get state => _state;

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
  void started() => _emit(HouseholdHydrationState.running);

  /// Records how a drain ended, in the terms a screen reads.
  void finished(HydrateOutcome outcome) => _emit(switch (outcome) {
    HydrateOutcome.complete ||
    HydrateOutcome.adminScoped => HouseholdHydrationState.refreshed,
    HydrateOutcome.failed => HouseholdHydrationState.failed,
  });

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
