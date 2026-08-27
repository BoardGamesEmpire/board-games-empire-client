import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

import '../sync/household_hydration_status.dart';
import 'household_list_event.dart';
import 'household_list_state.dart';

/// Drives the household list (#269 D6): the cached rows, plus what the
/// hydrate is doing to them.
///
/// ## Why a bloc and not a `StreamBuilder`
///
/// Two reasons, neither of them house style. The screen's state is a
/// *function of two streams* — the cache and the hydrate (#269 D1) — and
/// nesting one builder inside another spreads that function across the
/// widget tree. And the cache stream ends in two ways that are not rows —
/// an error (an unauthenticated read) and a close (session teardown) —
/// which a builder rendering `data` alone drops on the floor, while a
/// sealed state has somewhere to put both.
///
/// ## What the two sources mean together
///
/// | cache | hydrate | state |
/// |---|---|---|
/// | nothing yet | any | loading |
/// | empty | running | loading — unknown, not empty |
/// | empty | anything else | ready, no rows |
/// | rows | any | ready — a populated cache is never hidden |
/// | error | any | error, until the cache speaks again |
/// | ended, nothing read | any | error — nothing answered, and nothing will |
/// | ended, rows read | any | those rows, frozen |
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
/// A **null** [hydration] stream means no hydrate exists to wait for
/// (a container with no household client, #137). That reads as settled,
/// not as perpetually loading.
///
/// ## The retry, and why the bloc runs it (#300 D5)
///
/// A null [onRetry] is a composition that cannot re-run the drain — the
/// same #137 case that leaves [hydration] null — and the screen offers no
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
    Stream<HouseholdHydrationState>? hydration,
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

    _hydration = hydration?.listen(
      (state) => add(HouseholdListHydrationUpdated(state)),
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
  StreamSubscription<HouseholdHydrationState>? _hydration;

  /// Null until the cache has answered at all — which is not the same as
  /// having answered with nothing.
  List<Household>? _households;

  /// Set by a failed read, cleared by the next successful one.
  bool _readFailed = false;

  /// What the hydrate is doing, and whether it has ever confirmed an
  /// answer (#300 D16). Idle and unconfirmed until told otherwise, which
  /// is also what an absent hydrate means.
  ///
  /// [HouseholdHydrationMemory.everRefreshed] is what makes an empty list
  /// *confirmed* rather than merely unverified; the detail screen reads
  /// the same memory for the same reason.
  final HouseholdHydrationMemory _hydrationMemory = HouseholdHydrationMemory();

  /// Whether a pass **this screen asked for** is still running (#300 D6).
  ///
  /// Not derived from the hydration state: `running` says a pass is in
  /// flight, not who started it.
  bool _retrying = false;

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
    emit(const HouseholdListError());
  }

  void _onCacheEnded(
    HouseholdListCacheEnded event,
    Emitter<HouseholdListState> emit,
  ) {
    // Rows already read stay up; the route is being popped around us.
    // Nothing read at all is a spinner nobody will ever resolve.
    if (_households == null) emit(const HouseholdListError());
  }

  void _onHydrationUpdated(
    HouseholdListHydrationUpdated event,
    Emitter<HouseholdListState> emit,
  ) {
    _hydrationMemory.absorb(event.hydration);
    _emitDerived(emit);
  }

  Future<void> _onRetryRequested(
    HouseholdListRetryRequested event,
    Emitter<HouseholdListState> emit,
  ) async {
    final retry = _onRetry;
    // Already running one: the hydrator single-flights (#302 D3), so a
    // second call would join rather than duplicate the drain — but the
    // button should not queue passes either.
    if (retry == null || _retrying) return;

    _retrying = true;
    _emitDerived(emit);

    try {
      await retry();
    } on Object catch (error, stackTrace) {
      // Unreachable by contract — the pass reports failure through the
      // status stream and swallows the rest (#267). Caught anyway: the
      // cost of being wrong is a stuck "refreshing" the user cannot
      // clear.
      _logger.warn(
        'Household refresh escaped its own error handling',
        error: error,
        stackTrace: stackTrace,
      );
    }

    _retrying = false;
    // The pass has reported its outcome to the status by now, but that
    // report reaches this bloc as a separate event — so this emit may
    // land a turn before the banner comes back. That is a frame without
    // a banner, not a frame claiming success.
    if (!isClosed) _emitDerived(emit);
  }

  void _emitDerived(Emitter<HouseholdListState> emit) {
    // Order matters below, and one ordering is load-bearing: the
    // empty-and-filling check outranks [_retrying]. A retry over an empty
    // list returns the screen to its spinner rather than annotating an
    // emptiness no pass has confirmed (#269 D1) — see the screen doc.
    // Holds the error against everything except fresh rows — see the class
    // doc. In particular a hydrate result must not lift it.
    if (_readFailed) return emit(const HouseholdListError());

    final households = _households;
    if (households == null) return emit(const HouseholdListLoading());

    // "Filling" means the emptiness has never been confirmed, not merely
    // that a pass is running (#300 D16). #269 D1 exists to stop "no
    // households yet" rendering over a cache about to fill for the *first*
    // time; once a pass has landed `refreshed` the answer is known, and
    // #300 D1 makes re-checking it routine — so re-confirming it must not
    // un-render the screen on every entry.
    final filling =
        households.isEmpty &&
        _hydrationMemory.state == HouseholdHydrationState.running &&
        !_hydrationMemory.everRefreshed;
    if (filling) return emit(const HouseholdListLoading());

    emit(
      HouseholdListReady(
        households: households,
        refreshFailed: _hydrationMemory.state == HouseholdHydrationState.failed,
        refreshing: _retrying,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _cache.cancel();
    await _hydration?.cancel();
    return super.close();
  }
}
