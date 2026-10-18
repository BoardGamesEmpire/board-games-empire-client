import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';

import '../databases/server_database.dart';
import '../tables/sync_queue_table.dart' show syncQueueOutstandingStatuses;

/// [UnsentChangesNoticeRepository] over the per-server [ServerDatabase]
/// (#142).
///
/// Holds nothing but the database, so it is registered in the server scope
/// with no user id, and no dispose hook, since it vends no streams.
///
/// Reads `sync_queue` and never writes it; the only table it writes is
/// `unsent_changes_users`.
class UnsentChangesNoticeRepositoryImpl
    implements UnsentChangesNoticeRepository {
  const UnsentChangesNoticeRepositoryImpl(this._db);

  final ServerDatabase _db;

  @override
  Future<void> recordSessionStarted(String userId) =>
      // One transaction, so two session starts can't read the same latest
      // order and tie.
      _db.transaction(() async {
        final users = _db.unsentChangesUsersTable;
        final latest = users.recordedOrder.max();
        final row = await (_db.selectOnly(
          users,
        )..addColumns([latest])).getSingle();
        await _db
            .into(users)
            .insertOnConflictUpdate(
              UnsentChangesUsersTableCompanion.insert(
                userId: userId,
                recordedOrder: (row.read(latest) ?? 0) + 1,
              ),
            );
      });

  @override
  Future<void> recordSignedOut(String userId) async {
    await (_db.delete(
      _db.unsentChangesUsersTable,
    )..where((t) => t.userId.equals(userId))).go();
  }

  @override
  Future<int> unsentChangesCount() async {
    final users = _db.unsentChangesUsersTable;
    final queue = _db.syncQueueTable;
    final count = queue.id.count();
    // An inner join: a recorded user with nothing outstanding has no rows to
    // join, so drops out, and the latest of those left is the one counted.
    final query =
        _db.selectOnly(users).join([
            innerJoin(
              queue,
              queue.userId.equalsExp(users.userId) &
                  queue.status.isIn(syncQueueOutstandingStatuses),
              useColumns: false,
            ),
          ])
          ..addColumns([count])
          ..groupBy([users.userId])
          ..orderBy([OrderingTerm.desc(users.recordedOrder)])
          ..limit(1);
    final row = await query.getSingleOrNull();
    return row?.read(count) ?? 0;
  }
}
