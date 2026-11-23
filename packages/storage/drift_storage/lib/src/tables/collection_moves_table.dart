import 'package:drift/drift.dart';

/// Where a collection entry went when a live server copy of its triplet
/// replaced it under a different id (#693): the id the local row had,
/// [localId], and the server's, [serverId].
///
/// Written whenever a server write finds the triplet's local row under
/// another id: the reconcile of an add made on this device (the usual
/// case), but also a merge or a rebuild from the server whose row for the
/// triplet differs in id, and a reconcile whose local row for the triplet
/// is a tombstone. It is written in the same transaction that deletes the
/// local row, so a reader that can no longer find [localId] in
/// `game_collections` can find where it went. It lives in the
/// database rather than in a repository's memory because every web tab
/// reads one database: the tab that created an entry must find the move
/// whichever tab reconciled it, and a reload must too.
///
/// - **No foreign keys.** The reconcile deletes the [localId] row, and
///   the purge can delete the [serverId] one.
/// - **No `user_id`.** A move is a fact about an id, not a user's data.
///   Collection reads already filter by the current user, so a move
///   recorded in another user's session leads to an entry this user cannot
///   read.
/// - **Never pruned.** A row per id a triplet's entry moved off, which is
///   mostly one per entry added on this device, and no age tells when the
///   last route holding an old id has gone.
class CollectionMovesTable extends Table {
  TextColumn get localId => text()();
  TextColumn get serverId => text()();

  @override
  Set<Column> get primaryKey => {localId};

  @override
  String get tableName => 'collection_moves';
}
