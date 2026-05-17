import 'package:cuid2/cuid2.dart';
import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';

class SyncQueueRepositoryImpl implements SyncQueueRepository {
  const SyncQueueRepositoryImpl(this._db);

  final ServerDatabase _db;

  @override
  Future<SyncQueueEntry> enqueue(SyncOperation operation) async {
    // cuid2 id — matches the format used everywhere else in the
    // codebase (game collections, household entities, the backend's
    // Prisma `@default(cuid())`). Sync-queue ids never round-trip
    // to the server, so the format is a pure codebase-consistency
    // choice here — a log scanner inspecting both queue entries and
    // their target rows sees one id format throughout.
    final id = cuid();
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
    // Ordering: primary by createdAt (ASC, FIFO), tiebroken by SQLite
    // rowid (ASC, monotonic insertion order). The tiebreaker is
    // necessary because [DateTime.now()] resolves to microseconds and
    // two back-to-back enqueues on a fast machine can land on the
    // same microsecond — in which case createdAt-only ordering is
    // not deterministic and dependent ops (add → update → remove)
    // could be processed out of order. SQLite assigns rowids in
    // insertion order on tables that aren't `WITHOUT ROWID`, so it
    // gives us free monotonic enqueue-order.
    final rows =
        await (_db.select(_db.syncQueueTable)
              ..where(
                (t) =>
                    t.status.isIn(['pending', 'failed']) &
                    t.retryCount.isSmallerThanValue(SyncQueueEntry.maxRetries),
              )
              ..orderBy([
                (t) => OrderingTerm.asc(t.createdAt),
                (t) => OrderingTerm.asc(t.rowId),
              ]))
            .get();
    return rows.map(_mapRow).toList();
  }

