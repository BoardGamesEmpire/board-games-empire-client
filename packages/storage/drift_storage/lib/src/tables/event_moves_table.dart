import 'package:drift/drift.dart';

/// Where an event created on this device went when the server reconciled it
/// (#499): the client-issued [localId] and the id the server assigned,
/// [serverId].
///
/// Written in the same transaction that deletes the optimistic row, and
/// only when the two ids differ, so a reader that can no longer find
/// [localId] in `events` can find where it went. It lives in the database
/// rather than in a repository's memory because every web tab reads one
/// database: the tab that created an event must find the move whichever tab
/// reconciled it, and a reload must too.
///
/// - **No foreign keys.** The reconcile deletes the [localId] row, and
///   the purge (#496) can delete the [serverId] one.
/// - **No `user_id`.** A move is a fact about an id, not a user's data.
///   Event reads already require the event to be recorded for the current
///   user, so a move recorded in another user's session leads to an event
///   this user cannot read.
/// - **Never pruned.** One row per event created on this device, and no age
///   tells when the last route holding a local id has gone.
class EventMovesTable extends Table {
  TextColumn get localId => text()();
  TextColumn get serverId => text()();

  @override
  Set<Column> get primaryKey => {localId};

  @override
  String get tableName => 'event_moves';
}
