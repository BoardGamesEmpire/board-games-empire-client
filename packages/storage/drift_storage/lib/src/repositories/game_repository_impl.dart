import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';
import '../tables/game_access_table.dart';
import 'watch_disposal.dart';

/// [GameRepository] over the per-server [ServerDatabase], for one user
/// (#434).
///
/// ## One copy of each game, read per user
///
/// `games` and `platform_games` hold each row once per server, whichever
/// users it was cached for. Every write also records the row for this
/// repository's user, in `game_access` or `platform_game_access`, and every
/// read returns only rows recorded for that user. So a user signed in to the
/// same server on this device after another can't list or look up what the
/// server sent only to them.
///
/// The user is fixed at construction, as `GameCollectionRepositoryImpl`'s
/// is. The hydrate writes a page's summaries through this just before it
/// merges the page's entries through that, so the two must name the same
/// user. A page that lands after its session has ended, before the scope
/// finishes popping, still records its rows for the user they came from.
/// No method takes a user id.
///
/// ## Disposal
///
/// Registered in the user-session scope, which pops on sign-out, a server
/// switch, suspend and context dispose. Its Drift streams are tied to the
/// per-server database, which outlives that scope, so it takes the shared
/// [WatchDisposal] contract (#138): after `onDispose()` the `Future` methods
/// throw [StateError], and [watchGame] / [watchGames] close.
class GameRepositoryImpl with WatchDisposal implements GameRepository {
  GameRepositoryImpl(this._db, {required this._userId});

  final ServerDatabase _db;
  final String _userId;

  /// The clock both of this repository's stamps come from: a summary
  /// insert's `createdAt` / `updatedAt`, and a full write's
  /// `fullRecordCachedAt`. Each is a local "when this device cached it"
  /// time with no consensus meaning, so the skew-corrected `ClockService`
  /// is not what it wants. No reader sees either stamp (#406), so neither
  /// is injected.
  static DateTime _now() => DateTime.now().toUtc();

  @override
  String get disposedRepositoryName => 'GameRepository';

  // ── Game ───────────────────────────────────────────────────────────────────────

  /// Whether every game read may return the `games` row [t]: a full record,
  /// not a tombstone, cached for this user.
  ///
  /// Tombstones are hidden so the rest of the app never has to special-case
  /// `deletedAt`. Summary-only rows are hidden because their other columns
  /// hold defaults, not the server's values (#406). Rows cached only for
  /// other users are hidden because the server never sent them to this one
  /// (#434).
  Expression<bool> _readableGame($GamesTableTable t) {
    final access = _db.gameAccessTable;
    return t.deletedAt.isNull() &
        t.fullRecordCachedAt.isNotNull() &
        t.id.isInQuery(
          _db.selectOnly(access)
            ..addColumns([access.gameId])
            ..where(access.userId.equals(_userId)),
        );
  }

  @override
  Future<Game?> getGame(String id) async {
    checkNotDisposed();
    final row = await (_db.select(
      _db.gamesTable,
    )..where((t) => t.id.equals(id) & _readableGame(t))).getSingleOrNull();
    return row == null ? null : _mapGame(row);
  }

  @override
  Future<List<Game>> getGames(List<String> ids) async {
    checkNotDisposed();
    if (ids.isEmpty) return [];
    final rows = await (_db.select(
      _db.gamesTable,
    )..where((t) => t.id.isIn(ids) & _readableGame(t))).get();
    return rows.map(_mapGame).toList();
  }

  @override
  Future<void> cacheGame(Game game) => cacheGames([game]);

  @override
  Future<void> cacheGames(List<Game> games) async {
    checkNotDisposed();
    final now = _now();
    await _db.batch((b) {
      for (final g in games) {
        final row = _gameToCompanion(g, now);
        b.insert(_db.gamesTable, row, onConflict: DoUpdate((old) => row));
        b.insert(
          _db.gameAccessTable,
          _gameAccess(g.id, cacheAccessSourceCatalog),
          mode: InsertMode.insertOrIgnore,
        );
      }
    });
  }

  @override
  Future<void> forgetGame(String id) async {
    checkNotDisposed();
    final games = _db.gameAccessTable;
    final platformGames = _db.platformGameAccessTable;
    await _db.transaction(() async {
      await (_db.delete(platformGames)..where(
            (t) =>
                t.userId.equals(_userId) &
                t.platformGameId.isInQuery(
                  _db.selectOnly(_db.platformGamesTable)
                    ..addColumns([_db.platformGamesTable.id])
                    ..where(_db.platformGamesTable.gameId.equals(id)),
                ),
          ))
          .go();
      await (_db.delete(
        games,
      )..where((t) => t.userId.equals(_userId) & t.gameId.equals(id))).go();
    });
  }

