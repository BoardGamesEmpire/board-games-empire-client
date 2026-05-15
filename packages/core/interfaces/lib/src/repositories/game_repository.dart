import 'package:models/domain.dart';

/// Read-only cache of [Game] and [PlatformGame] records for a single server.
///
/// Games are server-managed — no create/update/delete. The repository
/// populates the local cache from server responses and serves reads from it.
abstract class GameRepository {
  /// Returns the cached [Game] for [id], or null if not cached.
  Future<Game?> getGame(String id);

  /// Returns all cached games matching [ids]. Missing entries are omitted.
  Future<List<Game>> getGames(List<String> ids);

  /// Returns the cached [PlatformGame] for [id], or null if not cached.
  Future<PlatformGame?> getPlatformGame(String id);

  /// Returns all [PlatformGame] entries for a given [gameId].
  Future<List<PlatformGame>> getPlatformGamesForGame(String gameId);

  /// Upserts [game] into the local cache.
  Future<void> cacheGame(Game game);

  /// Upserts a batch of games. More efficient than repeated [cacheGame] calls.
  Future<void> cacheGames(List<Game> games);

  /// Upserts [platformGame] into the local cache.
  Future<void> cachePlatformGame(PlatformGame platformGame);

  /// Upserts a batch of platform games.
  Future<void> cachePlatformGames(List<PlatformGame> platformGames);

  /// Searches cached games by [query] against title and subtitle.
  /// Returns results ordered by relevance (title prefix match first).
  Future<List<Game>> searchGames(String query, {int limit = 20});

  /// Watches a single [Game] for changes. Emits null if deleted from cache.
  Stream<Game?> watchGame(String id);

  /// Watches all cached games, emitting on any change.
  Stream<List<Game>> watchGames();
}
