import 'package:cuid2/cuid2.dart';
import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';
import 'watch_disposal.dart';

/// Per-user implementation of [SyncQueueRepository] over the per-server
/// `sync_queue` table (#147).
///
/// ## User scoping
///
/// The table is server-wide, but this repository is constructed per user
/// session with the session's [userId] (its installer,
/// `UserSessionScopeInstaller`, is a `UserScopeInstaller` and receives the
/// id at install time). [enqueue] stamps every row with that id, and
/// **every** other method — reads, status transitions, maintenance, and
/// [remapCollectionId] — filters on it, so a repository built for user A
/// can never observe or mutate user B's rows. On a shared device this is
/// what keeps a departed user's queued offline writes dormant (intact but
/// invisible) until *they* sign back in, and what prevents the drain
/// worker (#121) from ever pushing one user's writes under another user's
/// session. The id is fixed at construction rather than resolved lazily:
/// the object lives in the user-session scope (#135) and is disposed on
/// every authentication transition, so a resolvable instance cannot carry
/// a stale identity.
///
/// ## Disposal (#135 / #138)
///
/// Disposal is the shared [WatchDisposal] contract, and it splits by
/// return type: after [onDispose] the `Future`-returning methods throw
/// [StateError], while [watchPendingCount] **closes** rather than errors
/// — a live subscription ends with `onDone` on the scope pop, and a call
/// made after disposal returns an already-closed stream. See
/// `watch_disposal.dart` — one fix surface shared with
/// `HouseholdRepositoryImpl`.
class SyncQueueRepositoryImpl
    with WatchDisposal
    implements SyncQueueRepository {
  SyncQueueRepositoryImpl(this._db, this._clock, {required this._userId});

  final ServerDatabase _db;

  /// Server-corrected time source (#12). Queue timestamps (createdAt,
  /// lastAttemptAt) use [ClockService.nowUtc] so bookkeeping stays
  /// consistent with the tombstone/updatedAt timestamps produced by
  /// the collection repository against the same server.
  final ClockService _clock;

  /// The user this repository instance is scoped to (#147). Stamped on
  /// every enqueue; filtered on by every query.
  final String _userId;

  @override
  String get disposedRepositoryName => 'SyncQueueRepository';

  @override
  Future<SyncQueueEntry> enqueue(SyncOperation operation) async {
    checkNotDisposed();
    // cuid2 id — matches the format used everywhere else in the
    // codebase (game collections, household entities, the
    // backend's explicit cuid2 usage). Sync-queue ids never
    // round-trip to the server, so the format is a pure
    // codebase-consistency choice here — a log scanner inspecting
    // both queue entries and their target rows sees one id format
    // throughout.
    final id = cuid();
    final now = _clock.nowUtc();

    await _db
        .into(_db.syncQueueTable)
        .insert(
          SyncQueueTableCompanion.insert(
            id: id,
            userId: _userId,
            payload: operation.serialized,
            status: const Value('pending'),
            retryCount: const Value(0),
            createdAt: now,
          ),
        );

    final row = await (_db.select(
      _db.syncQueueTable,
    )..where((t) => t.id.equals(id) & t.userId.equals(_userId))).getSingle();
    return _mapRow(row);
  }

  @override
  Future<List<SyncQueueEntry>> getPendingEntries() async {
    checkNotDisposed();
    // Ordering: primary by createdAt (ASC, FIFO), tiebroken by SQLite
    // rowid (ASC, monotonic insertion order). The tiebreaker is
    // necessary because [ClockService.nowUtc] resolves to microseconds
    // and two back-to-back enqueues on a fast machine can land on the
    // same microsecond (the skew clock's monotonic guard can even pin
    // successive calls to an identical instant) — in which case
    // createdAt-only ordering is
    // not deterministic and dependent ops (add → update → remove)
    // could be processed out of order. SQLite assigns rowids in
    // insertion order on tables that aren't `WITHOUT ROWID`, so it
    // gives us free monotonic enqueue-order.
    final rows =
        await (_db.select(_db.syncQueueTable)
              ..where(
                (t) =>
                    t.userId.equals(_userId) &
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
    checkNotDisposed();
    final rows =
        await (_db.select(_db.syncQueueTable)
              ..where((t) => t.userId.equals(_userId))
              ..orderBy([
                (t) => OrderingTerm.asc(t.createdAt),
                (t) => OrderingTerm.asc(t.rowId),
              ]))
            .get();
    return rows.map(_mapRow).toList();
  }

  @override
  Future<void> markInProgress(String id) async {
    checkNotDisposed();
    await (_db.update(
      _db.syncQueueTable,
    )..where((t) => t.id.equals(id) & t.userId.equals(_userId))).write(
      SyncQueueTableCompanion(
        status: const Value('inProgress'),
        lastAttemptAt: Value(_clock.nowUtc()),
      ),
    );
  }

  @override
  Future<void> markCompleted(String id) async {
    checkNotDisposed();
    await (_db.update(_db.syncQueueTable)
          ..where((t) => t.id.equals(id) & t.userId.equals(_userId)))
        .write(const SyncQueueTableCompanion(status: Value('completed')));
  }

  @override
  Future<void> markFailed(String id, {required String error}) async {
    checkNotDisposed();
    // Atomic increment: the retry count is bumped via a column
    // expression (`retry_count = retry_count + 1`) in a single UPDATE
    // statement rather than a read-then-write, so concurrent
    // markFailed calls against the same id cannot lose increments.
    //
    // If the id no longer exists (e.g. already purged) — or belongs to
    // a different user (#147) — the UPDATE affects zero rows and we
    // move on; same effective behaviour as the prior
    // `if (row == null) return` early-return.
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
      'WHERE id = ? AND user_id = ?',
      variables: [
        Variable.withString('failed'),
        Variable.withString(error),
        Variable.withDateTime(_clock.nowUtc()),
        Variable.withString(id),
        Variable.withString(_userId),
      ],
      updates: {_db.syncQueueTable},
    );
  }

  @override
  Future<int> resetStaleInProgress() async {
    checkNotDisposed();
    // Recovery path for sync-worker crashes. Entries left in the
    // inProgress state after a crash are counted as outstanding by
    // [getPendingCount] / [watchPendingCount] (both of which include
    // 'inProgress') but never returned by [getPendingEntries] (which
    // only returns 'pending' / 'failed'), so without this method
    // they'd sit stuck forever — visible to the UI but unreachable
    // to the worker.
    //
    // Scoped to the current user (#147): a stale entry belonging to a
    // departed user is *their* worker's to recover when they return;
    // resetting it here would make it drainable under the wrong
    // session the moment #121 lands.
    //
    // Single bulk UPDATE so the reset is atomic; .write() returns
    // the affected row count which we propagate to the caller for
    // logging / metrics.
    return (_db.update(_db.syncQueueTable)..where(
          (t) => t.userId.equals(_userId) & t.status.equals('inProgress'),
        ))
        .write(const SyncQueueTableCompanion(status: Value('pending')));
  }

  @override
  Future<int> purgeCompleted() async {
    checkNotDisposed();
    return (_db.delete(_db.syncQueueTable)..where(
          (t) => t.userId.equals(_userId) & t.status.equals('completed'),
        ))
        .go();
  }

  @override
  Future<int> remapCollectionId({
    required String oldCollectionId,
    required String newCollectionId,
  }) async {
    checkNotDisposed();
    // Identity short-circuit — nothing to do if the caller passed
    // the same id twice. (Defensive; the only caller today
    // (reconcileFromServer) already guards against this.)
    if (oldCollectionId == newCollectionId) return 0;

    return _db.transaction(() async {
      // We can't push the id filter into SQL because the target id
      // is buried inside the JSON payload. Fetch all retryable
      // entries, deserialize each, and rewrite the ones that match.
      // The SELECT uses the same predicate as [getPendingEntries] —
      // including the user filter (#147) — and the per-row UPDATE
      // below re-applies `user_id` alongside the id, so the write
      // enforces the scope invariant independently of where its id
      // came from: collection ids are cuid2 and cross-user collisions
      // are practically impossible, but the boundary is enforced
      // uniformly on every write rather than reasoned about
      // per-method.
      final rows =
          await (_db.select(_db.syncQueueTable)..where(
                (t) =>
                    t.userId.equals(_userId) &
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

        await (_db.update(
          _db.syncQueueTable,
        )..where((t) => t.id.equals(row.id) & t.userId.equals(_userId))).write(
          SyncQueueTableCompanion(payload: Value(rewritten.serialized)),
        );
        remapped++;
      }
      return remapped;
    });
  }

  @override
  Future<int> getPendingCount() async {
    checkNotDisposed();
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
    // and re-emits on every change to the sync_queue table. The raw
    // Drift stream is tied to the per-server database and would
    // outlive this repository's user-session scope, so it is wrapped
    // by [untilDisposed] (#135 / #138): the vended stream CLOSES on
    // scope disposal instead of continuing to emit the departed
    // user's (frozen) count.
    return untilDisposed(() {
      final count = _db.syncQueueTable.id.count();
      return (_db.selectOnly(_db.syncQueueTable)
            ..addColumns([count])
            ..where(_pendingPredicate()))
          .watchSingle()
          .map((row) => row.read(count) ?? 0);
    });
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

  /// Predicate for "outstanding sync work" — entries the worker
  /// will eventually pick up or that are currently locked by the
  /// worker. Used by [getPendingCount] and [watchPendingCount] to
  /// feed the UI's sync-queue badge.
  ///
  /// Four rules, each defended by an existing test in the
  /// `getPendingCount() / watchPendingCount() — _pendingPredicate
  /// symmetry` group (the user rule by the #147 scoping suite):
  ///
  /// 1. **Only the current user's rows count** (#147): another
  ///    user's dormant offline work is not this session's
  ///    outstanding work and must not inflate the badge.
  ///
  /// 2. **All three live statuses are included**: `pending` and
  ///    `failed` because [getPendingEntries] returns them;
  ///    `inProgress` because those entries are still outstanding
  ///    work even though the worker has them locked (they go
  ///    through [resetStaleInProgress] before becoming retryable
  ///    again, but until that happens the badge should not lie
  ///    by hiding them). `completed` is excluded — that's done
  ///    work.
  ///
  /// 3. **`retryCount < maxRetries` applies to ALL three**, not
  ///    just `failed`.
  ///
  /// 4. **Symmetry with [getPendingEntries]** is enforced by the
  ///    test group: every change to one predicate gets a
  ///    corresponding test for the other.
  Expression<bool> _pendingPredicate() {
    final t = _db.syncQueueTable;
    return t.userId.equals(_userId) &
        t.status.isIn(['pending', 'inProgress', 'failed']) &
        t.retryCount.isSmallerThanValue(SyncQueueEntry.maxRetries);
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
  /// unrecognized value represents either DB corruption or a newer
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
