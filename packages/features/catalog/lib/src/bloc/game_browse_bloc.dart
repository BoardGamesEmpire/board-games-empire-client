import 'dart:async';

import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/src/bloc/game_browse_event.dart';
import 'package:game_catalog/src/bloc/game_browse_state.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Drives the browse screen (#42): the server's catalog, a page at a time.
///
/// ## Online, every page is cached
///
/// Each page `GET /games` returns is written to the games cache
/// ([GameRepository.cacheGames]) before it is shown, so the catalog the
/// user has paged through is there offline. A failed write is logged and
/// otherwise ignored: the page is still the server's answer.
///
/// Nothing is written once the list has closed: it no longer hears of a game
/// found gone, so a page answered after that could make one readable again.
///
/// A page that repeats a game already shown is not shown twice. The catalog
/// is a live list, so a game added mid-browse pushes the rows after it back
/// one. By title that is the rows after its title; newest first, where it
/// lands at the top, every row.
///
/// ## The order (#615)
///
/// The list is read by title, or newest first ([GameSort]). It starts in
/// `initialSort`, and [GameBrowseSortChanged] reads it again from the first
/// page in another. The choice is this bloc's alone: nothing keeps it for the
/// next screen.
///
/// ## The deepest page
///
/// The server refuses a page that starts past
/// [GamesRemoteDataSource.maxDepth] rows, so the list ends there, whatever
/// `hasMore` says. Search reaches the rest.
///
/// ## When the server refuses
///
/// A 403 says this user may not read the server's games at all: the route
/// checks that before it reads a row. So the screen says so,
/// [GameBrowseDenied], rather than showing the cache: the server's answer
/// wins over an old copy, as it does on the detail. A later page refused
/// takes down the pages already shown, for the same reason. The refusal also
/// forgets this user's catalog on this device, so offline browse and search
/// show only the games their collection reaches (#557). A failed forget is
/// logged and otherwise ignored.
///
/// ## When the server fails, the cache in the order asked for
///
/// When the first page cannot be fetched, for any other reason, the screen
/// shows the games cached on this device instead, read a page at a time in
/// the order asked for ([GameRepository.getGamesPage]), as
/// [GameBrowseReady.fromCache]. "More" then reads the cache's next page.
///
/// A retry asks the server for its first page again, and keeps the rows
/// already shown up while it asks ([GameBrowseReady.retrying]). One that
/// fails leaves them as they were, every page of them, rather than reading
/// the cache again from the top.
///
/// It never falls back on a page the server did answer: an empty catalog is
/// an empty catalog, whatever the cache holds.
///
/// ## A game found gone
///
/// A game that the server no longer has, or this user may no longer read,
/// is taken down when [gone] says so, wherever it was found: from this list,
/// or from a search opened over it. The rest of the list stays as it was.
/// Read from the cache, the next page then starts where it should: the game
/// is gone from the cache, too.
///
/// It stays down while this screen is open. A page already on its way when
/// it went can repeat it, and neither shows it nor caches it again: the
/// detail forgot it, and caching it would undo that.
///
/// ## One read at a time
///
/// A read is dropped while another is running (`droppable()`), so a scroll
/// that asks for more twice reads one page, not two. A game found gone is
/// not a read: it is taken down at once, even while a page loads.
///
/// Nor is a sort change: it would be dropped behind the read it means to
/// replace, so it replaces it. The read already out is not waited for, and
/// whatever it answers or fails with later is ignored: not shown, not
/// cached, and a refusal in it does not forget the catalog. The new read
/// hears a refusal for itself. Waiting would hold the slot reads are dropped
/// from until a slow server answered, and the new list's next page, or its
/// retry, would do nothing until then.
class GameBrowseBloc extends Bloc<GameBrowseEvent, GameBrowseState> {
  GameBrowseBloc({
    required this._remote,
    this._cache,
    Stream<String>? gone,
    GameSort initialSort = GameSort.title,
    this.pageSize = defaultPageSize,
    BgeLogger? logger,
  }) : _sort = initialSort,
       _logger = logger ?? BgeLogger('bge.catalog.browse'),
       super(GameBrowseLoading(sort: initialSort)) {
    on<GameBrowseRead>(
      (event, emit) => switch (event) {
        GameBrowseLoadRequested() => _load(
          emit,
          retrying: state is GameBrowseReady,
        ),
        GameBrowseMoreRequested() => _loadMore(emit),
      },
      transformer: droppable(),
    );
    on<GameBrowseSortChanged>(
      _onSortChanged,
      // The sort being read already is not a change, and must not restart
      // its own read. The handler sets [_sort] before it first waits, so this
      // sees the last one asked for.
      transformer: (events, mapper) => restartable<GameBrowseSortChanged>()(
        events.where((event) => event.sort != _sort),
        mapper,
      ),
    );
    on<GameBrowseGameGone>(_onGameGone);
    _goneSubscription = gone?.listen((id) => add(GameBrowseGameGone(id)));
  }

