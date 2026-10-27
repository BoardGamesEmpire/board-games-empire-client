import 'package:drift/drift.dart';

import '../databases/server_database.dart';
import '../tables/game_access_table.dart';

/// Ends access records in the games cache, and deletes the `games` /
/// `platform_games` rows they leave with no reader (#469, #557). Each method
/// runs in a transaction, joining the caller's when it has one.
///
/// A row is read by a user while a record names it for them, so it has no
/// reader once the last record is gone. A `platform_games` row also stays
/// while any `game_collections` row joins to it, whatever its user or state,
/// and a `games` row while any `platform_games` row does.
///
/// Every prune is scoped to the ids whose records the call just deleted, and
/// the games of any platform games it deleted. It never sweeps a table.
final class GameCacheAccess {
  GameCacheAccess(this._db);

  final ServerDatabase _db;

  /// The most ids one statement binds. SQLite's bound-variable limit is
  /// 32766, and a catalog can hold more rows than that.
  static const int _chunkSize = 500;

  /// Deletes [userId]'s records of every source for [gameId] and its
  /// platform games, then prunes them.
  Future<void> forgetGame({required String userId, required String gameId}) =>
      _db.transaction(() async {
        final platformGames = _db.platformGamesTable;
        // A subquery rather than the ids below, so the delete binds two
        // variables however many platform games the game has.
        final ofGame = _db.selectOnly(platformGames)
          ..addColumns([platformGames.id])
          ..where(platformGames.gameId.equals(gameId));
        final platformGameIds = await ofGame
            .map((row) => row.read(platformGames.id)!)
            .get();

        await (_db.delete(_db.platformGameAccessTable)..where(
              (t) =>
                  t.userId.equals(userId) & t.platformGameId.isInQuery(ofGame),
            ))
            .go();
        await (_db.delete(_db.gameAccessTable)
              ..where((t) => t.userId.equals(userId) & t.gameId.equals(gameId)))
            .go();

        await prune(
          gameIds: {gameId},
          platformGameIds: platformGameIds.toSet(),
        );
      });

  /// Deletes [userId]'s `catalog` records, game and platform game, then
  /// prunes what they named.
  Future<void> forgetCatalog({required String userId}) =>
      _db.transaction(() async {
        final platformRecords =
            await (_db.delete(_db.platformGameAccessTable)..where(
                  (t) =>
                      t.userId.equals(userId) &
                      t.source.equals(cacheAccessSourceCatalog),
                ))
                .goAndReturn();
        final gameRecords =
            await (_db.delete(_db.gameAccessTable)..where(
                  (t) =>
                      t.userId.equals(userId) &
                      t.source.equals(cacheAccessSourceCatalog),
                ))
                .goAndReturn();

        await prune(
          gameIds: {for (final record in gameRecords) record.gameId},
          platformGameIds: {
            for (final record in platformRecords) record.platformGameId,
          },
        );
      });

  /// For each of [platformGameIds] where [userId] has no `game_collections`
  /// row left: deletes their `collection` platform-game record. For each
  /// game of those where they have no row left on any platform game:
  /// deletes their `collection` game record. Then prunes.
  Future<void> releaseCollection({
    required String userId,
    required Set<String> platformGameIds,
  }) async {
    if (platformGameIds.isEmpty) return;
    await _db.transaction(() async {
      final collections = _db.gameCollectionsTable;
      final platformGames = _db.platformGamesTable;

      final held = <String>{};
      for (final chunk in _chunks(platformGameIds)) {
        held.addAll(
          await (_db.selectOnly(collections, distinct: true)
                ..addColumns([collections.platformGameId])
                ..where(
                  collections.userId.equals(userId) &
                      collections.platformGameId.isIn(chunk),
                ))
              .map((row) => row.read(collections.platformGameId)!)
              .get(),
        );
      }
      final released = platformGameIds.difference(held);
      if (released.isEmpty) return;

      final candidateGameIds = <String>{};
      for (final chunk in _chunks(released)) {
        candidateGameIds.addAll(
          await (_db.selectOnly(platformGames, distinct: true)
                ..addColumns([platformGames.gameId])
                ..where(platformGames.id.isIn(chunk)))
              .map((row) => row.read(platformGames.gameId)!)
              .get(),
        );
      }

      final heldGameIds = <String>{};
      for (final chunk in _chunks(candidateGameIds)) {
        heldGameIds.addAll(
          await (_db.selectOnly(collections, distinct: true).join([
                  innerJoin(
                    platformGames,
                    platformGames.id.equalsExp(collections.platformGameId),
                  ),
                ])
                ..addColumns([platformGames.gameId])
                ..where(
                  collections.userId.equals(userId) &
                      platformGames.gameId.isIn(chunk),
                ))
              .map((row) => row.read(platformGames.gameId)!)
              .get(),
        );
      }
      final releasedGameIds = candidateGameIds.difference(heldGameIds);

      for (final chunk in _chunks(released)) {
        await (_db.delete(_db.platformGameAccessTable)..where(
              (t) =>
                  t.userId.equals(userId) &
                  t.source.equals(cacheAccessSourceCollection) &
                  t.platformGameId.isIn(chunk),
            ))
            .go();
      }
      for (final chunk in _chunks(releasedGameIds)) {
        await (_db.delete(_db.gameAccessTable)..where(
              (t) =>
                  t.userId.equals(userId) &
                  t.source.equals(cacheAccessSourceCollection) &
                  t.gameId.isIn(chunk),
            ))
            .go();
      }

      await prune(gameIds: releasedGameIds, platformGameIds: released);
    });
  }

  /// Deletes the [platformGameIds] rows no record or collection row points
  /// at, then the [gameIds] rows, and the games of the platform games it
  /// deleted, that no record or platform game points at.
  Future<void> prune({
    Set<String> gameIds = const {},
    Set<String> platformGameIds = const {},
  }) => _db.transaction(() async {
    final platformGames = _db.platformGamesTable;
    final platformAccess = _db.platformGameAccessTable;
    final collections = _db.gameCollectionsTable;

    // Platform games go first: `platform_games.game_id` references `games`.
    final candidateGameIds = {...gameIds};
    for (final chunk in _chunks(platformGameIds)) {
      final deleted =
          await (_db.delete(platformGames)..where(
                (t) =>
                    t.id.isIn(chunk) &
                    notExistsQuery(
                      _db.select(platformAccess)
                        ..where((a) => a.platformGameId.equalsExp(t.id)),
                    ) &
                    notExistsQuery(
                      _db.select(collections)
                        ..where((c) => c.platformGameId.equalsExp(t.id)),
                    ),
              ))
              .goAndReturn();
      candidateGameIds.addAll(deleted.map((row) => row.gameId));
    }

    final gameAccess = _db.gameAccessTable;
    for (final chunk in _chunks(candidateGameIds)) {
      await (_db.delete(_db.gamesTable)..where(
            (t) =>
                t.id.isIn(chunk) &
                notExistsQuery(
                  _db.select(gameAccess)
                    ..where((a) => a.gameId.equalsExp(t.id)),
                ) &
                notExistsQuery(
                  _db.select(platformGames)
                    ..where((p) => p.gameId.equalsExp(t.id)),
                ),
          ))
          .go();
    }
  });

  static Iterable<List<String>> _chunks(Set<String> ids) sync* {
    final all = ids.toList();
    for (var i = 0; i < all.length; i += _chunkSize) {
      final end = i + _chunkSize;
      yield all.sublist(i, end > all.length ? all.length : end);
    }
  }
}
