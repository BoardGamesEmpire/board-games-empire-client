import 'package:models/domain.dart';

/// Manages the local sync queue for offline operations.
///
/// The sync engine reads from this repository, sends operations to the server,
/// and marks entries completed or failed. All writes go through here — no
/// component should write directly to the server without enqueuing first.
abstract class SyncQueueRepository {
  /// Enqueues a new operation. Returns the created entry.
  Future<SyncQueueEntry> enqueue(SyncOperation operation);

  /// Returns all entries with [SyncStatus.pending] or [SyncStatus.failed]
  /// that have not exceeded [SyncQueueEntry.maxRetries], in [createdAt] order.
  Future<List<SyncQueueEntry>> getPendingEntries();

  /// Returns all entries regardless of status. Useful for diagnostics.
  Future<List<SyncQueueEntry>> getAllEntries();

  /// Marks [id] as [SyncStatus.inProgress] and records the attempt timestamp.
  Future<void> markInProgress(String id);

  /// Marks [id] as [SyncStatus.completed].
  ///
  /// Today this only flips the `status` column — there is no separate
  /// `completedAt` timestamp or other completion metadata, despite
  /// historic notes that suggested otherwise. Implementations should
  /// be idempotent: calling on an id that's already completed (or no
  /// longer present) is a silent no-op.
  Future<void> markCompleted(String id);

  /// Marks [id] as [SyncStatus.failed], increments retry count, stores [error].
  Future<void> markFailed(String id, {required String error});

  /// Reset entries currently in [SyncStatus.inProgress] back to
  /// [SyncStatus.pending] so they can be retried.
  ///
  /// Intended for the sync worker to call on startup, **before**
  /// [getPendingEntries], to recover entries left mid-flight when
  /// the previous process died between [markInProgress] and the
  /// matching [markCompleted] / [markFailed]. Otherwise such
  /// entries are counted as pending by [getPendingCount] /
  /// [watchPendingCount] (which include `inProgress`) but never
  /// returned by [getPendingEntries] for processing — the queue UI
  /// shows work outstanding that no one will pick up.
  ///
  /// Idempotent: returns the number of entries actually reset (0
  /// when nothing was stuck). Safe to call repeatedly.
  ///
  /// Implementations MUST NOT call this while a sync worker is
  /// concurrently processing entries — it'd race with the worker's
  /// own [markInProgress] / [markCompleted] sequence. The intended
  /// callsite is single-threaded startup recovery.
  Future<int> resetStaleInProgress();

  /// Removes all completed entries. Called periodically to keep the queue lean.
  Future<int> purgeCompleted();

  /// Total count of pending + in-progress entries. Used for UI badge display.
  Future<int> getPendingCount();

  /// Stream emitting pending count on any queue change.
  Stream<int> watchPendingCount();
}
