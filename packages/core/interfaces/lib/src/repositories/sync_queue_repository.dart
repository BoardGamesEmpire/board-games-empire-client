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
  /// that have not exceeded [SyncQueueEntry.maxRetries], in [createdAt]
  /// order with rowid as a stable tiebreaker.
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
  /// entries are counted as outstanding by [getPendingCount] /
  /// [watchPendingCount] but never returned by [getPendingEntries]
  /// for processing — the queue UI shows work outstanding that no
  /// one will pick up.
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

  /// Rewrites the payload of every pending or retryable-failed entry
  /// whose target collection id matches [oldCollectionId], replacing
  /// it with [newCollectionId].
  ///
  /// Used by [GameCollectionRepository.reconcileFromServer] when the
  /// server returns a canonical id different from the one the local
  /// row was created with: pending [UpdateCollectionOperation] /
  /// [RemoveFromCollectionOperation] entries queued against the
  /// local-only id would otherwise be sent to the server with an id
  /// the server doesn't know.
  ///
  /// Affects:
  ///
  /// - [AddToCollectionOperation.localId] (informational on the op,
  ///   kept consistent so the serialized form doesn't lie about
  ///   which local row it created).
  /// - [UpdateCollectionOperation.collectionId] (the actual target).
  /// - [RemoveFromCollectionOperation.collectionId] (the actual
  ///   target).
  ///
  /// Status filter: only entries with status `pending` or retryable
  /// `failed` are touched. `completed` and `inProgress` entries are
  /// not rewritten — they've already been sent to the server with
  /// the old id, and a separate completion / recovery path is
  /// responsible for them.
  ///
  /// Returns the number of entries actually rewritten. A return
  /// value of 0 is normal and means no pending op referenced
  /// [oldCollectionId].
  Future<int> remapCollectionId({
    required String oldCollectionId,
    required String newCollectionId,
  });

  /// Total count of outstanding sync work. Matches the same set
  /// [getPendingEntries] returns plus entries currently in
  /// [SyncStatus.inProgress], i.e. entries in:
  ///
  /// - [SyncStatus.pending]
  /// - [SyncStatus.inProgress] (still outstanding work; the worker
  ///   needs [resetStaleInProgress] before it can pick them up
  ///   directly, but they're not done either)
  /// - [SyncStatus.failed] with `retryCount < SyncQueueEntry.maxRetries`
  ///   (retryable failures — the worker will pick them up on its
  ///   next cycle)
  ///
  /// Used for UI badge display. Implementations MUST keep this in
  /// lockstep with [getPendingEntries] / [watchPendingCount]: a
  /// change to the predicate in one requires a matching change in
  /// the others, otherwise the badge and the worker's pickup queue
  /// diverge.
  Future<int> getPendingCount();

  /// Stream emitting the pending count on any queue change. Same
  /// status-set semantics as [getPendingCount].
  Stream<int> watchPendingCount();
}
