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

  /// Marks [id] as [SyncStatus.completed] and records completion.
  Future<void> markCompleted(String id);

  /// Marks [id] as [SyncStatus.failed], increments retry count, stores [error].
  Future<void> markFailed(String id, {required String error});

  /// Removes all completed entries. Called periodically to keep the queue lean.
  Future<int> purgeCompleted();

  /// Total count of pending + in-progress entries. Used for UI badge display.
  Future<int> getPendingCount();

  /// Stream emitting pending count on any queue change.
  Stream<int> watchPendingCount();
}
