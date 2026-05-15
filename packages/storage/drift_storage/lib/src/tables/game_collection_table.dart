import 'package:drift/drift.dart';
import 'platform_game_table.dart';

class GameCollectionsTable extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text()();
  TextColumn get platformGameId => text().references(PlatformGamesTable, #id)();
  TextColumn get medium => text()();

  IntColumn get quantity => integer().withDefault(const Constant(1))();
  IntColumn get rating => integer().nullable()();
  IntColumn get playCount => integer().nullable()();
  BoolColumn get playAgain => boolean().nullable()();
  BoolColumn get favorite => boolean().nullable()();
  TextColumn get comment => text().nullable()();
  DateTimeColumn get lastPlayed => dateTime().nullable()();
  DateTimeColumn get lastUpdated => dateTime().nullable()();

  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();
  BoolColumn get isLocalOnly => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Index> get indexes => [
    Index(
      'game_collections_user_idx',
      'CREATE INDEX '
          'game_collections_user_idx ON game_collections (user_id)',
    ),
    Index(
      'game_collections_platform_game_idx',
      'CREATE INDEX game_collections_platform_game_idx '
          'ON game_collections (platform_game_id)',
    ),
  ];

  @override
  String get tableName => 'game_collections';
}
