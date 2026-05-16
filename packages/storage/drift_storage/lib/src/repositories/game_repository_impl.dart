import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';

class GameRepositoryImpl implements GameRepository {
  const GameRepositoryImpl(this._db);

  final ServerDatabase _db;

  // ── Game ──────────────────────────────────────────────────────────────────────

  @override
  Future<Game?> getGame(String id) async {
    final row = await (_db.select(
      _db.gamesTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapGame(row);
  }

  @override
  Future<List<Game>> getGames(List<String> ids) async {
    if (ids.isEmpty) return [];
    final rows = await (_db.select(
      _db.gamesTable,
    )..where((t) => t.id.isIn(ids))).get();
    return rows.map(_mapGame).toList();
  }

  @override
  Future<void> cacheGame(Game game) async {
    await _db
        .into(_db.gamesTable)
        .insertOnConflictUpdate(_gameToCompanion(game));
  }

  @override
  Future<void> cacheGames(List<Game> games) async {
    await _db.batch((b) {
      for (final g in games) {
        b.insert(
          _db.gamesTable,
          _gameToCompanion(g),
          onConflict: DoUpdate((old) => _gameToCompanion(g)),
        );
      }
    });
  }

  @override
  Future<List<Game>> searchGames(String query, {int limit = 20}) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];

    // Order in SQL before LIMIT (Copilot J): the previous impl
    // sorted in Dart AFTER applying SQL LIMIT, so when many games
    // matched, the LIMIT clause picked an arbitrary slice and the
    // post-hoc Dart sort could not produce the true top-N by
    // prefix-matching. The two-term SQL ORDER BY below gives the
    // same ranking the Dart sort used to attempt, but on the full
    // result set before LIMIT trims it down.
    final prefixPattern = '$q%';

    final rows =
        await (_db.select(_db.gamesTable)
              ..where(
                (t) =>
                    t.title.lower().contains(q) |
                    t.subtitle.lower().contains(q),
              )
              ..orderBy([
                // Title-prefix matches first. The LIKE expression
                // evaluates to 1/0; DESC puts 1 (prefix matches) ahead.
                (t) => OrderingTerm(
                  expression: t.title.lower().like(prefixPattern),
                  mode: OrderingMode.desc,
                ),
                // Then alphabetical by title.
                (t) => OrderingTerm.asc(t.title),
              ])
              ..limit(limit))
            .get();

    return rows.map(_mapGame).toList();
  }

  @override
  Stream<Game?> watchGame(String id) =>
      (_db.select(_db.gamesTable)..where((t) => t.id.equals(id)))
          .watchSingleOrNull()
          .map((row) => row == null ? null : _mapGame(row));

  @override
  Stream<List<Game>> watchGames() => _db
      .select(_db.gamesTable)
      .watch()
      .map((rows) => rows.map(_mapGame).toList());

  // ── PlatformGame ───────────────────────────────────────────────────────────────

