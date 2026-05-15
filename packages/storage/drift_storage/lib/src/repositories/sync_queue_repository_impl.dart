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
        status: const Value('in_progress'),
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
    final row = await (_db.select(
      _db.syncQueueTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return;

    await (_db.update(_db.syncQueueTable)..where((t) => t.id.equals(id))).write(
      SyncQueueTableCompanion(
        status: const Value('failed'),
        retryCount: Value(row.retryCount + 1),
        lastError: Value(error),
        lastAttemptAt: Value(DateTime.now().toUtc()),
      ),
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
      ..where(_db.syncQueueTable.status.isIn(['pending', 'in_progress']));
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
          ..where(_db.syncQueueTable.status.isIn(['pending', 'in_progress'])))
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

  SyncStatus _parseStatus(String value) => switch (value) {
    'pending' => SyncStatus.pending,
    'in_progress' => SyncStatus.inProgress,
    'failed' => SyncStatus.failed,
    'completed' => SyncStatus.completed,
    _ => SyncStatus.pending,
  };
}
