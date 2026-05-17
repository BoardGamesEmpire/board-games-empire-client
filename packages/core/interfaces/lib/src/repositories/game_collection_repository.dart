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
  /// flow, including the resurrection-race carve-out. There is
  /// intentionally no separate `purge` method on this interface:
  /// tombstone lifecycle is owned by the sync engine, not by
  /// callers, so the only paths that remove rows are
  /// [removeFromCollection] (tombstone) and [reconcileFromServer]
  /// with a tombstoned server entry (surgical physical purge).
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
  /// ### Tombstone confirmation (surgical physical purge)
  ///
  /// When `serverEntry.deletedAt` is non-null, the server is
  /// confirming a removal. Implementations MUST physically delete
  /// every tombstone and every server-confirmed live row for the
  /// matching triplet — the row whose id matches `serverEntry.id`,
  /// plus any older tombstones that may have accumulated.
  ///
  /// Implementations MUST NOT delete a local-only live row
  /// (`deletedAt == null && isLocalOnly == true`) even when the
  /// triplet matches. Such a row represents a user intent (a
  /// re-add after an earlier removal) that is still pending in the
  /// sync queue, and clobbering it would silently drop the user's
  /// most recent action. The race the carve-out defends against:
  ///
  /// 1. User adds entry, server confirms (live, isLocalOnly=false).
  /// 2. User removes → tombstone (deletedAt set, isLocalOnly=false),
  ///    RemoveOp queued.
  /// 3. RemoveOp completes — server has tombstoned the row.
  /// 4. User re-adds. The Drift implementation's `addToCollection`
  ///    resurrects the tombstone via its canonical-row lookup:
  ///    same id, `deletedAt` cleared, `isLocalOnly=true`, AddOp
  ///    queued.
  /// 5. The server's confirmation of the step-2 removal — which
  ///    has been in flight — finally arrives at
  ///    [reconcileFromServer]. Without the carve-out, the purge
  ///    would delete the resurrection along with everything else
  ///    for the triplet, silently dropping the user's pending
  ///    re-add intent.
  ///
  /// With the carve-out, the resurrection survives the purge and
  /// its pending AddOp continues through the queue under its
  /// (remapped, if necessary) id.
  ///
  /// No upsert of `serverEntry` happens in the tombstone branch —
  /// the rows the predicate matches are gone, the exclusion clause
  /// keeps the resurrection alive, and the row identity is owned
  /// by the queue from here on.
  ///
  /// ### Live-entry upsert
  ///
  /// When `serverEntry.deletedAt` is null, implementations upsert
  /// the server entry with `isDirty: false, isLocalOnly: false`.
  /// If a local row had a different id, that stale row is dropped
  /// first (after the remap step above).
  ///
  /// **TODO(server-driven-dirty-merge)**: this contract treats
  /// every live-entry reconcile as authoritative — server wins,
  /// `isDirty` is cleared. That's correct when [completedSyncQueueId]
  /// is supplied (the reconcile is the ack of a specific queued
  /// mutation, so the local dirty state was that mutation, and
  /// clearing it is exactly right). It is NOT correct for a
  /// server-driven background pull arriving while unrelated local
  /// dirty edits are queued: the upsert clobbers those edits and
  /// marks the row clean, while the queued Update ops may still be
  /// in flight. A future revision will split this into
  /// `acknowledge(serverEntry, syncQueueId)` and
  /// `mergeFromServer(serverEntry)` with explicit conflict
  /// resolution for the latter. Phase 3 sync-orchestrator scope.
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
