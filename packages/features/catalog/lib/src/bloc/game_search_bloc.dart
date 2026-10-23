import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'debounce_restartable.dart';
import 'game_search_event.dart';
import 'game_search_state.dart';

/// Drives the search screen (#42): one page of `GET /games/search`, shown in
/// two sections.
///
/// ## One page, over REST
///
/// The search asks once and shows what comes back. There is no "load more":
/// the server puts no order on its local half and sends no has-more signal,
/// so a second page could repeat or skip results (backend#792). Streaming
/// over the WebSocket is #473.
///
/// The server waits for every DataGateway, for up to 15 seconds, before it
/// answers, so [GameSearchLoading] can last that long.
///
/// ## Two sections
///
/// [GameSearchReady.onServer] is the server's own half. Every DataGateway's
/// results follow, in [GameSearchReady.fromSources], less any game the
/// first section already lists: the server reports a game it imported both
/// as its own and again under the DataGateway it came from (backend#662).
///
/// A DataGateway is named only where [sourceNames] can name it. The shell
/// passes one only when the user may read DataGateways, which ordinary users
/// may not (#42). Without it, a result carries no source name, and the note
/// on DataGateways that did not answer counts them instead of naming them.
///
/// ## Typing, filtering and the order of answers
///
/// Query changes are debounced, and a new one cancels the handler still
/// waiting on an older one (`restartable()`). A filter change and a retry
/// start a search of their own, outside that ordering. So every search
/// takes a sequence number, and an answer that lands after a newer search
/// started is dropped, as `DataGatewayListBloc`'s reads are.
///
/// A query change whose text, trimmed, is what is already shown searches
/// nothing. One that arrives while that search is still running searches
/// again, because the change cancelled the handler that was waiting for it.
///
/// Clearing the text skips the debounce: the screen goes back to
/// [GameSearchIdle] at once, rather than showing the old text's results
/// under an empty field, and an answer still on its way for that text is
/// dropped.
///
/// ## A game found gone
///
/// A game that the server no longer has, or this user may no longer read,
/// is taken down from both sections when [gone] says so, and stays down
/// while this screen is open.
///
/// ## When the server refuses
///
/// A 403 says this user may not read the server's games at all: the route
/// checks that before it searches. So the bloc reports [GameSearchDenied]
/// rather than searching the cache: the server's answer wins over an old
/// copy, as it does on the detail.
///
/// ## When the search fails
///
/// The bloc searches the games cached on this device instead
/// ([GameRepository.searchGames]), narrowed by the filter's content types,
/// and reports them as [GameSearchReady.fromCache]. Without a cache, or when
/// that read fails too, it reports [GameSearchFailed].
///
/// The cache holds no platform types, so a search narrowed by platform type
/// finds nothing there rather than showing games it cannot vouch for.
class GameSearchBloc extends Bloc<GameSearchEvent, GameSearchState> {
  GameSearchBloc({
    required this._remote,
    this._cache,
    Future<Map<String, String>> Function()? sourceNames,
    Stream<String>? gone,
    Duration debounce = defaultDebounce,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.catalog.search'),
       super(const GameSearchIdle()) {
    on<GameSearchQueryChanged>(
      _onQueryChanged,
      transformer: debounceRestartable(
        debounce,
        immediate: (event) => event.query.trim().isEmpty,
      ),
    );
    on<GameSearchFilterChanged>(_onFilterChanged);
    on<GameSearchRetryRequested>(_onRetryRequested);
    on<GameSearchSourceNamesLoaded>(_onSourceNamesLoaded);
    on<GameSearchGameGone>(_onGameGone);
    _goneSubscription = gone?.listen((id) => add(GameSearchGameGone(id)));

    if (sourceNames != null) unawaited(_loadSourceNames(sourceNames));
  }

  /// How long typing must pause before the text is searched for.
  static const Duration defaultDebounce = Duration(milliseconds: 400);

  final GamesRemoteDataSource _remote;
  final GameRepository? _cache;
  final BgeLogger _logger;

  /// The trimmed text being searched for. Empty when there is none.
  String _query = '';
  GameSearchFilter _filter = const GameSearchFilter();

  /// Which search is the latest. An older one that answers late is dropped.
  int _sequence = 0;

  /// Each DataGateway's name, by id. Empty until they arrive, and for good
  /// where they cannot be read.
  Map<String, String> _names = const {};

  /// The last answer shown, the server's or this device's, kept so names
  /// that arrive later, and games found gone, can be applied to it.
  GameSearchResults? _shown;

  /// Games found gone since this screen opened, never shown again.
  final Set<String> _gone = {};
  StreamSubscription<String>? _goneSubscription;

  @override
  Future<void> close() async {
    await _goneSubscription?.cancel();
    return super.close();
  }

  Future<void> _loadSourceNames(
    Future<Map<String, String>> Function() read,
  ) async {
    try {
      final names = await read();
      if (!isClosed) add(GameSearchSourceNamesLoaded(names));
    } on Object catch (error, stackTrace) {
      // Unnamed results still read correctly; the note counts the
      // DataGateways that did not answer rather than naming them.
      _logger.info(
        'Could not read the DataGateways\' names',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _onQueryChanged(
    GameSearchQueryChanged event,
    Emitter<GameSearchState> emit,
  ) async {
    final query = event.query.trim();
    if (query == _query && state is GameSearchReady) return;
    _query = query;
    await _search(emit);
  }

  Future<void> _onFilterChanged(
    GameSearchFilterChanged event,
    Emitter<GameSearchState> emit,
  ) async {
    _filter = event.filter;
    await _search(emit);
  }

  Future<void> _onRetryRequested(
    GameSearchRetryRequested event,
    Emitter<GameSearchState> emit,
  ) => _search(emit);

  void _onSourceNamesLoaded(
    GameSearchSourceNamesLoaded event,
    Emitter<GameSearchState> emit,
  ) {
    _names = Map.unmodifiable(event.names);
    _showAgain(emit);
  }

  void _onGameGone(GameSearchGameGone event, Emitter<GameSearchState> emit) {
    if (_gone.add(event.gameId)) _showAgain(emit);
  }

  /// Shows the last answer again, with what has changed since applied.
  void _showAgain(Emitter<GameSearchState> emit) {
    final shown = _shown;
    final current = state;
    if (current is GameSearchReady && shown != null) {
      emit(_ready(shown, fromCache: current.fromCache));
    }
  }

  Future<void> _search(Emitter<GameSearchState> emit) async {
    final search = ++_sequence;
    final query = _query;
    final filter = _filter;
    _shown = null;

    if (query.isEmpty) {
      emit(GameSearchIdle(filter: filter));
      return;
    }

    emit(GameSearchLoading(query: query, filter: filter));
    try {
      final results = await _remote.search(
        query,
        contentTypes: filter.contentTypes,
        platformTypes: filter.platformTypes,
      );
      if (search != _sequence) return;
      _shown = results;
      emit(_ready(results, fromCache: false));
    } on GamesForbiddenException {
      if (search != _sequence) return;
      emit(GameSearchDenied(query: query, filter: filter));
    } on Object catch (error, stackTrace) {
      if (search != _sequence) return;
      _logger.warn(
        'Game search failed; searching this device instead',
        error: error,
        stackTrace: stackTrace,
      );
      await _searchCache(emit, search: search, query: query, filter: filter);
    }
  }

  Future<void> _searchCache(
    Emitter<GameSearchState> emit, {
    required int search,
    required String query,
    required GameSearchFilter filter,
  }) async {
    final cache = _cache;
    if (cache == null) {
      emit(GameSearchFailed(query: query, filter: filter));
      return;
    }

    try {
      final games = filter.platformTypes.isNotEmpty
          ? const <Game>[]
          : await cache.searchGames(
              query,
              limit: GamesRemoteDataSource.searchPageSize,
              contentTypes: filter.contentTypes,
            );
      if (search != _sequence) return;
      final results = GameSearchResults(
        local: [for (final game in games) _hitOf(game)],
      );
      _shown = results;
      emit(_ready(results, fromCache: true));
    } on Object catch (error, stackTrace) {
      if (search != _sequence) return;
      _logger.warn(
        'Searching this device failed too',
        error: error,
        stackTrace: stackTrace,
      );
      emit(GameSearchFailed(query: query, filter: filter));
    }
  }

  /// A cached game, as a result from this server.
  static GameSearchHit _hitOf(Game game) => GameSearchHit(
    externalId: game.id,
    title: game.title,
    contentType: game.contentType,
    gameId: game.id,
    yearPublished: game.publishYear,
    minPlayers: game.minPlayers,
    maxPlayers: game.maxPlayers,
    thumbnailUrl: game.thumbnail,
  );

  GameSearchSource _source(String id) =>
      GameSearchSource(id: id, name: _names[id]);

  GameSearchReady _ready(GameSearchResults results, {required bool fromCache}) {
    final onServerIds = {
      for (final hit in results.local)
        if (hit.gameId != null) hit.gameId,
    };

    return GameSearchReady(
      query: _query,
      filter: _filter,
      fromCache: fromCache,
      onServer: [
        for (final hit in results.local)
          if (!_gone.contains(hit.gameId)) hit,
      ],
      fromSources: [
        for (final MapEntry(key: sourceId, value: hits)
            in results.byDataGateway.entries)
          for (final hit in hits)
            if (!onServerIds.contains(hit.gameId) &&
                !_gone.contains(hit.gameId))
              GameSearchSourceHit(source: _source(sourceId), hit: hit),
      ],
      // One note covers every way a DataGateway can fail to answer: the
      // screen tells the user some results may be missing, not why.
      missingSources: [
        for (final id in {
          ...results.failedDataGateways,
          ...results.rateLimitedDataGateways,
          ...results.unavailableDataGateways,
        })
          _source(id),
      ],
    );
  }
}
