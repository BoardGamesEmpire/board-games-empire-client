import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/src/bloc/game_detail_event.dart';
import 'package:game_catalog/src/bloc/game_detail_state.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Drives the game detail screen (#42): one game, read from the server, with
/// the platform games a collection add picks from.
///
/// ## Online
///
/// The game `GET /games/:id` returns is written to the games cache
/// ([GameRepository.cacheGame]) before it is shown, and then its platform
/// games ([GameRepository.cachePlatformGames]), so an add from this screen
/// finds its row (#45). A failed write is logged and otherwise ignored. A
/// failed game write skips the platform games, whose rows need the game's.
///
/// Nothing is written once the detail has closed: by then a later visit may
/// have found the game gone and forgotten it, and this older answer would
/// make it readable again. That holds between the two writes as well.
///
/// ## Unavailable
///
/// A missing game (404) and one this user may not read (403) are both
/// [GameDetailUnavailable], whatever the cache holds: the server's answer
/// wins over an old copy.
///
/// Either way the game is also forgotten on this device for this user
/// ([GameRepository.forgetGame]), so offline browse and search stop listing
/// it. A failed forget is logged and otherwise ignored. Then [onGone] hears
/// of it, so the lists already open can take it down, unless the detail
/// closed before the server answered.
///
/// An id that cannot name a game at all is unavailable too, and forgets
/// nothing: the remote refuses it before sending (it arrives from a path,
/// unvalidated), so the server has said nothing about it.
///
/// ## When the read fails
///
/// Any other failure reads the cached copy instead, as
/// [GameDetailReady.fromCache], with the platform games cached for it
/// ([GameRepository.getPlatformGamesForGame]), so the page can still say what
/// the user owns and offer an add (#708). A failed read of those is logged
/// and shows the game without them. Without a cached game,
/// [GameDetailFailed].
class GameDetailBloc extends Bloc<GameDetailEvent, GameDetailState> {
  GameDetailBloc({
    required this.gameId,
    required this._remote,
    this._cache,
    this.onGone,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.catalog.detail'),
       super(const GameDetailLoading()) {
    on<GameDetailLoadRequested>(_onLoadRequested, transformer: droppable());
  }

  final String gameId;

  /// Told [gameId] when the server says the game is gone: see
  /// "Unavailable". Null tells no one.
  final void Function(String gameId)? onGone;

  final GamesRemoteDataSource _remote;
  final GameRepository? _cache;
  final BgeLogger _logger;

  Future<void> _onLoadRequested(
    GameDetailLoadRequested event,
    Emitter<GameDetailState> emit,
  ) async {
    emit(const GameDetailLoading());

    final GameWithPlatformGames read;
    try {
      read = await _remote.fetchGame(gameId);
    } on GameNotFoundException {
      await _gone();
      return emit(const GameDetailUnavailable());
    } on GamesForbiddenException {
      await _gone();
      return emit(const GameDetailUnavailable());
    } on ArgumentError {
      return emit(const GameDetailUnavailable());
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Game read failed; reading this device instead',
        error: error,
        stackTrace: stackTrace,
      );
      return _loadFromCache(emit);
    }

    if (isClosed) return;
    await _write(read);
    emit(GameDetailReady(game: read.game, platformGames: read.platformGames));
  }

  Future<void> _loadFromCache(Emitter<GameDetailState> emit) async {
    final cache = _cache;
    if (cache == null) return emit(const GameDetailFailed());
    try {
      final game = await cache.getGame(gameId);
      if (game == null) return emit(const GameDetailFailed());
      emit(
        GameDetailReady(
          game: game,
          platformGames: await _cachedPlatformGames(cache),
          fromCache: true,
        ),
      );
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Reading the cached game failed',
        error: error,
        stackTrace: stackTrace,
      );
      emit(const GameDetailFailed());
    }
  }

  Future<List<PlatformGame>> _cachedPlatformGames(GameRepository cache) async {
    try {
      return await cache.getPlatformGamesForGame(gameId);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Reading the cached platform games failed',
        error: error,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  /// Forgets the game, then says it is gone: a list told first could read
  /// it back from the cache.
  ///
  /// Says nothing once the detail has closed: its answer may arrive after
  /// a sign-out, and the lists open then may be another user's, who can
  /// read the game. The game is still forgotten, for this user only.
  Future<void> _gone() async {
    await _forget();
    if (!isClosed) onGone?.call(gameId);
  }

  Future<void> _forget() async {
    final cache = _cache;
    if (cache == null) return;
    try {
      await cache.forgetGame(gameId);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Forgetting the unavailable game failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Caches the game, then its platform games, whose rows need the game's.
  Future<void> _write(GameWithPlatformGames read) async {
    final cache = _cache;
    if (cache == null) return;
    try {
      await cache.cacheGame(read.game);
    } on Object catch (error, stackTrace) {
      return _logger.warn(
        'Caching the game failed',
        error: error,
        stackTrace: stackTrace,
      );
    }

    // The game's write may have outlived the detail: see "Online".
    if (isClosed || read.platformGames.isEmpty) return;
    try {
      await cache.cachePlatformGames(read.platformGames);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Caching the platform games failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