  /// Matches LIKE-wildcard metacharacters: `%` and `_`.
  static final RegExp _likeWildcardChars = RegExp(r'[%_]');

  @override
  Future<List<Game>> searchGames(
    String query, {
    int limit = 20,
    Set<ContentType> contentTypes = const {},
  }) async {
    checkNotDisposed();
    // Reject non-positive limits up front. Without this, passing
    // `limit: -1` would silently disable SQLite's LIMIT clause and
    // turn the query into a full cache scan; `limit: 0` would emit
    // SQL with `LIMIT 0` that returns nothing but still pays the
    // ORDER BY cost.
    if (limit <= 0) return [];

    // Strip SQL `LIKE` wildcards (`%`, `_`) from the user's input.
    //
    // Drift's expression API doesn't expose the `LIKE ... ESCAPE`
    // clause directly, and rewriting the whole searchGames body as a
    // `customSelect` to add `ESCAPE '\\'` would mean replacing the
    // type-safe `select(_db.gamesTable).where(...).orderBy(...)` chain
    // with raw SQL plus manual `QueryRow` -> `GamesTableData` mapping.
    // The pragmatic compromise: drop the wildcards before building
    // the predicate. For board game titles/subtitles, `%` and `_`
    // are vanishingly rare, so the lossiness is acceptable. A user
    // searching for "100%" will get results for "100" instead.
    //
    // TODO(search-literal-wildcards): if a future requirement needs
    // literal `%`/`_` matching, switch this method to `customSelect`
    // with explicit `LIKE ? ESCAPE '\\'` and a row mapper.
    final q = query.trim().toLowerCase().replaceAll(_likeWildcardChars, '');
    if (q.isEmpty) return [];

    // Order in SQL before LIMIT: the previous impl sorted in Dart
    // AFTER applying SQL LIMIT, so when many games matched, the
    // LIMIT clause picked an arbitrary slice and the post-hoc Dart
    // sort could not produce the true top-N by prefix-matching.
    // The two-term SQL ORDER BY below gives the same ranking the
    // Dart sort used to attempt, but on the full result set before
    // LIMIT trims it down.
    final prefixPattern = '$q%';

    // The content types narrow in SQL, before LIMIT, so a type outnumbered
    // by other matches is still found.
    final types = [for (final type in contentTypes) type.toWire()];

    final rows =
        await (_db.select(_db.gamesTable)
              ..where(
                (t) =>
                    _readableGame(t) &
                    (t.title.lower().contains(q) |
                        t.subtitle.lower().contains(q)) &
                    (types.isEmpty
                        ? const Constant(true)
                        : t.contentType.isIn(types)),
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
  Future<List<Game>> getGamesPage({int offset = 0, required int limit}) async {
    checkNotDisposed();
    // Checked rather than passed through: SQLite reads a negative LIMIT as no
    // limit at all, which would turn a page into the whole cache.
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'must not be negative');
    }
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'must be at least 1');
    }

