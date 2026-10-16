import 'dart:async';

import 'package:equatable/equatable.dart';

import 'game_collection_hydrator.dart';

/// What the collection hydrate is doing, as far as the list needs to know
/// (#44).
///
/// The household's states, for the household's reasons
/// (`HouseholdHydrationState`): the list has to tell a cache that is
/// *filling* from one that is *empty*, and rows that are current from rows a
/// failed pass left behind.
enum GameCollectionHydrationState {
  /// No pass has run. Also what an **absent** [GameCollectionHydrationStatus]
  /// means to a reader: a container with no collection client registers
  /// none, and that must render the empty state rather than an endless
  /// spinner.
  idle,

  /// A pass is in flight. An empty list under this state is unknown, not
  /// empty.
  running,

  /// The last pass completed.
  refreshed,

  /// The last pass ended early. The cache holds at least what it held
  /// before: safe to display, possibly stale.
  failed,
}

/// One reading of [GameCollectionHydrationStatus]: what the hydrate is
/// doing, and what the passes before it established (#44).
///
/// The history travels with the state because a reader cannot rebuild it
/// from the changes it happens to see. The list is often opened while a
/// pass is already running (entry, resume, reconnect and the sign-in drain
/// all start one), and a replayed `running` on its own does not say whether
/// an earlier pass confirmed the collection or failed and left stale rows.
final class GameCollectionHydration extends Equatable {
  /// The defaults are a status no pass has touched, which is also what an
  /// absent status means to a reader.
  const GameCollectionHydration({
    this.state = GameCollectionHydrationState.idle,
    this.everRefreshed = false,
    this.lastPassFailed = false,
  });

  /// What the hydrate is doing now.
  final GameCollectionHydrationState state;

  /// Whether any pass has completed. Never goes back to false: a later
  /// failure does not undo what a success confirmed. A failed pass sets
  /// nothing, because it confirms nothing.
  final bool everRefreshed;

  /// Whether the last pass to finish failed. A pass starting does not clear
  /// it: until one completes, the rows are still the ones that failure left.
  final bool lastPassFailed;

  @override
  List<Object?> get props => [state, everRefreshed, lastPassFailed];
}

/// The observable half of the collection hydrate (#44).
///
/// Modelled on `HouseholdHydrationStatus`, less `markStale`: nothing on the
/// collection list invalidates the set, because an add (#45) writes to the
/// cache and the list's stream shows it without a pass. It differs in two
/// ways. Each reading carries its history ([GameCollectionHydration]), where
/// the household's screens rebuild theirs from the changes they see, and
/// [isStaleAfter] reads a clock that went backwards as stale. #407 is where
/// the two would become one.
///
/// [started] and [finished] belong to `GameCollectionHydrateInstaller`'s
/// pass. The list reads [watch]; the installer's `SessionRehydrator` entry
/// reads [state] and [isStaleAfter], so the screen and the registry get one
/// answer to "is it stale?" rather than two that can drift (#302).
///
/// The clock is an injected `DateTime Function()`, as the household's is: a
/// staleness window is elapsed time on this device, with no consensus
/// meaning, so it is not `ClockService`'s. It is the wall clock rather than
/// a `Stopwatch` because Dart's monotonic clock stops while an Android
/// device is suspended, so a phone left overnight would read as fresh.
///
/// Writes after [close] are dropped, not thrown. The drain is started
/// unawaited, so a pass can still be in flight when the session ends and
/// the scope closes this; a throw there would be an unhandled async error.
class GameCollectionHydrationStatus {
  /// [now] defaults to the device clock. Injected so a five-minute window
  /// is testable without waiting five real minutes.
  GameCollectionHydrationStatus({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final StreamController<GameCollectionHydration> _changes =
      StreamController<GameCollectionHydration>.broadcast();

  final DateTime Function() _now;

  GameCollectionHydration _current = const GameCollectionHydration();

  /// When the last completed pass completed, or null when none has.
  DateTime? _refreshedAt;

  bool _closed = false;

  /// The current state. [GameCollectionHydrationState.idle] until a pass
  /// runs.
  GameCollectionHydrationState get state => _current.state;

  /// How long since the last completed pass, or null when none has.
  ///
  /// A failed pass does not clear this: the rows on screen are still the
  /// ones the last success landed, and that is how old they are. A failure
  /// is stale by [state] instead.
  Duration? get sinceRefresh {
    final at = _refreshedAt;
    return at == null ? null : _now().difference(at);
  }

  /// Whether the last completed pass is at least [window] old, or no pass
  /// has completed.
  ///
  /// Inclusive at the boundary: at exactly [window] the answer is already
  /// that old. Says nothing about [state]; what a running or failed pass
  /// means is the caller's policy.
  ///
  /// A negative age is stale too: the device clock went back since the
  /// stamp, so the real age is unknown. Read as fresh, it would skip every
  /// trigger until the clock caught up; read as stale, it costs one pass,
  /// which stamps again.
  bool isStaleAfter(Duration window) {
    final since = sinceRefresh;
    return since == null || since.isNegative || since >= window;
  }

  /// The current reading, then every change.
  ///
  /// The current value is delivered from `onListen`, in the same callback
  /// that subscribes to the changes, so a change landing between the two
  /// cannot be lost. The pass this reports on is usually already running
  /// when the list subscribes.
  Stream<GameCollectionHydration> watch() {
    late final StreamController<GameCollectionHydration> out;
    StreamSubscription<GameCollectionHydration>? subscription;

    out = StreamController<GameCollectionHydration>(
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
  void started() => _emit(
    GameCollectionHydration(
      state: GameCollectionHydrationState.running,
      everRefreshed: _current.everRefreshed,
      lastPassFailed: _current.lastPassFailed,
    ),
  );

  /// Records how a drain ended. A completed pass also stamps the staleness
  /// clock, here rather than in [_emit], which skips an unchanged reading.
  void finished(CollectionHydrateOutcome outcome) {
    if (_closed) return;

    switch (outcome) {
      case CollectionHydrateOutcome.complete:
        _refreshedAt = _now();
        _emit(
          const GameCollectionHydration(
            state: GameCollectionHydrationState.refreshed,
            everRefreshed: true,
          ),
        );
      case CollectionHydrateOutcome.failed:
        _emit(
          GameCollectionHydration(
            state: GameCollectionHydrationState.failed,
            everRefreshed: _current.everRefreshed,
            lastPassFailed: true,
          ),
        );
    }
  }

  void _emit(GameCollectionHydration next) {
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
