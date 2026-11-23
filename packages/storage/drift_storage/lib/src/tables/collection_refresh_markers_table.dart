import 'package:drift/drift.dart';

/// When a user's collection last finished a successful hydration pass on
/// this server (#771): one row per [userId], [confirmedAt] the moment the
/// pass completed.
///
/// It lets a cold start that is offline, or whose first pass has not
/// finished, trust a cache an earlier session already confirmed, instead of
/// treating every start as a first sync.
///
/// - **Per server and user.** The server's database is per server, and the
///   key is the user, so another user on the same server, or a server that
///   has never synced, has no row.
/// - **Not cleared on sign-out.** `game_collections` keeps its rows per
///   user across a sign-out, and the marker lives as long as that cache. It
///   goes when the server's database is wiped.
/// - **No foreign key.** [userId] is a server-assigned id with no users
///   table behind it.
class CollectionRefreshMarkersTable extends Table {
  TextColumn get userId => text()();
  DateTimeColumn get confirmedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {userId};

  @override
  String get tableName => 'collection_refresh_markers';
}
