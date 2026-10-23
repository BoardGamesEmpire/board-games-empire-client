import 'dart:async';

import 'package:equatable/equatable.dart';

import 'event_hydrator.dart';

/// What the event hydrate is doing, as far as the event screens need to know
/// (#496).
///
/// The collection's states, for the collection's reasons
/// (`GameCollectionHydrationState`): a screen has to tell a cache that is
/// *filling* from one that is *empty*, and rows that are current from rows a
/// failed pass left behind.
enum EventHydrationState {
  /// No pass has run. Also what an **absent** [EventHydrationStatus] means to
  /// a reader: a container with no event client registers none, and that must
  /// render the empty state rather than an endless spinner.
  idle,

  /// A pass is in flight. An empty list under this state is unknown, not
  /// empty.
  running,

  /// The last pass cached every page the server sent: it ended
  /// [EventHydrateOutcome.complete], [EventHydrateOutcome.windowed] or
  /// [EventHydrateOutcome.drained]. See [EventHydrationStatus.finished] for
  /// why the last two count.
  refreshed,

  /// The last pass ended early. Every page it wrote stays, and so does any
  /// purge its page 1 already made: safe to display, possibly stale.
  failed,
}

/// One reading of [EventHydrationStatus]: what the hydrate is doing, and what
/// the passes before it established (#496).
///
/// The history travels with the state because a reader cannot rebuild it from
/// the changes it happens to see. A screen is often opened while a pass is
/// already running (entry, resume, reconnect and the sign-in drain all start
/// one), and a replayed `running` on its own does not say whether an earlier
/// pass confirmed the events or failed and left stale rows.
final class EventHydration extends Equatable {
  /// The defaults are a status no pass has touched, which is also what an
  /// absent status means to a reader.
  const EventHydration({
    this.state = EventHydrationState.idle,
    this.everRefreshed = false,
    this.lastPassFailed = false,
  });

  /// What the hydrate is doing now.
  final EventHydrationState state;

  /// Whether any pass has cached the list. Never goes back to false: a later
  /// failure does not undo what a success confirmed. A failed pass sets
  /// nothing, because it confirms nothing.
  final bool everRefreshed;

  /// Whether the last pass to finish failed. A pass starting does not clear
  /// it: until one completes, the rows are still the ones that failure left.
  final bool lastPassFailed;

  @override
  List<Object?> get props => [state, everRefreshed, lastPassFailed];
}

/// The observable half of the event hydrate (#496).
///
/// Modelled on `GameCollectionHydrationStatus`, and like it without the
/// household's `markStale`: nothing on the event screens invalidates the
/// cache, because #496 makes no writes. Each reading carries its history
/// ([EventHydration]), and [isStaleAfter] reads a clock that went backwards as
/// stale. #407 is where the copies would become one, and events are its third
/// consumer, after households and collections.
///
/// [started] and [finished] belong to `EventHydrateInstaller`'s pass. The
/// screens read [watch]; the installer's `SessionRehydrator` entry reads
/// [state] and [isStaleAfter], so the screen and the registry get one answer
/// to "is it stale?" rather than two that can drift (#302).
///
/// The clock is an injected `DateTime Function()`, as the household's is: a
/// staleness window is elapsed time on this device, with no consensus
/// meaning, so it is not `ClockService`'s. It is the wall clock rather than a
/// `Stopwatch` because Dart's monotonic clock stops while an Android device is
/// suspended, so a phone left overnight would read as fresh.
///
/// Writes after [close] are dropped, not thrown. The pass is started
/// unawaited, so one can still be in flight when the session ends and the
/// scope closes this; a throw there would be an unhandled async error.
class EventHydrationStatus {
  /// [now] defaults to the device clock. Injected so a five-minute window is
  /// testable without waiting five real minutes.
  EventHydrationStatus({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final StreamController<EventHydration> _changes =
      StreamController<EventHydration>.broadcast();

  final DateTime Function() _now;

  EventHydration _current = const EventHydration();

  /// When the last pass that cached the list ended, or null when none has.
  DateTime? _refreshedAt;

  bool _closed = false;

  /// The current state. [EventHydrationState.idle] until a pass runs.
  EventHydrationState get state => _current.state;

  /// How long since the last pass that cached the list, or null when none
  /// has.
  ///
  /// A failed pass does not clear this: the rows on screen are still the ones
  /// the last success landed, and that is how old they are. A failure is stale
  /// by [state] instead.
  Duration? get sinceRefresh {
    final at = _refreshedAt;
    return at == null ? null : _now().difference(at);
  }

  /// Whether the last pass that cached the list is at least [window] old, or
  /// none has.
  ///
  /// Inclusive at the boundary: at exactly [window] the answer is already that
  /// old. Says nothing about [state]; what a running or failed pass means is
  /// the caller's policy.
  ///
  /// A negative age is stale too: the device clock went back since the stamp,
  /// so the real age is unknown. Read as fresh, it would skip every trigger
  /// until the clock caught up; read as stale, it costs one pass, which stamps
  /// again.
  bool isStaleAfter(Duration window) {
    final since = sinceRefresh;
    return since == null || since.isNegative || since >= window;
  }

  /// The current reading, then every change.
  ///
  /// The current value is delivered from `onListen`, in the same callback that
  /// subscribes to the changes, so a change landing between the two cannot be
  /// lost. The pass this reports on is usually already running when a screen
  /// subscribes.
  Stream<EventHydration> watch() {
    late final StreamController<EventHydration> out;
    StreamSubscription<EventHydration>? subscription;

    out = StreamController<EventHydration>(
      onListen: () {
        out.add(_current);
        subscription = _changes.stream.listen(out.add, onDone: out.close);
      },
      onCancel: () => subscription?.cancel(),
    );

    return out.stream;
  }

  /// Marks a pass as in flight. What earlier passes established carries over.
  void started() => _emit(
    EventHydration(
      state: EventHydrationState.running,
      everRefreshed: _current.everRefreshed,
      lastPassFailed: _current.lastPassFailed,
    ),
  );

  /// Records how a pass ended. One that cached the list also stamps the
  /// staleness clock, here rather than in [_emit], which skips an unchanged
  /// reading.
  ///
  /// [EventHydrateOutcome.windowed] and [EventHydrateOutcome.drained] read as
  /// refreshed, like [EventHydrateOutcome.complete]. All three cached every
  /// page the server sent, and the screens show those rows. They differ only
  /// in how far the pass could vouch for an absence, so in what it removed.
  /// Reading either as failed would be wrong twice over. It would put a
  /// failure banner over rows that are current, and it would make every
  /// trigger drain the whole list again, since a failed status is always
  /// stale and a re-run cannot do better until the list itself changes. A
  /// user with more than one page of events would never read as refreshed.
  void finished(EventHydrateOutcome outcome) {
    if (_closed) return;

    switch (outcome) {
      case EventHydrateOutcome.complete ||
          EventHydrateOutcome.windowed ||
          EventHydrateOutcome.drained:
        _refreshedAt = _now();
        _emit(
          const EventHydration(
            state: EventHydrationState.refreshed,
            everRefreshed: true,
          ),
        );
      case EventHydrateOutcome.failed:
        _emit(
          EventHydration(
            state: EventHydrationState.failed,
            everRefreshed: _current.everRefreshed,
            lastPassFailed: true,
          ),
        );
    }
  }

  void _emit(EventHydration next) {
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
