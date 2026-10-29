import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

import 'game_collection_list_event.dart';
import 'game_collection_list_state.dart';

/// Drives the collection list (#44): the cached rows, plus what the hydrate
/// is doing to them.
///
/// The household list's design (`HouseholdListBloc`), for the same reasons:
/// the screen's state is a function of two streams, and the cache stream
/// ends in two ways that are not rows.
///
/// | cache | hydrate | state |
/// |---|---|---|
/// | nothing yet | any | loading |
/// | empty | running, and no pass has ever completed | loading |
/// | empty | anything else | ready, no rows |
/// | rows | any | ready: a populated cache is never hidden |
/// | error | any | error, until the cache emits rows again |
/// | ended, nothing read | any | error: nothing answered, and nothing will |
/// | ended, rows read | any | those rows, frozen |
///
/// An error is not terminal: drift keeps a stream open after a failed
/// query, so the next table update delivers rows on the same subscription.
/// Only rows clear it; a hydrate result is an annotation, not data.
///
/// A null [hydration] stream means there is no hydrate to wait for, which
/// reads as settled rather than as loading forever.
///
/// ## A re-check is not a first fill
///
/// Entering the list runs a stale re-hydrate (#44), so a pass over an
/// answer the list already has is routine. "Empty and running" is loading
/// only until a pass has completed once; after that the emptiness is
/// confirmed, and re-checking it must not put the spinner back on every
/// entry. A failed pass confirms nothing. This is the household's #300
/// rule.
///
/// The status remembers which passes completed, not this bloc
/// ([Hydration]). The list is often opened while a pass is
/// already running, and a bloc that remembered only what it saw would treat
/// that pass as the first.
///
/// ## The warning outlasts the next pass
///
/// After a failed pass the banner stays up until a pass completes, not
/// until one starts: the rows are no fresher while the next one runs, and a
/// banner that vanished on start would take keyboard focus with it. A pass
/// nobody asked for is still not narrated (#300), so the banner keeps its
/// failed copy and its button.
///
/// ## The retry
///
/// The bloc calls [onRetry] rather than the button, because starting a pass
/// and saying one is running are the same event: the status stream reports
/// every pass as `running`, whoever started it.
class GameCollectionListBloc
    extends Bloc<GameCollectionListEvent, GameCollectionListState> {
  GameCollectionListBloc({
    required GameCollectionRepository repository,
    Stream<Hydration>? hydration,
    this._onRetry,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.collection.list'),
       super(const GameCollectionListLoading()) {
    on<GameCollectionListCacheUpdated>(_onCacheUpdated);
    on<GameCollectionListCacheFailed>(_onCacheFailed);
    on<GameCollectionListCacheEnded>(_onCacheEnded);
    on<GameCollectionListHydrationUpdated>(_onHydrationUpdated);
    on<GameCollectionListRetryRequested>(_onRetryRequested);

    _cache = repository.watchCollectionListItems().listen(
      (items) => add(GameCollectionListCacheUpdated(items)),
      onError: (Object error, StackTrace stackTrace) {
        _logger.warn(
          'Collection list read failed',
          error: error,
          stackTrace: stackTrace,
        );
        add(const GameCollectionListCacheFailed());
      },
      onDone: () => add(const GameCollectionListCacheEnded()),
    );

    _hydrationUpdates = hydration?.listen(
      (state) => add(GameCollectionListHydrationUpdated(state)),
      // Nothing errors this stream today. If something does, the annotation
      // is what is lost, not the list it annotates.
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Collection hydration status stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  final BgeLogger _logger;

  /// Runs one hydrate pass, or null where this composition has none.
  final Future<void> Function()? _onRetry;

  /// Whether a retry would run anything. Read by the list to decide whether
  /// to draw a button at all, so a host of the list cannot offer one this
  /// bloc would ignore.
  bool get canRetry => _onRetry != null;

  late final StreamSubscription<List<GameCollectionListItem>> _cache;
  StreamSubscription<Hydration>? _hydrationUpdates;

  /// Null until the cache has answered at all, which is not the same as
  /// having answered with nothing.
  List<GameCollectionListItem>? _items;

  /// Set by a failed read, cleared by the next rows.
  bool _readFailed = false;

  /// What the hydrate last reported. The default is also what an absent
  /// hydrate means: idle, nothing confirmed, nothing failed.
  Hydration _hydration = const Hydration();

  /// Whether a pass this screen asked for is still running.
  bool _retrying = false;

  void _onCacheUpdated(
    GameCollectionListCacheUpdated event,
    Emitter<GameCollectionListState> emit,
  ) {
    _readFailed = false;
    _items = event.items;
    _emitDerived(emit);
  }

  void _onCacheFailed(
    GameCollectionListCacheFailed event,
    Emitter<GameCollectionListState> emit,
  ) {
    _readFailed = true;
    emit(const GameCollectionListError());
  }

  void _onCacheEnded(
    GameCollectionListCacheEnded event,
    Emitter<GameCollectionListState> emit,
  ) {
    // Rows already read stay up while the auth redirect pops the route.
    if (_items != null) return;
    // Held like a failed read: a closed stream will never send the rows
    // that would clear it, so a later hydrate result must not lift it.
    _readFailed = true;
    emit(const GameCollectionListError());
  }

  void _onHydrationUpdated(
    GameCollectionListHydrationUpdated event,
    Emitter<GameCollectionListState> emit,
  ) {
    _hydration = event.hydration;
    _emitDerived(emit);
  }

  Future<void> _onRetryRequested(
    GameCollectionListRetryRequested event,
    Emitter<GameCollectionListState> emit,
  ) async {
    final retry = _onRetry;
    // The pass would join a second call rather than duplicate the
    // drain, but the button should not queue passes either.
    if (retry == null || _retrying) return;

    _retrying = true;
    _emitDerived(emit);

    try {
      await retry();
    } on Object catch (error, stackTrace) {
      // Unreachable by contract: the pass reports failure through the
      // status. Caught anyway, because the cost of being wrong is a stuck
      // "refreshing" the user cannot clear.
      _logger.warn(
        'Collection refresh escaped its own error handling',
        error: error,
        stackTrace: stackTrace,
      );
    }

    _retrying = false;
    if (!isClosed) _emitDerived(emit);
  }

  void _emitDerived(Emitter<GameCollectionListState> emit) {
    // Holds the error against everything except fresh rows.
    if (_readFailed) return emit(const GameCollectionListError());

    final items = _items;
    if (items == null) return emit(const GameCollectionListLoading());

    // Outranks [_retrying]: a retry over an unconfirmed empty list returns
    // to the spinner rather than annotating an emptiness no pass confirmed.
    final filling =
        items.isEmpty &&
        _hydration.state == HydrationState.running &&
        !_hydration.everRefreshed;
    if (filling) return emit(const GameCollectionListLoading());

    emit(
      GameCollectionListReady(
        items: items,
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
