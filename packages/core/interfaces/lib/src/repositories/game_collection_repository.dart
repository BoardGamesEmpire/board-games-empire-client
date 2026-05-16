import 'package:models/domain.dart';

/// Read-write repository for the current user's [GameCollection] entries.
///
/// All writes are applied locally first (optimistic) and a [SyncQueueEntry]
/// is created for each mutation. Callers never wait for server confirmation.
///
/// [isDirty] on a [GameCollection] signals a pending local change.
/// [isLocalOnly] signals an entry not yet confirmed by the server.
abstract class GameCollectionRepository {
  /// Returns all collection entries for the current user.
  Future<List<GameCollection>> getCollection();

  /// Returns the collection entry for [platformGameId] and [medium], or null.
  Future<GameCollection?> getCollectionEntry({
    required String platformGameId,
    required GameMedium medium,
  });

  /// Adds a game to the collection.
  ///
  /// [quantity] must be `> 0`. Implementations should throw
  /// [ArgumentError] before opening the local transaction if it isn't,
  /// so the cache and the sync queue stay untouched on bad input.
  /// Use [removeFromCollection] to delete an entry rather than
  /// passing `quantity: 0`.
  ///
  /// Writes locally, enqueues [AddToCollectionOperation].
  Future<GameCollection> addToCollection({
    required String platformGameId,
    required GameMedium medium,
    int quantity = 1,
    int? rating,
    String? comment,
  });

  /// Updates an existing collection entry.
  ///
  /// Only non-null fields are updated. [quantity] must be `> 0` when
  /// provided; implementations should throw [ArgumentError] before
  /// opening the transaction for non-positive values. Enqueues
  /// [UpdateCollectionOperation].
  ///
  /// **TODO(clear-fields)**: this method cannot currently distinguish
  /// "don't touch this field" from "explicitly clear this nullable
  /// field to null". For nullable columns ([rating], [comment],
  /// [lastPlayed]), `null` always means leave-unchanged. A planned
  /// follow-up will add a separate `clearFields` method (or an enum
  /// parameter on this one) plus a `ClearFieldsOperation` sync op,
  /// so callers can explicitly null out a previously-set rating or
  /// comment. Until then, the workaround is to remove and re-add
  /// the entry without the field.
  Future<GameCollection> updateCollectionEntry({
    required String id,
    int? quantity,
    int? rating,
    int? playCount,
    bool? playAgain,
    bool? favorite,
    String? comment,
    DateTime? lastPlayed,
  });

  /// Removes an entry from the collection.
  ///
  /// Marks the entry as deleted locally (tombstone), enqueues
  /// [RemoveFromCollectionOperation]. Purged after server confirms.
  Future<void> removeFromCollection(String id);

  /// Reconciles a confirmed server response after a sync.
  ///
  /// Replaces the local entry (including [isLocalOnly] → false,
  /// [isDirty] → false). If [completedSyncQueueId] is provided, the
  /// matching sync-queue entry is marked completed in the same
  /// transaction — this is how reconciliation closes the loop with
  /// the queued operation that triggered the server write, so the
  /// same op isn't retried later. Implementations MUST perform the
  /// local upsert and the queue update atomically; either both
  /// succeed or neither does.
  ///
  /// Callers that reconcile from a server-driven sync (not
  /// originating from a local mutation — e.g. a full re-pull) may
  /// omit [completedSyncQueueId] to skip the queue step.
  Future<void> reconcileFromServer(
    GameCollection serverEntry, {
    String? completedSyncQueueId,
  });

  /// Watches the full collection, emitting on any change.
  Stream<List<GameCollection>> watchCollection();

  /// Watches a single entry. Emits null when removed.
  Stream<GameCollection?> watchEntry(String id);
}