  @override
  Future<List<SyncQueueEntry>> getAllEntries() async {
    final rows =
        await (_db.select(_db.syncQueueTable)..orderBy([
              (t) => OrderingTerm.asc(t.createdAt),
              (t) => OrderingTerm.asc(t.rowId),
            ]))
            .get();
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
  Future<int> resetStaleInProgress() async {
    // Recovery path for sync-worker crashes. Entries left in the
    // inProgress state after a crash are counted as outstanding by
    // [getPendingCount] / [watchPendingCount] (both of which include
    // 'inProgress') but never returned by [getPendingEntries] (which
    // only returns 'pending' / 'failed'), so without this method
    // they'd sit stuck forever — visible to the UI but unreachable
    // to the worker.
    //
    // Single bulk UPDATE so the reset is atomic; .write() returns
    // the affected row count which we propagate to the caller for
    // logging / metrics.
    return (_db.update(_db.syncQueueTable)
          ..where((t) => t.status.equals('inProgress')))
        .write(const SyncQueueTableCompanion(status: Value('pending')));
  }

  @override
  Future<int> purgeCompleted() async {
    return (_db.delete(
      _db.syncQueueTable,
    )..where((t) => t.status.equals('completed'))).go();
  }

  @override
  Future<int> remapCollectionId({
    required String oldCollectionId,
    required String newCollectionId,
  }) async {
    // Identity short-circuit — nothing to do if the caller passed
    // the same id twice. (Defensive; the only caller today
    // (reconcileFromServer) already guards against this.)
    if (oldCollectionId == newCollectionId) return 0;

    return _db.transaction(() async {
      // We can't push the id filter into SQL because the target id
      // is buried inside the JSON payload. Fetch all retryable
      // entries, deserialize each, and rewrite the ones that match.
      // The query uses the same predicate as [getPendingEntries] so
      // we only ever touch entries the worker can still pick up.
      final rows =
          await (_db.select(_db.syncQueueTable)..where(
                (t) =>
                    t.status.isIn(['pending', 'failed']) &
                    t.retryCount.isSmallerThanValue(SyncQueueEntry.maxRetries),
              ))
              .get();

      var remapped = 0;
      for (final row in rows) {
        final SyncOperation op;
        try {
          op = SyncOperation.deserialize(row.payload);
        } catch (_) {
          // Skip un-parseable rows; the worker will surface the
          // failure on its next pickup attempt.
          continue;
        }

        final rewritten = _remapOp(op, oldCollectionId, newCollectionId);
        if (rewritten == null) continue;

        await (_db.update(_db.syncQueueTable)
              ..where((t) => t.id.equals(row.id)))
            .write(
              SyncQueueTableCompanion(payload: Value(rewritten.serialized)),
            );
        remapped++;
      }
      return remapped;
    });
  }

  @override
  Future<int> getPendingCount() async {
    final count = _db.syncQueueTable.id.count();
    final query = _db.selectOnly(_db.syncQueueTable)
      ..addColumns([count])
      ..where(_pendingPredicate());
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  @override
  Stream<int> watchPendingCount() {
    // Drift's .watch() already emits the current value on subscribe
    // and re-emits on every change to the sync_queue table, so the
    // prior `async* { yield 0; yield* ...}` wrapper was emitting a
    // misleading fake-zero ahead of the real value. Returning the
    // Drift stream directly also avoids a category of bugs where the
    // wrapper is implemented via a leaky StreamController whose inner
    // subscription is never cancelled when the consumer cancels.
    final count = _db.syncQueueTable.id.count();
    return (_db.selectOnly(_db.syncQueueTable)
          ..addColumns([count])
          ..where(_pendingPredicate()))
        .watchSingle()
        .map((row) => row.read(count) ?? 0);
  }

  /// Returns a rewritten op when [op] targets [oldId], else null.
  ///
  /// Sealed-hierarchy switch with `when` guards: each case both
  /// narrows the op type AND filters by the relevant id field, so
  /// we don't accidentally remap unrelated ops that happen to
  /// stringify to the same id.
  SyncOperation? _remapOp(SyncOperation op, String oldId, String newId) {
    return switch (op) {
      AddToCollectionOperation() when op.localId == oldId =>
        AddToCollectionOperation(
          localId: newId,
          platformGameId: op.platformGameId,
          medium: op.medium,
          quantity: op.quantity,
          rating: op.rating,
          comment: op.comment,
        ),
      UpdateCollectionOperation() when op.collectionId == oldId =>
        UpdateCollectionOperation(
          collectionId: newId,
          quantity: op.quantity,
          rating: op.rating,
          playCount: op.playCount,
          playAgain: op.playAgain,
          favorite: op.favorite,
          comment: op.comment,
          lastPlayed: op.lastPlayed,
        ),
      RemoveFromCollectionOperation() when op.collectionId == oldId =>
        RemoveFromCollectionOperation(collectionId: newId),
      _ => null,
    };
  }

  /// Predicate matching the same set of entries that
  /// [getPendingEntries] returns plus those currently in
  /// [SyncStatus.inProgress] (which are still outstanding work even
  /// if the worker can't pick them up directly — they need
  /// [resetStaleInProgress] first).
  ///
  /// Symmetry with [getPendingEntries] is important: the badge that
  /// `watchPendingCount` feeds is meant to indicate "outstanding sync
  /// work", which must include retryable failures. Pre-fix, the
  /// count excluded `failed` rows entirely, so after a transient
  /// network failure the badge dropped to 0 even though the worker
  /// would retry the entry on its next cycle.
  Expression<bool> _pendingPredicate() {
    final t = _db.syncQueueTable;
    return t.status.isIn(['pending', 'inProgress']) |
        (t.status.equals('failed') &
            t.retryCount.isSmallerThanValue(SyncQueueEntry.maxRetries));
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
  /// Strict: any value outside the canonical [SyncStatus] name set
  /// throws [StateError]. A row whose `status` column holds an
  /// unrecognised value represents either DB corruption or a newer
  /// code-side enum case that's been deployed before this read path
  /// was updated. Both must surface rather than be silently coerced
  /// into [SyncStatus.pending] — the prior fallback would have caused
  /// a corrupt or unknown-status row to be retried as a live sync op
  /// against the server.
  ///
  /// The legacy `'in_progress'` snake_case arm has been removed:
  /// pre-production, no v1-state DBs exist, so there is nothing to
  /// migrate from. The canonical wire form is the camelCase
  /// [SyncStatus] `name` (e.g. `'inProgress'`).
  SyncStatus _parseStatus(String value) => switch (value) {
    'pending' => SyncStatus.pending,
    'inProgress' => SyncStatus.inProgress,
    'failed' => SyncStatus.failed,
    'completed' => SyncStatus.completed,
    _ => throw StateError(
      'Unknown sync_queue.status value: "$value". '
      'Expected one of: pending, inProgress, failed, completed.',
    ),
  };
}
