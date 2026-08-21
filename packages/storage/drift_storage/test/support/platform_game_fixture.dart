import 'package:drift_storage/src/databases/server_database.dart';

/// The default ids the collection fixtures key on.
const kFixtureGameId = 'game-1';
const kFixturePlatformGameId = 'pg-1';

/// Seeds a `games` row — the FK target of every `platform_games` row.
///
/// Idempotent (`insertOnConflictUpdate`) so a test can seed several
/// platform games for the same game without ordering its calls.
Future<void> seedGame(
  ServerDatabase db, {
  String id = kFixtureGameId,
  String title = 'Test Game',
}) async {
  final now = DateTime.now().toUtc();
  await db
      .into(db.gamesTable)
      .insertOnConflictUpdate(
        GamesTableCompanion.insert(
          id: id,
          title: title,
          createdAt: now,
          updatedAt: now,
        ),
      );
}

/// Seeds the `games` → `platform_games` chain a `game_collections` row
/// needs, and returns the platform-game id to add to a collection.
///
/// One copy for the whole package: a schema change to either table (a new
/// non-null column, a new FK) is a single edit here rather than five
/// hand-maintained duplicates that fail as opaque Drift insert errors when
/// they drift apart.
Future<String> seedPlatformGame(
  ServerDatabase db, {
  String id = kFixturePlatformGameId,
  String gameId = kFixtureGameId,
}) async {
  await seedGame(db, id: gameId);
  final now = DateTime.now().toUtc();
  await db
      .into(db.platformGamesTable)
      .insert(
        PlatformGamesTableCompanion.insert(
          id: id,
          gameId: gameId,
          platformId: 'plat-1',
          platformName: 'Tabletop',
          createdAt: now,
          updatedAt: now,
        ),
      );
  return id;
}
