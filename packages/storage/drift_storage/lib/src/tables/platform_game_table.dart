import 'package:drift/drift.dart';
import 'game_table.dart';

/// Index on [PlatformGamesTable.gameId] backs the
/// `getPlatformGamesForGame(gameId)` lookup in
/// `GameRepositoryImpl`. Without it, that query degrades to a full
/// table scan as the cache grows. The primary-key index on [id]
/// doesn't help because the lookup filters by [gameId], not by [id].
@TableIndex(name: 'platform_games_game_id_idx', columns: {#gameId})
class PlatformGamesTable extends Table {
  TextColumn get id => text()();
  TextColumn get gameId => text().references(GamesTable, #id)();
  TextColumn get platformId => text()();
  TextColumn get platformName => text()();

  IntColumn get minPlayers => integer().nullable()();
  IntColumn get maxPlayers => integer().nullable()();
  IntColumn get minPlayTime => integer().nullable()();
  TextColumn get minPlayTimeMeasure => text().nullable()();
  IntColumn get maxPlayTime => integer().nullable()();
  TextColumn get maxPlayTimeMeasure => text().nullable()();
  TextColumn get image => text().nullable()();
  TextColumn get thumbnail => text().nullable()();

  BoolColumn get supportsSolo => boolean().withDefault(const Constant(false))();
  BoolColumn get supportsLocal =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get supportsOnline =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get hasAsyncPlay => boolean().withDefault(const Constant(false))();
  BoolColumn get hasRealtime => boolean().withDefault(const Constant(false))();
  BoolColumn get hasTutorial => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'platform_games';
}