  /// Games a page, online and offline alike.
  static const int defaultPageSize = 50;

  final int pageSize;
  final GamesRemoteDataSource _remote;
  final GameRepository? _cache;
  final BgeLogger _logger;

  /// The order the list is read in: [initialSort], then each change.
  GameSort _sort;

  /// Completes when the sort changes, and the new sort gets a new one. A read
  /// keeps the one it began under: once it is complete, what the read finds
  /// is of another order and must not show, be cached or forget anything.
  /// While it is not, [_sort] is the read's own.
  Completer<void> _epoch = Completer<void>();

  List<Game> _games = const [];
  bool _hasMore = false;
  bool _fromCache = false;

  /// The server's next page, while online.
  int _nextPage = 1;

  /// Games found gone since this screen opened, never shown again.
  final Set<String> _gone = {};
  StreamSubscription<String>? _goneSubscription;

  @override
  Future<void> close() async {
    await _goneSubscription?.cancel();
    return super.close();
  }

  /// Reads the catalog's first page again in the new order.
  ///
  /// Ends every read begun before it ([_epoch]), whatever the sort of them,
  /// and starts over: the pages shown were of another order.
  Future<void> _onSortChanged(
    GameBrowseSortChanged event,
    Emitter<GameBrowseState> emit,
  ) {
    _sort = event.sort;
    _epoch.complete();
    _epoch = Completer<void>();
    _games = const [];
    _hasMore = false;
    _fromCache = false;
    _nextPage = 1;
    return _load(emit, retrying: false);
  }

  Future<void> _load(
    Emitter<GameBrowseState> emit, {
    required bool retrying,
  }) async {
    final epoch = _epoch;
    if (retrying) {
      _emitReady(emit, retrying: true);
    } else {
      emit(GameBrowseLoading(sort: _sort));
    }

    final PaginatedResult<Game>? page;
    try {
      page = await _fetch(epoch, page: 1);
    } on GamesForbiddenException {
      if (epoch.isCompleted) return;
      await _forgetCatalog();
      if (_ended(epoch)) return;
      _games = const [];
      return emit(GameBrowseDenied(sort: _sort));
    } on Object catch (error, stackTrace) {
      if (epoch.isCompleted) return;
      _logger.warn(
        'Game catalog read failed',
        error: error,
        stackTrace: stackTrace,
      );
      // A failed retry leaves the rows shown as they were.
      if (retrying) return _emitReady(emit);
      return _loadFromCache(emit, epoch);
    }

    if (page == null || _ended(epoch)) return;
    await _write(page.items);
    if (_ended(epoch)) return;
    _games = [];
    _append(page.items);
    _fromCache = false;
    _nextPage = 2;
    _hasMore = page.meta.hasMore && _served(_nextPage);
    _emitReady(emit);
  }

  Future<void> _loadFromCache(
    Emitter<GameBrowseState> emit,
    Completer<void> epoch,
  ) async {
    final rows = await _readCache(offset: 0);
    if (_ended(epoch)) return;
    if (rows == null || rows.isEmpty) {
      _games = const [];
      return emit(GameBrowseFailed(sort: _sort));
    }
    _games = [];
    _appendCached(rows);
    _fromCache = true;
    _emitReady(emit);
  }

