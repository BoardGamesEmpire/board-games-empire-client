import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

/// A queue that counts how often its rows are read and otherwise passes
/// every call through to [_inner].
///
/// A read loads every row it matches, so the number of reads a pass makes
/// is what that pass costs as the queue grows.
class CountingQueue implements SyncQueueRepository {
  CountingQueue(this._inner);

  final SyncQueueRepository _inner;

  /// Listings and lookups so far: every call that loads rows.
  int reads = 0;

  Future<T> _read<T>(Future<T> Function() read) {
    reads++;
    return read();
  }

  @override
  Future<List<SyncQueueEntry>> getPendingEntries() =>
      _read(_inner.getPendingEntries);

  @override
  Future<List<SyncQueueEntry>> getAllEntries() => _read(_inner.getAllEntries);

  @override
  Future<List<SyncQueueEntry>> getOutstandingEntries() =>
      _read(_inner.getOutstandingEntries);

  @override
  Future<List<SyncQueueEntry>> getOutstandingOpsFor(
    String collectionId, {
    String? including,
  }) => _read(
    () => _inner.getOutstandingOpsFor(collectionId, including: including),
  );

  @override
  Future<SyncQueueEntry?> lastDeliveredOpFor(String collectionId) =>
      _read(() => _inner.lastDeliveredOpFor(collectionId));

  @override
  Future<SyncQueueEntry> enqueue(SyncOperation operation) =>
      _inner.enqueue(operation);

  @override
  Future<bool> claim(String id, {String? payload}) =>
      _inner.claim(id, payload: payload);

  @override
  Future<void> release(String id) => _inner.release(id);

  @override
  Future<void> markCompleted(String id) => _inner.markCompleted(id);

  @override
  Future<void> markFailed(String id, {required String error}) =>
      _inner.markFailed(id, error: error);

  @override
  Future<void> park(String id, {required String error}) =>
      _inner.park(id, error: error);

  @override
  Future<int> purgeCompleted({Duration olderThan = Duration.zero}) =>
      _inner.purgeCompleted(olderThan: olderThan);

  @override
  Future<int> remapCollectionId({
    required String oldCollectionId,
    required String newCollectionId,
  }) => _inner.remapCollectionId(
    oldCollectionId: oldCollectionId,
    newCollectionId: newCollectionId,
  );

  @override
  Future<int> getPendingCount() => _inner.getPendingCount();

  @override
  Stream<int> watchPendingCount() => _inner.watchPendingCount();

  @override
  Stream<List<SyncQueueEntry>> watchStuckEntries() =>
      _inner.watchStuckEntries();

  @override
  Future<SyncQueueEntry?> getEntry(String id) =>
      _read(() => _inner.getEntry(id));

  @override
  Future<bool> retry(String id) => _inner.retry(id);

  @override
  Future<bool> discard(String id) => _inner.discard(id);

  @override
  Future<bool> discardStuck(String id) => _inner.discardStuck(id);
}
