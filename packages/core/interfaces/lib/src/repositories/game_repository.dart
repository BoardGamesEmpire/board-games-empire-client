import 'package:models/domain.dart';

/// Read-only cache of [Game] and [PlatformGame] records for a single server.
///
/// Games are server-managed — clients do not create, update, or delete
/// game catalog entries. The repository populates the local cache from
/// server responses and serves reads from it.
///
/// ## Tombstones
///
/// The cache schema has a `deletedAt` column on [Game] for server-driven
/// soft-deletes (a game removed from the server catalog). All read paths
/// — [getGame], [getGames], [searchGames], [watchGame], [watchGames] —
/// filter out tombstoned rows, so callers never have to special-case
/// `deletedAt != null` themselves. Tombstoned rows physically remain in
/// the cache until a full re-sync purges them; this happens in a phase
/// later than the read-path scope of this interface.
///
/// [PlatformGame] does not have a tombstone column today — server-side
/// removal of a `PlatformGame` is rare enough that the cache treats
/// such rows as "stale until next sync" rather than soft-deletable.
/// If this changes, both this doc and the impl's read paths will need
/// to be updated together.
abstract class GameRepository {
  /// Returns the cached [Game] for [id], or null if not cached.
  ///
  /// Returns null for a tombstoned game (one whose `deletedAt` is set
  /// in the cache) — the tombstone is treated as "not cached" from
  /// the caller's perspective, consistent with [getGames] /
  /// [watchGame].
  Future<Game?> getGame(String id);

  /// Returns all cached games matching [ids]. Missing entries are omitted.
  ///
  /// Tombstoned games are also omitted; the returned list contains
  /// only live entries. Returns `[]` for an empty input list.
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
  ///
  /// Tombstoned games are excluded from the search index, so a search
  /// hit always corresponds to a live cached entry. [limit] must be
  /// positive; non-positive values short-circuit to an empty list
  /// without touching the database.
  Future<List<Game>> searchGames(String query, {int limit = 20});

  /// Watches a single [Game] for changes. Emits null if deleted from cache.
  ///
  /// The stream also emits null when the cached game transitions to
  /// a tombstone (`deletedAt` set) — from the watcher's perspective
  /// the row is gone whether it was hard-deleted or soft-deleted.
  Stream<Game?> watchGame(String id);

  /// Watches all cached games, emitting on any change.
  ///
  /// Tombstoned games are filtered out of every emission, so a
  /// subscriber sees the live-games view evolve without seeing
  /// intermediate tombstoned states.
  Stream<List<Game>> watchGames();
}