  Future<void> _loadMore(Emitter<GameBrowseState> emit) async {
    if (state is! GameBrowseReady || !_hasMore) return;
    final epoch = _epoch;
    _emitReady(emit, loadingMore: true);

    if (_fromCache) {
      final rows = await _readCache(offset: _games.length);
      if (_ended(epoch)) return;
      if (rows == null) return _emitReady(emit, loadMoreFailed: true);
      _appendCached(rows);
      return _emitReady(emit);
    }

    final PaginatedResult<Game>? page;
    try {
      page = await _fetch(epoch, page: _nextPage);
    } on GamesForbiddenException {
      if (epoch.isCompleted) return;
      await _forgetCatalog();
      if (_ended(epoch)) return;
      _games = const [];
      _hasMore = false;
      return emit(GameBrowseDenied(sort: _sort));
    } on Object catch (error, stackTrace) {
      if (epoch.isCompleted) return;
      _logger.warn(
        'Game catalog page $_nextPage failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _emitReady(emit, loadMoreFailed: true);
    }

    if (page == null || _ended(epoch)) return;
    await _write(page.items);
    if (_ended(epoch)) return;
    _append(page.items);
    _nextPage++;
    _hasMore = page.meta.hasMore && _served(_nextPage);
    _emitReady(emit);
  }

  /// The server's [page] of the catalog in the current sort, or null as soon
  /// as the sort changes under [epoch].
  ///
  /// A read of the old sort is not waited out. It holds the slot reads are
  /// dropped from ([GameBrowseRead]) for as long as the server takes to
  /// answer, and a slow one would make the new list's next page, or its
  /// retry, do nothing until it did. The request itself still runs, and
  /// whatever it answers or fails with later is ignored.
  Future<PaginatedResult<Game>?> _fetch(
    Completer<void> epoch, {
    required int page,
  }) => Future.any<PaginatedResult<Game>?>([
    _remote.fetchPage(page: page, limit: pageSize, sort: _sort),
    epoch.future.then<PaginatedResult<Game>?>((_) => null),
  ]);

  /// Whether a read begun under [epoch] has nothing left to do: the list has
  /// closed, or the sort has changed since, and what it read is of another
  /// order.
  bool _ended(Completer<void> epoch) => isClosed || epoch.isCompleted;

  void _onGameGone(GameBrowseGameGone event, Emitter<GameBrowseState> emit) {
    _gone.add(event.gameId);
    final shown = state;
    if (shown is! GameBrowseReady) return;
    final games = [
      for (final game in _games)
        if (game.id != event.gameId) game,
    ];
    if (games.length == _games.length) return;
    _games = games;
    // A page on its way, or a retry, is still on its way.
    _emitReady(
      emit,
      retrying: shown.retrying,
      loadingMore: shown.loadingMore,
      loadMoreFailed: shown.loadMoreFailed,
    );
  }

  /// Whether the server serves [page]: see "The deepest page".
  bool _served(int page) =>
      (page - 1) * pageSize <= GamesRemoteDataSource.maxDepth;

  /// One page of the cache, plus one row to tell whether there is another.
  /// Null when there is no cache or the read failed.
  Future<List<Game>?> _readCache({required int offset}) async {
    final cache = _cache;
    if (cache == null) return null;
    try {
      return await cache.getGamesPage(
        offset: offset,
        limit: pageSize + 1,
        sort: _sort,
      );
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Reading cached games failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  void _appendCached(List<Game> rows) {
    _hasMore = rows.length > pageSize;
    _append(rows.take(pageSize));
  }

  void _append(Iterable<Game> games) {
    final shown = {..._gone, for (final game in _games) game.id};
    _games = [
      ..._games,
      for (final game in games)
        if (shown.add(game.id)) game,
    ];
  }

  Future<void> _write(List<Game> page) async {
    final cache = _cache;
    final games = [
      for (final game in page)
        if (!_gone.contains(game.id)) game,
    ];
    if (cache == null || games.isEmpty) return;
    try {
      await cache.cacheGames(games);
    } on Object catch (error, stackTrace) {
      // A session ending mid-read lands here, as a disposed cache.
      _logger.warn(
        'Caching a catalog page failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _forgetCatalog() async {
    final cache = _cache;
    if (cache == null) return;
    try {
      await cache.forgetCatalog();
    } on Object catch (error, stackTrace) {
      // The forget fails on a cache the ended session disposed.
      _logger.warn(
        'Forgetting the refused catalog failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _emitReady(
    Emitter<GameBrowseState> emit, {
    bool retrying = false,
    bool loadingMore = false,
    bool loadMoreFailed = false,
  }) => emit(
    GameBrowseReady(
      sort: _sort,
      games: _games,
      hasMore: _hasMore,
      fromCache: _fromCache,
      retrying: retrying,
      loadingMore: loadingMore,
      loadMoreFailed: loadMoreFailed,
    ),
  );
}
