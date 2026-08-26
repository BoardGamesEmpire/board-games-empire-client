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
class HouseholdListBloc extends Bloc<HouseholdListEvent, HouseholdListState> {
  HouseholdListBloc({
    required HouseholdRepository repository,
    Stream<HouseholdHydrationState>? hydration,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.list'),
       super(const HouseholdListLoading()) {
    on<HouseholdListCacheUpdated>(_onCacheUpdated);
    on<HouseholdListCacheFailed>(_onCacheFailed);
    on<HouseholdListCacheEnded>(_onCacheEnded);
    on<HouseholdListHydrationUpdated>(_onHydrationUpdated);

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

  late final StreamSubscription<List<Household>> _cache;
  StreamSubscription<HouseholdHydrationState>? _hydration;

  /// Null until the cache has answered at all — which is not the same as
  /// having answered with nothing.
  List<Household>? _households;

  /// Set by a failed read, cleared by the next successful one.
  bool _readFailed = false;

  /// Idle until told otherwise, which is also what an absent hydrate
  /// means.
  HouseholdHydrationState _hydrationState = HouseholdHydrationState.idle;

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
    _hydrationState = event.hydration;
    _emitDerived(emit);
  }

  void _emitDerived(Emitter<HouseholdListState> emit) {
    // Holds the error against everything except fresh rows — see the class
    // doc. In particular a hydrate result must not lift it.
    if (_readFailed) return emit(const HouseholdListError());

    final households = _households;
    if (households == null) return emit(const HouseholdListLoading());

    final filling =
        households.isEmpty &&
        _hydrationState == HouseholdHydrationState.running;
    if (filling) return emit(const HouseholdListLoading());

    emit(
      HouseholdListReady(
        households: households,
        refreshFailed: _hydrationState == HouseholdHydrationState.failed,
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
