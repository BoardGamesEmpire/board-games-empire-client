import 'package:drift/drift.dart';

/// The layout each user left each list screen in (#710): one row per
/// `(user_id, screen)`.
///
/// In the server's database, keyed per user like `game_access` (#434), so a
/// shared device keeps each user's choice apart and wiping the server's data
/// wipes it too. Not `device_preferences`, which is one row for the whole
/// device. Never synced.
///
/// - **Names, not indexes.** [screen] and [layout] hold `Enum.name`, so
///   reordering an enum can't change what a stored row means. A [layout] the
///   client doesn't know reads as no choice.
/// - **No foreign key.** [userId] is a server-assigned id with no users
///   table behind it.
class ListLayoutsTable extends Table {
  TextColumn get userId => text()();

  /// A `ListLayoutScreen` name.
  TextColumn get screen => text()();

  /// A `ListLayout` name.
  TextColumn get layout => text()();

  @override
  Set<Column> get primaryKey => {userId, screen};

  @override
  String get tableName => 'list_layouts';
}
