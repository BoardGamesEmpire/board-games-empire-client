import 'package:drift/drift.dart';

/// The users whose unsent changes the sign-in screen may mention on this
/// server (#142): one row per user whose session started here and didn't
/// end with them signing out.
///
/// In the server's database, beside the `sync_queue` rows it counts, so the
/// two are created, migrated and wiped together. A key-loss recovery that
/// deletes the queue can't leave this naming users whose changes are gone.
///
/// - **More than one row.** On a shared device, A can leave changes behind
///   and B can then lose a session with changes of their own. The screen
///   speaks for the latest of them with something unsent, [recordedOrder]
///   says which that is, and B's deliberate sign-out hands it back to A.
/// - **No foreign key.** The queue's `user_id` is a server-assigned id with
///   no users table behind it.
/// - **Never pruned.** A user whose changes have all gone simply counts
///   zero, and the table grows by one row per user who has signed in here.
class UnsentChangesUsersTable extends Table {
  TextColumn get userId => text()();

  /// When the user's latest session started, as a sequence: higher is
  /// later. A counter rather than a time, so a device clock that moves
  /// backwards can't reorder it.
  IntColumn get recordedOrder => integer()();

  @override
  Set<Column> get primaryKey => {userId};

  @override
  String get tableName => 'unsent_changes_users';
}
