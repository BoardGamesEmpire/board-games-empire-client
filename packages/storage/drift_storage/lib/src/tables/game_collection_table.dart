import 'package:drift/drift.dart';
import 'platform_game_table.dart';

class GameCollectionsTable extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text()();
  TextColumn get platformGameId => text().references(PlatformGamesTable, #id)();
  TextColumn get medium => text()();

  /// Optional link to a specific [GameRelease] (printing/edition).
  TextColumn get releaseId => text().nullable()();

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

  /// Soft-delete tombstone. Non-null means the entry is awaiting purge
  /// after the sync engine confirms the remote delete. The partial
  /// unique index excludes tombstones from the uniqueness constraint,
  /// so a user can resurrect a previously deleted entry by inserting a
  /// fresh row with the same (user_id, platform_game_id, medium).
  DateTimeColumn get deletedAt => dateTime().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Index> get indexes => [
    Index(
      'game_collections_user_idx',
      'CREATE INDEX game_collections_user_idx '
          'ON game_collections (user_id)',
    ),
    // Partial unique index: enforces one live ownership row per
    // (user_id, platform_game_id, medium) while ignoring tombstoned
    // rows. This serves both as the uniqueness constraint and as the
    // primary lookup path for getCollectionEntry({platformGameId,
    // medium}) on the current user.
    Index(
      'game_collections_user_pgame_medium_unique_idx',
      'CREATE UNIQUE INDEX '
          'game_collections_user_pgame_medium_unique_idx '
          'ON game_collections (user_id, platform_game_id, medium) '
          'WHERE deleted_at IS NULL',
    ),
  ];

  @override
  String get tableName => 'game_collections';
}
