import 'package:drift/drift.dart';

/// Where a household created on this device went when the server
/// reconciled it (#442): the client-issued [localId] and the id the
/// server assigned, [serverId].
///
/// Written in the same transaction that deletes the optimistic row, and
/// only when the two ids differ, so a reader that can no longer find
/// [localId] in `households` can find where it went. It lives in the
/// database rather than in a repository's memory because every web tab
/// reads one database: the tab that created a household must find the
/// move whichever tab reconciled it, and a reload must too.
///
/// - **No foreign keys.** The reconcile deletes the [localId] row, and
///   the purge (#268) can delete the [serverId] one.
/// - **No `user_id`.** A move is a fact about an id, not a user's data.
///   Household reads already require the current user's membership, so a
///   move recorded in another user's session leads to a household this
///   user cannot read.
/// - **Never pruned.** One row per household created on this device, and
///   no age tells when the last route holding a local id has gone.
class HouseholdMovesTable extends Table {
  TextColumn get localId => text()();
  TextColumn get serverId => text()();

  @override
  Set<Column> get primaryKey => {localId};

  @override
  String get tableName => 'household_moves';
}
