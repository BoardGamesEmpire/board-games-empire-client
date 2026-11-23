import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:household/src/bloc/household_list_event.dart';
import 'package:household/src/bloc/household_list_state.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

/// Drives the household list (#269): the cached rows, plus what the hydrate is
/// doing to them.
///
/// ## Why a bloc and not a `StreamBuilder`
///
/// Two reasons, neither of them house style. The screen's state is a *function
/// of two streams* — the cache and the hydrate (#269) — and nesting one builder
/// inside another spreads that function across the widget tree. And the cache
/// stream ends in two ways that are not rows — an error (an unauthenticated
/// read) and a close (session teardown) — which a builder rendering `data`
/// alone drops on the floor, while a sealed state has somewhere to put both.
///
/// ## What the two sources mean together
///
/// | cache | hydrate | state |
/// |---|---|---|
/// | nothing yet | any | loading |
/// | empty | running, no pass ever completed | loading, not empty |
/// | empty | anything else | ready, no rows |
/// | rows | any | ready, never hidden |
/// | error | any | error, until the cache speaks again |
/// | ended, nothing read | any, now or later | error |
/// | ended, rows read | any | those rows, frozen |
///
/// Loading there means unknown, not empty. A populated cache is never
/// hidden. A cache that ended with nothing read answered nothing and
/// never will.
///
/// ## Two ways the cache stops
///
/// The session teardown path is a **close**, not an error: `WatchDisposal`
/// cancels the drift subscription and closes the vended stream, and
/// documents that subscribers see `onDone`. An error arrives only from the
/// narrower case the repository routes through the stream body — an
/// unauthenticated read in the window between authentication loss and the
/// scope pop.
///
/// Both are handled, and they are not the same event. A close with rows
/// already on screen freezes a snapshot that was true when it arrived and
/// lets the auth redirect pop the route; a close with nothing read has no
/// answer to show, and saying "no households" there would be a claim about
/// data nobody managed to read.
///
/// An **error is not terminal**, because the stream that raised it is not.
/// Drift adds a failed query's error to its listener and keeps the stream
/// open (`stream_queries.dart`), and neither `yield*` nor
/// `WatchDisposal.untilDisposed` ends on a forwarded error — so the next
/// table update delivers rows on the same subscription. Only fresh rows
/// clear the error state: a hydrate result is an annotation, not data, and
/// letting it lift the error would show a list nobody could read.
///
/// A **null** `hydration` stream means no hydrate exists to wait for
/// (a container with no household client, #125). That reads as settled,
/// not as perpetually loading.
///
/// ## The retry, and why the bloc runs it (#300)
///
/// A null `onRetry` is a composition that cannot re-run the drain — the
/// same #125 case that leaves `hydration` null — and the screen offers no
/// retry there rather than a button that does nothing.
///
/// The callback is invoked from here rather than straight from the button
/// because starting a pass and *saying* one is running are the same
/// event. The screen cannot know the difference between a pass it asked
/// for and one a #302 trigger started — both arrive as `running` on the
/// status stream — so the only place that distinction exists is the
/// handler that started it.
class HouseholdListBloc extends Bloc<HouseholdListEvent, HouseholdListState> {
  HouseholdListBloc({
    required HouseholdRepository repository,
    Stream<Hydration>? hydration,
    this._onRetry,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.list'),
       super(const HouseholdListLoading()) {
    on<HouseholdListCacheUpdated>(_onCacheUpdated);
    on<HouseholdListCacheFailed>(_onCacheFailed);
    on<HouseholdListCacheEnded>(_onCacheEnded);
    on<HouseholdListHydrationUpdated>(_onHydrationUpdated);
    on<HouseholdListRetryRequested>(_onRetryRequested);

    _cache = repository.watchHouseholds().listen(
      (households) => add(HouseholdListCacheUpdated(households)),
      onError: (Object error, StackTrace stackTrace) {
        // The narrower of the two endings: the repository resolves the
        // user id inside the stream body, so an unauthenticated read
        // arrives here rather than throwing at subscribe. Ordinary
        // teardown closes the stream instead — see onDone.
        _logger.warn(
          'Household list read failed',
          error: error,
          stackTrace: stackTrace,
        );
        add(const HouseholdListCacheFailed());
      },
      onDone: () => add(const HouseholdListCacheEnded()),
    );

    _hydrationUpdates = hydration?.listen(
      (reading) => add(HouseholdListHydrationUpdated(reading)),
      // Nothing errors this stream today. If something ever does, the
      // annotation is what is lost — not the list it annotates.
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Household hydration status stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  final BgeLogger _logger;

  /// Runs one hydrate pass, or null where this composition has none.
  final Future<void> Function()? _onRetry;

  late final StreamSubscription<List<Household>> _cache;
  StreamSubscription<Hydration>? _hydrationUpdates;

  /// Null until the cache has answered at all — which is not the same as
  /// having answered with nothing.
  List<Household>? _households;

  /// Set by a failed read, cleared by the next successful one. A cache that
  /// ends with nothing read sets it too, and nothing clears it then.
  bool _readFailed = false;

  /// What the hydrate last reported. The default is also what an absent
  /// hydrate means: idle, nothing confirmed, nothing failed.
  ///
  /// The status keeps the history, not this bloc (#453). The list is often
  /// opened while a pass is already running, and a bloc that remembered
  /// only the readings it saw would treat that pass as the first.
  /// [Hydration.everRefreshed] is what makes an empty list *confirmed*
  /// rather than merely unverified (#300).
  Hydration _hydration = const Hydration();

  /// Whether a pass **this screen asked for** is still running (#300).
  ///
  /// Not derived from the hydration state: `running` says a pass is in
  /// flight, not who started it.
  bool get _retrying => _inFlight != null;

  /// Ends when the pass this screen asked for ends, or null when none is
  /// running. Never completes with an error, so a request that joins it
  /// only waits (#314).
  Future<void>? _inFlight;

  void _onCacheUpdated(
    HouseholdListCacheUpdated event,
    Emitter<HouseholdListState> emit,
  ) {
    // Rows are the one thing that clears a failed read: they are proof the
    // stream recovered.
    _readFailed = false;
    _households = event.households;
    _emitDerived(emit);
  }

  void _onCacheFailed(
    HouseholdListCacheFailed event,
    Emitter<HouseholdListState> emit,
  ) {
    _readFailed = true;
    emit(HouseholdListError(refreshing: _retrying));
  }

  void _onCacheEnded(
    HouseholdListCacheEnded event,
    Emitter<HouseholdListState> emit,
  ) {
    // Rows already read stay up; the route is being popped around us.
    if (_households != null) return;
    // Nothing read at all is a spinner nobody will ever resolve. Held like
    // a failed read: a closed stream will never send the rows that would
    // clear it, so a later hydrate result must not lift it (#453).
    _readFailed = true;
    emit(HouseholdListError(refreshing: _retrying));
  }

  void _onHydrationUpdated(
    HouseholdListHydrationUpdated event,
    Emitter<HouseholdListState> emit,
  ) {
    _hydration = event.hydration;
    _emitDerived(emit);
  }

  Future<void> _onRetryRequested(
    HouseholdListRetryRequested event,
    Emitter<HouseholdListState> emit,
  ) async {
    try {
      await _retry(emit);
    } finally {
      // Never with an error: whatever the pass did, the spinner a pull
      // handed this to must end with it (#314).
      event.done?.complete();
    }
  }

  Future<void> _retry(Emitter<HouseholdListState> emit) async {
    final retry = _onRetry;
    if (retry == null) return;

    // Already running one: `HydratePass` single-flights (#302), so a second
    // call would join the drain in flight rather than duplicate it — but
    // the button should not queue passes either. A request made now waits
    // for that pass instead of returning at once, so a pull's spinner ends
    // with it (#314). This handler runs while the first is still awaiting
    // because the event takes bloc's default, concurrent transformer. It is
    // an exception to the rule that an operation handler takes
    // `droppable()` (CONTRIBUTING.md): `droppable()` would drop a joining
    // request unrun, so its `done` would never complete and the pull's
    // spinner would hang.
    final running = _inFlight;
    if (running != null) return running;

    final ended = Completer<void>();
    _inFlight = ended.future;
    _emitDerived(emit);

    try {
      await retry();
    } on Object catch (error, stackTrace) {
      // Unreachable by contract — the pass reports failure through the
      // status stream and swallows the rest (#267). Caught anyway: the
      // cost of being wrong is a stuck "refreshing" the user cannot
      // clear. Caught here, once, so a request waiting on [_inFlight]
      // never sees it.
      _logger.warn(
        'Household refresh escaped its own error handling',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _inFlight = null;
      ended.complete();
    }

    // The pass has reported its outcome to the status by now, but that
    // report reaches this bloc as a separate event, so this emit can land
    // first and still carry the failure the press set out to clear. Both
    // land in the same microtask drain, so no frame shows it.
    if (!isClosed) _emitDerived(emit);
  }

  void _emitDerived(Emitter<HouseholdListState> emit) {
    // Order matters below, and one ordering is load-bearing: the
    // empty-and-filling check outranks [_retrying]. A retry over an empty
    // list returns the screen to its spinner rather than annotating an
    // emptiness no pass has confirmed (#269) — see the screen doc.
    // Holds the error against everything except fresh rows — see the class
    // doc. In particular a hydrate result must not lift it.
    //
    // Every state carries [_retrying], not only the rows': it rides along
    // for the refresh button's label and changes none of the ordering
    // (#314).
    if (_readFailed) return emit(HouseholdListError(refreshing: _retrying));

    final households = _households;
    if (households == null) {
      return emit(HouseholdListLoading(refreshing: _retrying));
    }

    // "Filling" means the emptiness has never been confirmed, not merely
    // that a pass is running (#300). #269 exists to stop "no households
    // yet" rendering over a cache about to fill for the *first* time; once
    // a pass has landed `refreshed` the answer is known, and #300 makes
    // re-checking it routine — so re-confirming it must not un-render the
    // screen on every entry.
    final filling =
        households.isEmpty &&
        _hydration.state == HydrationState.running &&
        !_hydration.everRefreshed;
    if (filling) return emit(HouseholdListLoading(refreshing: _retrying));

    emit(
      HouseholdListReady(
        households: households,
        // The last pass to finish, not the current state: a pass starting
        // leaves the rows exactly as stale as the failure left them, so
        // only one that lands clears the banner (#453).
        refreshFailed: _hydration.lastPassFailed,
        refreshing: _retrying,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _cache.cancel();
    await _hydrationUpdates?.cancel();
    return super.close();
  }
}
