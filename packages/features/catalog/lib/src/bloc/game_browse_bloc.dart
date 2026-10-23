import 'dart:async';

import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'game_browse_event.dart';
import 'game_browse_state.dart';

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
/// is a live list ordered by title, so a game added mid-browse pushes every
/// row after it back one.
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
/// takes down the pages already shown, for the same reason.
///
/// ## When the server fails, the cache in the catalog's order
///
/// When the first page cannot be fetched, for any other reason, the screen
/// shows the games cached on this device instead, read a page at a time in
/// the catalog's own order ([GameRepository.getGamesPage]), as
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
class GameBrowseBloc extends Bloc<GameBrowseEvent, GameBrowseState> {
  GameBrowseBloc({
    required this._remote,
    this._cache,
    Stream<String>? gone,
    this.pageSize = defaultPageSize,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.catalog.browse'),
       super(const GameBrowseLoading()) {
    on<GameBrowseRead>(
      (event, emit) => switch (event) {
        GameBrowseLoadRequested() => _load(emit),
        GameBrowseMoreRequested() => _loadMore(emit),
      },
      transformer: droppable(),
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

  Future<void> _load(Emitter<GameBrowseState> emit) async {
    final retrying = state is GameBrowseReady;
    if (retrying) {
      _emitReady(emit, retrying: true);
    } else {
      emit(const GameBrowseLoading());
    }

    final PaginatedResult<Game> page;
    try {
      page = await _remote.fetchPage(limit: pageSize);
    } on GamesForbiddenException {
      _games = const [];
      return emit(const GameBrowseDenied());
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Game catalog read failed',
        error: error,
        stackTrace: stackTrace,
      );
      // A failed retry leaves the rows shown as they were.
      if (retrying) return _emitReady(emit);
      return _loadFromCache(emit);
    }

    if (isClosed) return;
    await _write(page.items);
    _games = [];
    _append(page.items);
    _fromCache = false;
    _nextPage = 2;
    _hasMore = page.meta.hasMore && _served(_nextPage);
    _emitReady(emit);
  }

  Future<void> _loadFromCache(Emitter<GameBrowseState> emit) async {
    final rows = await _readCache(offset: 0);
    if (rows == null || rows.isEmpty) {
      _games = const [];
      return emit(const GameBrowseFailed());
    }
    _games = [];
    _appendCached(rows);
    _fromCache = true;
    _emitReady(emit);
  }

  Future<void> _loadMore(Emitter<GameBrowseState> emit) async {
    if (state is! GameBrowseReady || !_hasMore) return;
    _emitReady(emit, loadingMore: true);

    if (_fromCache) {
      final rows = await _readCache(offset: _games.length);
      if (rows == null) return _emitReady(emit, loadMoreFailed: true);
      _appendCached(rows);
      return _emitReady(emit);
    }

    final PaginatedResult<Game> page;
    try {
      page = await _remote.fetchPage(page: _nextPage, limit: pageSize);
    } on GamesForbiddenException {
      _games = const [];
      _hasMore = false;
      return emit(const GameBrowseDenied());
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Game catalog page $_nextPage failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _emitReady(emit, loadMoreFailed: true);
    }

    if (isClosed) return;
    await _write(page.items);
    _append(page.items);
    _nextPage++;
    _hasMore = page.meta.hasMore && _served(_nextPage);
    _emitReady(emit);
  }

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
      return await cache.getGamesPage(offset: offset, limit: pageSize + 1);
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

  void _emitReady(
    Emitter<GameBrowseState> emit, {
    bool retrying = false,
    bool loadingMore = false,
    bool loadMoreFailed = false,
  }) => emit(
    GameBrowseReady(
      games: _games,
      hasMore: _hasMore,
      fromCache: _fromCache,
      retrying: retrying,
      loadingMore: loadingMore,
      loadMoreFailed: loadMoreFailed,
    ),
  );
}
