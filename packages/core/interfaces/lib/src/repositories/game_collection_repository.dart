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
  /// Only non-null fields are updated. Enqueues [UpdateCollectionOperation].
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
  /// [isDirty] → false) and clears the associated sync queue entry.
  Future<void> reconcileFromServer(GameCollection serverEntry);

  /// Watches the full collection, emitting on any change.
  Stream<List<GameCollection>> watchCollection();

  /// Watches a single entry. Emits null when removed.
  Stream<GameCollection?> watchEntry(String id);
}
