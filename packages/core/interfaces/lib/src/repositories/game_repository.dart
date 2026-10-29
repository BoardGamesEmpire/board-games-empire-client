import 'package:models/domain.dart';

/// Read-only cache of [Game] and [PlatformGame] records for a single server,
/// read as one user.
///
/// Games are server-managed — clients do not create, update, or delete
/// game catalog entries. The repository populates the local cache from
/// server responses and serves reads from it.
///
/// ## Per user (#434)
///
/// An instance belongs to one user's session and is resolved from that
/// session's scope. The cache stores each game once per server, whichever
/// users signed in to it on this device it was cached for, but every read
/// returns only rows cached for this instance's user. A game the server
/// sent only to another user reads as not cached, even a public one,
/// because what decides it is what the server sent each user, not the
/// game's reach.
///
/// Platform games are recorded separately from their games. A user who was
/// sent one platform game of a game reads that one, not the game's others.
///
/// After the session ends the `Future` methods throw [StateError], and
/// [watchGame] / [watchGames] streams close.
///
/// ## Tombstones
///
/// The cache schema has a `deletedAt` column on [Game] for server-driven
/// soft-deletes (a game removed from the server catalog). All read paths
/// — [getGame], [getGames], [searchGames], [getGamesPage], [watchGame],
/// [watchGames] —
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
///
/// ## Summary-only rows (#259, #406)
///
/// [cachePlatformGameSummaries] can insert a game the cache never held
/// with only its title, subtitle and images. Every other column keeps its
/// default until a full record is cached: null player counts, play time
/// and the rest, and a `reach` of public, which the summary never
/// stated.
///
/// So every read treats such a row as not cached, the way it treats a
/// tombstone, until [cacheGame] / [cacheGames] (or [cachePlatformGame] /
/// [cachePlatformGames]) caches the full record. A cache hit is therefore
/// always a full record. A screen that has an entry's summary but no full
/// record shows the summary and fetches the rest from the server.
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

  /// Returns the cached [PlatformGame] entries for a given [gameId]: only
  /// those this user was sent, so possibly not all of the game's.
  Future<List<PlatformGame>> getPlatformGamesForGame(String gameId);

  /// Upserts [game]'s full record into the local cache, and records it for
  /// this user.
  ///
  /// Records the game only: none of its platform games becomes readable to
  /// this user through it.
  Future<void> cacheGame(Game game);

  /// Upserts a batch of games, as [cacheGame] does for each, in one batch.
  Future<void> cacheGames(List<Game> games);

  /// Stops reading the game [id] and its platform games as cached for this
  /// user, whatever cached them: for when the server answers that this user
  /// can't read the game, as `GET /games/:id`'s 404 and 403 do (#42).
  ///
  /// Other users' records are left alone. The game and platform game rows
  /// left with no record, and no collection row or platform game pointing at
  /// them, are deleted (#469). Caching the game again makes it readable
  /// again.
  Future<void> forgetGame(String id);

  /// Stops reading as cached for this user whatever the catalog cached: for
  /// when the server answers that this user can read none of its games, as
  /// `GET /games` and `GET /games/search` do with a 403 (#557).
  ///
  /// Deletes this user's `catalog` records. Their `collection` records and
  /// other users' records are left alone, so a game the server sent with
  /// this user's collection still reads. A game added on this device gets
  /// its `collection` record only when a collection sync sends it back, so
  /// until then it stops reading too. The game and platform game rows left
  /// with no record, and nothing pointing at them, are deleted. Throws once
  /// the session has ended, like every other method.
  Future<void> forgetCatalog();

  /// Upserts [platformGame]'s full record into the local cache, and records
  /// it for this user. Its game must already be cached.
  Future<void> cachePlatformGame(PlatformGame platformGame);

  /// Upserts a batch of platform games, as [cachePlatformGame] does for
  /// each, in one batch.
  Future<void> cachePlatformGames(List<PlatformGame> platformGames);

  /// Writes the platform game and game [summaries] a collection response
  /// embeds (#259), touching **only the columns a summary carries**.
  ///
  /// A row that is absent is inserted with every other column at its
  /// default, and reads as not cached; see "Summary-only rows" in the class
  /// doc. A row that exists has just these columns updated: the game's
  /// `title`, `subtitle`, `image` and `thumbnail`, and the platform game's
  /// `gameId`, `platformId`, `platformName`, `image` and `thumbnail`. So a
  /// fuller record cached through [cacheGame] / [cachePlatformGame] keeps
  /// its player counts, play time and the rest, and stays readable; those
  /// two are full replaces and would null them.
  ///
  /// Both the game and the platform game are recorded for this user, so a
  /// full record cached later, by any user, is readable to this one.
  ///
  /// Each game is written before its platform game, which references it.
  /// The whole list lands in one transaction, so a watcher re-runs once
  /// for it rather than once per summary. An empty list writes nothing.
  ///
  /// ### Timestamps are local, not the server's
  ///
  /// `createdAt` / `updatedAt` are required columns and the summary has
  /// neither, so a row this **inserts** is stamped from the local clock at
  /// the time of the write. An update leaves both alone. No reader sees
  /// them: the row reads as not cached until a full record replaces both
  /// with the server's.
  Future<void> cachePlatformGameSummaries(List<PlatformGameSummary> summaries);

  /// Searches this user's cached games by [query] against title and
  /// subtitle.
  /// Returns results ordered by relevance (title prefix match first).
  ///
  /// Tombstoned games are excluded from the search index, so a search
  /// hit always corresponds to a live cached entry. [limit] must be
  /// positive; non-positive values short-circuit to an empty list
  /// without touching the database.
  ///
  /// [filter] narrows the search by the server's own rules (#474, #565,
  /// #580), before [limit], so [limit] counts only the games it keeps:
  ///
  /// - **Content types:** a game of any type named. None named matches every
  ///   type.
  /// - **Platform types:** the cache holds none, so a filter naming one finds
  ///   nothing rather than games it can't vouch for (#474).
  /// - **Publish year:** a year inside the bounds given. An undated game is
  ///   left out unless the range keeps unknown values.
  /// - **Player count:** a game that supports every count in the range. A
  ///   bound alone is one count, so `min: 5` keeps a 2 to 6 player game and
  ///   drops a 2 to 4 one. A game missing either count is unknown.
  /// - **Play time:** a game whose whole play time fits the range. A bound
  ///   left out doesn't narrow that side. A game with one play time uses it
  ///   for both ends, and one with neither is unknown.
  ///
  /// A range with neither bound narrows nothing, and one that keeps unknown
  /// values also keeps the games that are unknown on it.
  Future<List<Game>> searchGames(
    String query, {
    int limit = 20,
    GameSearchFilter filter = const GameSearchFilter(),
  });

  /// One page of this user's cached games, in the order `GET /games` pages
  /// the catalog: by title, then by id where titles tie (#42).
  ///
  /// Offline browse reads this when the catalog cannot be fetched, so a page
  /// of the cache lines up with a page of the server. Titles are compared
  /// without regard to case. The server's order is its database collation,
  /// which the cache cannot match exactly, so two titles that differ only in
  /// case or accents may come back in a different order than online.
  ///
  /// Tombstoned and summary-only games are left out, as every read leaves
  /// them out. [offset] must be at least 0 and [limit] at least 1; anything
  /// else throws [ArgumentError].
  Future<List<Game>> getGamesPage({int offset = 0, required int limit});

  /// Watches a single [Game] for changes. Emits null if deleted from cache.
  ///
  /// The stream also emits null when the cached game transitions to
  /// a tombstone (`deletedAt` set) — from the watcher's perspective
  /// the row is gone whether it was hard-deleted or soft-deleted.
  Stream<Game?> watchGame(String id);

  /// Watches all games cached for this user, emitting on any change.
  ///
  /// Tombstoned games are filtered out of every emission, so a
  /// subscriber sees the live-games view evolve without seeing
  /// intermediate tombstoned states.
  Stream<List<Game>> watchGames();
}
