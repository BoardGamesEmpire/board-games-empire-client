import 'dart:async';

import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:uuid/uuid.dart';

import '../databases/server_database.dart';

class SyncQueueRepositoryImpl implements SyncQueueRepository {
  const SyncQueueRepositoryImpl(this._db);

  final ServerDatabase _db;
  static const _uuid = Uuid();

  @override
  Future<SyncQueueEntry> enqueue(SyncOperation operation) async {
    final id = _uuid.v4();
    final now = DateTime.now().toUtc();

    await _db
        .into(_db.syncQueueTable)
        .insert(
          SyncQueueTableCompanion.insert(
            id: id,
            payload: operation.serialized,
            status: const Value('pending'),
            retryCount: const Value(0),
            createdAt: now,
          ),
        );

    final row = await (_db.select(
      _db.syncQueueTable,
    )..where((t) => t.id.equals(id))).getSingle();
    return _mapRow(row);
  }

  @override
  Future<List<SyncQueueEntry>> getPendingEntries() async {
    final rows =
        await (_db.select(_db.syncQueueTable)
              ..where(
                (t) =>
                    t.status.isIn(['pending', 'failed']) &
                    t.retryCount.isSmallerThanValue(SyncQueueEntry.maxRetries),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();
    return rows.map(_mapRow).toList();
  }

  @override
  Future<List<SyncQueueEntry>> getAllEntries() async {
    final rows = await (_db.select(
      _db.syncQueueTable,
    )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();
    return rows.map(_mapRow).toList();
  }

  @override
  Future<void> markInProgress(String id) async {
    await (_db.update(_db.syncQueueTable)..where((t) => t.id.equals(id))).write(
      SyncQueueTableCompanion(
        status: const Value('inProgress'),
        lastAttemptAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  @override
  Future<void> markCompleted(String id) async {
    await (_db.update(_db.syncQueueTable)..where((t) => t.id.equals(id))).write(
      const SyncQueueTableCompanion(status: Value('completed')),
    );
  }

  @override
  Future<void> markFailed(String id, {required String error}) async {
    // Atomic increment: the retry count is bumped via a column
    // expression (`retry_count = retry_count + 1`) in a single UPDATE
    // statement rather than a read-then-write, so concurrent
    // markFailed calls against the same id cannot lose increments.
    //
    // If the id no longer exists (e.g. already purged), the UPDATE
    // affects zero rows and we move on — same effective behaviour as
    // the prior `if (row == null) return` early-return.
    //
    // The `updates: {syncQueueTable}` argument hooks the raw UPDATE
    // into Drift's reactivity so any `.watch()`s on the queue table
    // (notably [watchPendingCount]) re-emit.
    await _db.customUpdate(
      'UPDATE sync_queue '
      'SET status = ?, '
      '    retry_count = retry_count + 1, '
      '    last_error = ?, '
      '    last_attempt_at = ? '
      'WHERE id = ?',
      variables: [
        Variable.withString('failed'),
        Variable.withString(error),
        Variable.withDateTime(DateTime.now().toUtc()),
        Variable.withString(id),
      ],
      updates: {_db.syncQueueTable},
    );
  }

  @override
  Future<int> purgeCompleted() async {
    return (_db.delete(
      _db.syncQueueTable,
    )..where((t) => t.status.equals('completed'))).go();
  }

  @override
  Future<int> getPendingCount() async {
    final count = _db.syncQueueTable.id.count();
    final query = _db.selectOnly(_db.syncQueueTable)
      ..addColumns([count])
      ..where(_db.syncQueueTable.status.isIn(['pending', 'inProgress']));
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  @override
  Stream<int> watchPendingCount() => _watchPendingCount();

  Stream<int> _watchPendingCount() async* {
    yield 0;
    final count = _db.syncQueueTable.id.count();
    yield* (_db.selectOnly(_db.syncQueueTable)
          ..addColumns([count])
          ..where(_db.syncQueueTable.status.isIn(['pending', 'inProgress'])))
        .watchSingle()
        .map((row) => row.read(count) ?? 0);
  }

  SyncQueueEntry _mapRow(SyncQueueTableData row) => SyncQueueEntry(
    id: row.id,
    payload: row.payload,
    status: _parseStatus(row.status),
    retryCount: row.retryCount,
    lastError: row.lastError,
    createdAt: row.createdAt,
    lastAttemptAt: row.lastAttemptAt,
  );

  /// Parses a stored status string back to a [SyncStatus].
  ///
  /// Accepts both the new canonical form (matching [SyncStatus.name]:
  /// `'inProgress'`) and the legacy schema-v1 form (`'in_progress'`)
  /// during the migration window. Pass 3 may drop the legacy arm once
  /// no v1-state DBs are expected.
  SyncStatus _parseStatus(String value) => switch (value) {
    'pending' => SyncStatus.pending,
    'inProgress' => SyncStatus.inProgress,
    'in_progress' => SyncStatus.inProgress, // legacy pre-schema-v2
    'failed' => SyncStatus.failed,
    'completed' => SyncStatus.completed,
    _ => SyncStatus.pending,
  };
}
