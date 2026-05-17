import 'package:models/domain.dart';

/// Read-write repository for the current user's [GameCollection] entries.
///
/// All writes are applied locally first (optimistic) and a [SyncQueueEntry]
/// is created for each mutation. Callers never wait for server confirmation.
///
/// [isDirty] on a [GameCollection] signals a pending local change.
/// [isLocalOnly] signals an entry not yet confirmed by the server.
///
/// ## Current-user boundary
///
/// Implementations are scoped to a single user (the one passed at
/// construction). Every read and mutation method filters by that
/// user; another user's cached rows are invisible and unreachable
/// regardless of which id the caller supplies. [reconcileFromServer]
/// applies the same boundary to inbound server responses: it throws
/// [StateError] if `serverEntry.userId` differs from the repository's
/// scoped user, so a misrouted or stale response cannot inject
/// another user's row.
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
  /// Marks the entry as deleted locally by setting its `deletedAt`
  /// timestamp (a *tombstone*) and enqueues a
  /// [RemoveFromCollectionOperation]. The tombstone is hidden from
  /// every read path — [getCollection], [getCollectionEntry],
  /// [watchCollection], [watchEntry] — but the row physically
  /// remains in the local cache until the server confirms the
  /// removal.
  ///
  /// ### Idempotence
  ///
  /// Calling on an already-tombstoned id is a silent no-op: no DB
  /// write, no second [RemoveFromCollectionOperation] enqueued.
  /// (The original removal was already sent.)
  ///
  /// ### Physical purge
  ///
  /// The tombstone is physically deleted by [reconcileFromServer]
  /// when the server replies with a `serverEntry` whose
  /// `deletedAt` is non-null — see that method's doc for the full
  /// flow. There is intentionally no separate `purge` method on
  /// this interface: tombstone lifecycle is owned by the sync
  /// engine, not by callers, so the only paths that remove rows
  /// are [removeFromCollection] (tombstone) and
  /// [reconcileFromServer] with a tombstoned server entry
  /// (physical purge).
  ///
  /// ### Throws
  ///
  /// [StateError] if the id is not found for the current user (i.e.
  /// belongs to another user or was never cached).
  Future<void> removeFromCollection(String id);

  /// Reconciles a confirmed server response after a sync.
  ///
  /// ### Current-user boundary
  ///
  /// Implementations MUST verify `serverEntry.userId` matches the
  /// repository's scoped user and throw [StateError] otherwise. A
  /// wrong/stale server response or a misrouted caller cannot
  /// silently inject another user's row into this user's cache.
  /// The check fires BEFORE any local write or sync-queue update,
  /// so a boundary violation leaves the cache and the queue
  /// completely untouched.
  ///
  /// ### Id reassignment + pending-op remap
  ///
  /// If a local row exists for the same
  /// `(userId, platformGameId, medium)` triplet under a different
  /// id than `serverEntry.id` (the server reassigned during sync),
  /// implementations MUST rewrite every pending sync-queue entry
  /// that references the old id to use the new id, BEFORE dropping
  /// the stale local row. Otherwise queued Update/Remove ops would
  /// later be sent to the server with an id the server doesn't
  /// know. The Drift implementation does this via
  /// [SyncQueueRepository.remapCollectionId].
  ///
  /// ### Tombstone confirmation (physical purge)
  ///
  /// When `serverEntry.deletedAt` is non-null, the server is
  /// confirming a removal. Implementations MUST physically delete
  /// every local row for the matching triplet (the live row plus
  /// any tombstones that may have accumulated). No upsert of the
  /// server entry happens in this branch — the row is gone. This
  /// is the only path that physically removes tombstoned rows
  /// created by [removeFromCollection].
  ///
  /// ### Live-entry upsert
  ///
  /// When `serverEntry.deletedAt` is null, implementations upsert
  /// the server entry with `isDirty: false, isLocalOnly: false`.
  /// If a local row had a different id, that stale row is dropped
  /// first (after the remap step above).
  ///
  /// ### Sync-queue closure
  ///
  /// If [completedSyncQueueId] is provided, the matching queue
  /// entry is marked completed in the same transaction. Either
  /// every write lands or none does — a failure in any step
  /// rolls back the whole reconciliation.
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