    final rows =
        await (_db.select(_db.gamesTable)
              ..where(_readableGame)
              ..orderBy([
                (t) => OrderingTerm.asc(t.title.collate(Collate.noCase)),
                (t) => OrderingTerm.asc(t.id),
              ])
              ..limit(limit, offset: offset))
            .get();
    return rows.map(_mapGame).toList();
  }

  @override
  Stream<Game?> watchGame(String id) => untilDisposed(
    () =>
        (_db.select(_db.gamesTable)
              ..where((t) => t.id.equals(id) & _readableGame(t)))
            .watchSingleOrNull()
            .map((row) => row == null ? null : _mapGame(row)),
  );

  @override
  Stream<List<Game>> watchGames() => untilDisposed(
    () => (_db.select(
      _db.gamesTable,
    )..where(_readableGame)).watch().map((rows) => rows.map(_mapGame).toList()),
  );

  // ── PlatformGame ───────────────────────────────────────────────────────────────────

  /// Whether every platform game read may return the `platform_games` row
  /// [t]: a full record cached for this user. Platform games carry no
  /// tombstone.
  ///
  /// Access is the platform game's own, not its game's (#434): a user given
  /// one platform game of a game is not given the others.
  Expression<bool> _readablePlatformGame($PlatformGamesTableTable t) {
    final access = _db.platformGameAccessTable;
    return t.fullRecordCachedAt.isNotNull() &
        t.id.isInQuery(
          _db.selectOnly(access)
            ..addColumns([access.platformGameId])
            ..where(access.userId.equals(_userId)),
        );
  }

  @override
  Future<PlatformGame?> getPlatformGame(String id) async {
    checkNotDisposed();
    final row =
        await (_db.select(_db.platformGamesTable)
              ..where((t) => t.id.equals(id) & _readablePlatformGame(t)))
            .getSingleOrNull();
    return row == null ? null : _mapPlatformGame(row);
  }

  @override
  Future<List<PlatformGame>> getPlatformGamesForGame(String gameId) async {
    checkNotDisposed();
    final rows = await (_db.select(
      _db.platformGamesTable,
    )..where((t) => t.gameId.equals(gameId) & _readablePlatformGame(t))).get();
    return rows.map(_mapPlatformGame).toList();
  }

  @override
  Future<void> cachePlatformGame(PlatformGame pg) => cachePlatformGames([pg]);

  @override
  Future<void> cachePlatformGames(List<PlatformGame> platformGames) async {
    checkNotDisposed();
    final now = _now();
    await _db.batch((b) {
      for (final pg in platformGames) {
        final row = _platformGameToCompanion(pg, now);
        b.insert(
          _db.platformGamesTable,
          row,
          onConflict: DoUpdate((old) => row),
        );
        b.insert(
          _db.platformGameAccessTable,
          _platformGameAccess(pg.id, cacheAccessSourceCatalog),
          mode: InsertMode.insertOrIgnore,
        );
      }
    });
  }

  // ── Collection summary (#259) ──────────────────────────────────────────────────

  @override
  Future<void> cachePlatformGameSummaries(
    List<PlatformGameSummary> summaries,
  ) async {
    checkNotDisposed();
    if (summaries.isEmpty) return;
    final now = _now();

    await _db.transaction(() async {
      for (final summary in summaries) {
        await _writeSummary(summary, now);
      }
    });
  }

  /// Writes one summary's game, then its platform game, and records both for
  /// this user. Runs inside the caller's transaction.
  ///
  /// Each insert carries the summary's columns plus the two required
  /// timestamps; each conflict update carries the summary's columns only.
  /// Drift writes just the columns a companion marks present, which is what
  /// keeps a fuller record's other fields intact, its `fullRecordCachedAt`
  /// among them (#406).
  Future<void> _writeSummary(PlatformGameSummary summary, DateTime now) async {
    final game = summary.game;

    await _db
        .into(_db.gamesTable)
        .insert(
          GamesTableCompanion.insert(
            id: game.id,
            title: game.title,
            subtitle: Value(game.subtitle),
            image: Value(game.image),
            thumbnail: Value(game.thumbnail),
            createdAt: now,
            updatedAt: now,
          ),
          onConflict: DoUpdate(
            (_) => GamesTableCompanion(
              title: Value(game.title),
              subtitle: Value(game.subtitle),
              image: Value(game.image),
              thumbnail: Value(game.thumbnail),
            ),
          ),
        );

    await _db
        .into(_db.platformGamesTable)
        .insert(
          PlatformGamesTableCompanion.insert(
            id: summary.id,
            gameId: game.id,
            platformId: summary.platformId,
            platformName: summary.platformName,
            image: Value(summary.image),
            thumbnail: Value(summary.thumbnail),
            createdAt: now,
            updatedAt: now,
          ),
          onConflict: DoUpdate(
            (_) => PlatformGamesTableCompanion(
              gameId: Value(game.id),
              platformId: Value(summary.platformId),
              platformName: Value(summary.platformName),
              image: Value(summary.image),
              thumbnail: Value(summary.thumbnail),
            ),
          ),
        );

    await _db
        .into(_db.gameAccessTable)
        .insert(
          _gameAccess(game.id, cacheAccessSourceCollection),
          mode: InsertMode.insertOrIgnore,
        );
    await _db
        .into(_db.platformGameAccessTable)
        .insert(
          _platformGameAccess(summary.id, cacheAccessSourceCollection),
          mode: InsertMode.insertOrIgnore,
        );
  }

  // ── Access ─────────────────────────────────────────────────────────────────────

  /// This user's access row for the game [gameId], from [source].
  GameAccessTableCompanion _gameAccess(String gameId, String source) =>
      GameAccessTableCompanion.insert(
        userId: _userId,
        gameId: gameId,
        source: source,
      );

  /// This user's access row for the platform game [platformGameId], from
  /// [source].
  PlatformGameAccessTableCompanion _platformGameAccess(
    String platformGameId,
    String source,
  ) => PlatformGameAccessTableCompanion.insert(
    userId: _userId,
    platformGameId: platformGameId,
    source: source,
  );

  // ── Mappers ──────────────────────────────────────────────────────────────────────────

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
    playingTime: row.playingTime,
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
    totalPlayCount: row.totalPlayCount,
    averageRating: row.averageRating,
    bayesRating: row.bayesRating,
    ratingsCount: row.ratingsCount,
    ownedByCount: row.ownedByCount,
    categories: _decodeStringList(row.categoriesJson),
    mechanics: _decodeStringList(row.mechanicsJson),
    designers: _decodeStringList(row.designersJson),
    publishers: _decodeStringList(row.publishersJson),
    tags: _decodeStringList(row.tagsJson),
    visibility: Visibility.fromWire(row.visibility),
    createdById: row.createdById,
    deletedAt: row.deletedAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  /// The full row for [g], marked a full record cached at [cachedAt].
  GamesTableCompanion _gameToCompanion(Game g, DateTime cachedAt) =>
      GamesTableCompanion.insert(
        id: g.id,
        title: g.title,
        subtitle: Value(g.subtitle),
        description: Value(g.description),
        image: Value(g.image),
        thumbnail: Value(g.thumbnail),
        publishYear: Value(g.publishYear),
        minPlayers: Value(g.minPlayers),
        maxPlayers: Value(g.maxPlayers),
        playingTime: Value(g.playingTime),
        minPlayTime: Value(g.minPlayTime),
        minPlayTimeMeasure: Value(g.minPlayTimeMeasure?.toWire()),
        maxPlayTime: Value(g.maxPlayTime),
        maxPlayTimeMeasure: Value(g.maxPlayTimeMeasure?.toWire()),
        minAge: Value(g.minAge),
        complexity: Value(g.complexity),
        contentType: Value(g.contentType.toWire()),
        totalPlayCount: Value(g.totalPlayCount),
        averageRating: Value(g.averageRating),
        bayesRating: Value(g.bayesRating),
        ratingsCount: Value(g.ratingsCount),
        ownedByCount: Value(g.ownedByCount),
        categoriesJson: Value(jsonEncode(g.categories)),
        mechanicsJson: Value(jsonEncode(g.mechanics)),
        designersJson: Value(jsonEncode(g.designers)),
        publishersJson: Value(jsonEncode(g.publishers)),
        tagsJson: Value(jsonEncode(g.tags)),
        visibility: Value(g.visibility.toWire()),
        createdById: Value(g.createdById),
        deletedAt: Value(g.deletedAt),
        createdAt: g.createdAt,
        updatedAt: g.updatedAt,
        fullRecordCachedAt: Value(cachedAt),
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

  /// The full row for [pg], marked a full record cached at [cachedAt].
  PlatformGamesTableCompanion _platformGameToCompanion(
    PlatformGame pg,
    DateTime cachedAt,
  ) => PlatformGamesTableCompanion.insert(
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
    fullRecordCachedAt: Value(cachedAt),
  );

  /// Decodes a JSON-encoded list of strings, returning `[]` on any
  /// failure (malformed JSON, wrong shape at the top level, or a
  /// non-String element).
  ///
  /// The trailing `.toList()` after `.cast<String>()` is
  /// load-bearing. `cast<String>()` returns a LAZY view that
  /// defers per-element type-checking until access; without an
  /// eager materialisation, a corrupt element (e.g. an integer
  /// slipped into a list otherwise full of strings) would not
  /// throw here — it would throw LATER, when a downstream
  /// consumer iterates the returned list, OUTSIDE this method's
  /// try/catch. `.toList()` forces the type-checked walk to
  /// happen inside the try, so the catch can do its job and the
  /// caller sees an empty list rather than an unhandled
  /// [TypeError] in unrelated mapping code.
  List<String> _decodeStringList(String json) {
    try {
      return (jsonDecode(json) as List).cast<String>().toList();
    } catch (_) {
      return [];
    }
  }
}