  @override
  Future<PlatformGame?> getPlatformGame(String id) async {
    final row = await (_db.select(
      _db.platformGamesTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapPlatformGame(row);
  }

  @override
  Future<List<PlatformGame>> getPlatformGamesForGame(String gameId) async {
    final rows = await (_db.select(
      _db.platformGamesTable,
    )..where((t) => t.gameId.equals(gameId))).get();
    return rows.map(_mapPlatformGame).toList();
  }

  @override
  Future<void> cachePlatformGame(PlatformGame pg) async {
    await _db
        .into(_db.platformGamesTable)
        .insertOnConflictUpdate(_platformGameToCompanion(pg));
  }

  @override
  Future<void> cachePlatformGames(List<PlatformGame> platformGames) async {
    await _db.batch((b) {
      for (final pg in platformGames) {
        b.insert(
          _db.platformGamesTable,
          _platformGameToCompanion(pg),
          onConflict: DoUpdate((old) => _platformGameToCompanion(pg)),
        );
      }
    });
  }

  // ── Mappers ──────────────────────────────────────────────────────────────────

  Game _mapGame(GamesTableData row) => Game(
    id: row.id,
    title: row.title,
    subtitle: row.subtitle,
    description: row.description,
    image: row.image,
    thumbnail: row.thumbnail,
    publishYear: row.publishYear,
    minPlayers: row.minPlayers,
    maxPlayers: row.maxPlayers,
    minPlayTime: row.minPlayTime,
    minPlayTimeMeasure: row.minPlayTimeMeasure != null
        ? TimeMeasure.fromWire(row.minPlayTimeMeasure!)
        : null,
    maxPlayTime: row.maxPlayTime,
    maxPlayTimeMeasure: row.maxPlayTimeMeasure != null
        ? TimeMeasure.fromWire(row.maxPlayTimeMeasure!)
        : null,
    minAge: row.minAge,
    complexity: row.complexity,
    contentType: ContentType.fromWire(row.contentType),
    averageRating: row.averageRating,
    bayesRating: row.bayesRating,
    ratingsCount: row.ratingsCount,
    ownedByCount: row.ownedByCount,
    categories: _decodeStringList(row.categoriesJson),
    mechanics: _decodeStringList(row.mechanicsJson),
    designers: _decodeStringList(row.designersJson),
    publishers: _decodeStringList(row.publishersJson),
    deletedAt: row.deletedAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  GamesTableCompanion _gameToCompanion(Game g) => GamesTableCompanion.insert(
    id: g.id,
    title: g.title,
    subtitle: Value(g.subtitle),
    description: Value(g.description),
    image: Value(g.image),
    thumbnail: Value(g.thumbnail),
    publishYear: Value(g.publishYear),
    minPlayers: Value(g.minPlayers),
    maxPlayers: Value(g.maxPlayers),
    minPlayTime: Value(g.minPlayTime),
    minPlayTimeMeasure: Value(g.minPlayTimeMeasure?.toWire()),
    maxPlayTime: Value(g.maxPlayTime),
    maxPlayTimeMeasure: Value(g.maxPlayTimeMeasure?.toWire()),
    minAge: Value(g.minAge),
    complexity: Value(g.complexity),
    contentType: Value(g.contentType.toWire()),
    averageRating: Value(g.averageRating),
    bayesRating: Value(g.bayesRating),
    ratingsCount: Value(g.ratingsCount),
    ownedByCount: Value(g.ownedByCount),
    categoriesJson: Value(jsonEncode(g.categories)),
    mechanicsJson: Value(jsonEncode(g.mechanics)),
    designersJson: Value(jsonEncode(g.designers)),
    publishersJson: Value(jsonEncode(g.publishers)),
    deletedAt: Value(g.deletedAt),
    createdAt: g.createdAt,
    updatedAt: g.updatedAt,
  );

  PlatformGame _mapPlatformGame(PlatformGamesTableData row) => PlatformGame(
    id: row.id,
    gameId: row.gameId,
    platformId: row.platformId,
    platformName: row.platformName,
    minPlayers: row.minPlayers,
    maxPlayers: row.maxPlayers,
    minPlayTime: row.minPlayTime,
    minPlayTimeMeasure: row.minPlayTimeMeasure != null
        ? TimeMeasure.fromWire(row.minPlayTimeMeasure!)
        : null,
    maxPlayTime: row.maxPlayTime,
    maxPlayTimeMeasure: row.maxPlayTimeMeasure != null
        ? TimeMeasure.fromWire(row.maxPlayTimeMeasure!)
        : null,
    image: row.image,
    thumbnail: row.thumbnail,
    supportsSolo: row.supportsSolo,
    supportsLocal: row.supportsLocal,
    supportsOnline: row.supportsOnline,
    hasAsyncPlay: row.hasAsyncPlay,
    hasRealtime: row.hasRealtime,
    hasTutorial: row.hasTutorial,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  PlatformGamesTableCompanion _platformGameToCompanion(PlatformGame pg) =>
      PlatformGamesTableCompanion.insert(
        id: pg.id,
        gameId: pg.gameId,
        platformId: pg.platformId,
        platformName: pg.platformName,
        minPlayers: Value(pg.minPlayers),
        maxPlayers: Value(pg.maxPlayers),
        minPlayTime: Value(pg.minPlayTime),
        minPlayTimeMeasure: Value(pg.minPlayTimeMeasure?.toWire()),
        maxPlayTime: Value(pg.maxPlayTime),
        maxPlayTimeMeasure: Value(pg.maxPlayTimeMeasure?.toWire()),
        image: Value(pg.image),
        thumbnail: Value(pg.thumbnail),
        supportsSolo: Value(pg.supportsSolo),
        supportsLocal: Value(pg.supportsLocal),
        supportsOnline: Value(pg.supportsOnline),
        hasAsyncPlay: Value(pg.hasAsyncPlay),
        hasRealtime: Value(pg.hasRealtime),
        hasTutorial: Value(pg.hasTutorial),
        createdAt: pg.createdAt,
        updatedAt: pg.updatedAt,
      );

  List<String> _decodeStringList(String json) {
    try {
      return (jsonDecode(json) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }
}
