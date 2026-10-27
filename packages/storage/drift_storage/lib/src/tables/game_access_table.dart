import 'package:drift/drift.dart';

import 'game_table.dart';

/// Which users each cached game was sent to (#434): one row per user, game
/// and [source].
///
/// `games` holds each game once per server, shared by every user signed in
/// to it on this device. Every game read returns only rows the reading user
/// has a row here for, so one user can't list or look up a game the server
/// sent only to another. Which rows exist records what the server sent, not
/// the game's reach: a collection summary carries no reach.
///
/// - **[source] is part of the key.** A game cached both from a user's
///   collection and from a catalog fetch keeps both reasons, so removing
///   one later (#469) can't take away the other.
/// - **Never pruned yet.** Rows for removed entries and departed users stay
///   until #469; each stays readable only by the user it names.
/// - **Indexed on [gameId].** The primary key leads with [userId], so it
///   can't find a game's rows. SQLite looks them up on every change to a
///   `games` key, which includes each full write's upsert, since drift
///   sets `id` in its update. Without the index, each lookup scans the
///   whole table.
@TableIndex(name: 'game_access_game_id_idx', columns: {#gameId})
class GameAccessTable extends Table {
  TextColumn get userId => text()();
  TextColumn get gameId => text().references(GamesTable, #id)();

  /// [cacheAccessSourceCollection] or [cacheAccessSourceCatalog].
  TextColumn get source => text()();

  @override
  Set<Column> get primaryKey => {userId, gameId, source};

  @override
  String get tableName => 'game_access';
}

/// The source of an access row a collection response's embedded summary
/// wrote (#259), and the one the v5 → v6 upgrade backfilled from
/// `game_collections`.
const String cacheAccessSourceCollection = 'collection';

/// The source of an access row a full record wrote: what the server returns
/// for the game itself, such as a `GET /games` search (#42) or an import
/// (#43).
const String cacheAccessSourceCatalog = 'catalog';
