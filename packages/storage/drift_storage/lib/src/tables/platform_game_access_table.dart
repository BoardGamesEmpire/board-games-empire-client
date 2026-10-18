import 'package:drift/drift.dart';

import 'platform_game_table.dart';

/// Which users each cached platform game was sent to (#434): one row per
/// user, platform game and [source], the platform-game half of
/// `GameAccessTable`.
///
/// Recorded separately from the game, because access to a game doesn't
/// imply access to every platform game of it. If A owns a game on one
/// platform and B on another, B mustn't learn that someone on this device
/// cached A's.
///
/// Indexed on [platformGameId] for the reason `GameAccessTable` is indexed
/// on its game id.
@TableIndex(
  name: 'platform_game_access_platform_game_id_idx',
  columns: {#platformGameId},
)
class PlatformGameAccessTable extends Table {
  TextColumn get userId => text()();
  TextColumn get platformGameId => text().references(PlatformGamesTable, #id)();

  /// `cacheAccessSourceCollection` or `cacheAccessSourceCatalog`.
  TextColumn get source => text()();

  @override
  Set<Column> get primaryKey => {userId, platformGameId, source};

  @override
  String get tableName => 'platform_game_access';
}
