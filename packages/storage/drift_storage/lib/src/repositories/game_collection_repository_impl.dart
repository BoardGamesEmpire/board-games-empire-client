import 'package:cuid2/cuid2.dart';
import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';
import 'watch_disposal.dart';

/// Offline-first implementation of [GameCollectionRepository] backed by
/// the per-server [ServerDatabase] plus a [SyncQueueRepository] for
/// outbound mutations.
///
/// ## ID generation
///
/// Fresh local rows get a [cuid2] id. This matches the backend's id
/// format — the backend uses cuid2 explicitly — so a row's id would be
/// the same string from local creation through to the server cache *if
/// the backend honoured a client-supplied id*. It doesn't: the create DTO
/// has no id field (and the API rejects undeclared properties), so the
/// server assigns its own cuid2 on insert and [reconcileFromServer]
/// handles the id-reassignment path via
/// [SyncQueueRepository.remapCollectionId].
///
/// ## Atomicity
///
/// Every mutation method wraps its local write **and** the matching
/// sync-queue enqueue in a single [GeneratedDatabase.transaction]. If
/// the enqueue fails (e.g. queue table constraint), the local write
/// rolls back so the on-disk state cannot drift away from the sync
/// log. [reconcileFromServer] applies the same rule to the local
/// upsert + the optional `markCompleted` of the originating queue
/// entry: either both land or neither does.
///
/// ## Current-user boundary
///
/// `updateCollectionEntry`, `removeFromCollection`, and `watchEntry`
/// filter by `userId == currentUserId` in addition to `id`. A caller
/// that guesses another user's row id cannot mutate or observe it.
/// The mutation methods preflight the row for the current user and
/// throw [StateError] if it does not exist; the transaction then
/// rolls back without enqueuing a sync op.
///
/// `reconcileFromServer` and `mergeFromServer` extend the same boundary
/// to inbound server responses: they verify `serverEntry.userId ==
/// currentUserId` and throw [StateError] if the response is for a
/// different user. A wrong/stale server response or a buggy caller
/// cannot inject another user's collection row into this repository's
/// cache.
///
/// ## Disposal (#135 / #138 / #150)
///
/// The instance is fixed to one user at construction, so it lives in the
/// **user-session scope** and is disposed whenever that scope pops — which
/// is any exit from the active user session, not only an authentication
/// change: sign-out or session loss, a server switch
/// (`ServerContextImpl.background()`), suspend, and context dispose. Its
/// Drift streams, however, are tied to the per-server [ServerDatabase],
/// which outlives that scope — so disposal is the
/// shared [WatchDisposal] contract, exactly as for
/// `SyncQueueRepositoryImpl` and `HouseholdRepositoryImpl`. Without it, a
/// `watchCollection()` subscription taken under user A would keep
/// emitting A's frozen rows after A signs out and B signs in.
///
/// The contract splits by return type: after `onDispose()` the
/// `Future`-returning methods throw [StateError], while
/// [watchCollection] and [watchEntry] **close** rather than error — a
/// live subscription ends with `onDone` on the scope pop, and a call made
/// after disposal returns an already-closed stream. `UserSessionScopeInstaller`
/// wires `onDispose` as the registration's dispose callback.
///
/// ## Quantity validation
///
/// `addToCollection.quantity` must be `> 0`. `updateCollectionEntry.quantity`
/// must be `> 0` when provided (`null` means "leave unchanged"). Both
/// methods throw [ArgumentError] **before** opening the transaction,
/// so the local cache and sync queue stay untouched on invalid input.
/// `updateCollectionEntry` with every field `null` throws the same way:
/// it has nothing to send. Removing an entry uses [removeFromCollection], not
/// `addToCollection(quantity: 0)` or `updateCollectionEntry(quantity: 0)`.
///
/// ## Tombstones
///
/// `deletedAt` is the canonical tombstone marker (matches the model's
/// [GameCollection.isDeleted] / [GameCollection.deletedAt]). The
/// partial unique index on `(user_id, platform_game_id, medium)
/// WHERE deleted_at IS NULL` lets tombstoned rows coexist with a
/// fresh row for the same triplet, which is what makes the
/// resurrect path in [addToCollection] safe.
///
/// Read and mutation paths all exclude tombstones explicitly:
///
/// - [getCollection] / [watchCollection] filter `deletedAt IS NULL`.
/// - [getCollectionEntry] filters `deletedAt IS NULL`.
/// - [watchEntry] filters `deletedAt IS NULL` so subscribers see
///   `null` (not the tombstoned row) after [removeFromCollection].
/// - [updateCollectionEntry] preflight filters `deletedAt IS NULL`,
///   so an id whose row is tombstoned throws [StateError] rather
///   than silently mutating a removed entry.
/// - [removeFromCollection] is idempotent: re-removing an already
///   tombstoned row is a silent no-op, neither bumping `deletedAt`
///   nor enqueuing a second `RemoveFromCollectionOperation`.
///
/// Tombstones are physically purged by [reconcileFromServer] when
/// the server confirms a removal. The purge is SURGICAL: it
/// deletes tombstones and server-confirmed live rows for the
/// matching triplet, but preserves any local-only live row
/// (`deletedAt == null && isLocalOnly == true`) that represents
/// an unsynced re-add intent. See [reconcileFromServer] for the
/// race scenario the carve-out defends against.
///
/// ## Resurrection preserves play history
///
/// When [addToCollection] finds a tombstoned row for the same
/// `(userId, platformGameId, medium)` triplet, it resurrects that
/// row rather than inserting a new one. The resurrection
/// deliberately preserves per-game metadata that is NOT tied to
/// the current ownership state:
///
/// - **Play history** (`playCount`, `lastPlayed`): factual records
///   of past plays. The user removing an entry means "I don't own
///   this anymore", not "I never played this." Orphaning play
///   stats on every removal would lose data BGG-style tracking
///   relies on (games-I've-played extends past current
///   ownership). The resurrection update does not touch these
///   columns.
/// - **Opinion fields** (`playAgain`, `favorite`): the user's
///   opinion of the GAME, not of the current ownership entry.
///   Preserved on the same principle — surviving an
///   ownership-state toggle.
/// - **Rating / comment**: same semantic as the live-row update
///   path — if the caller supplies a new value, the prior value
///   is overwritten; if null/omitted, the prior value is
///   preserved (`Value.absent()` on the companion).
/// - **Quantity**: always uses the caller-supplied value; the
///   prior quantity was tied to the previous ownership, which is
///   over. (Contrast the live-row branch, which INCREMENTS
///   quantity — a resurrected row is a fresh ownership
///   declaration, not an increment of the prior one.)
/// - **Lifecycle markers** (`deletedAt`, `isDirty`, `isLocalOnly`,
///   `updatedAt`): reset to "new local-only entry" state so the
///   row goes through the normal sync flow.
///
/// ## addToCollection / reconcileFromServer canonical-row lookup
///
/// Both methods need to find "the" canonical local row for a
/// `(userId, platformGameId, medium)` triplet — except the schema
/// permits multiple tombstoned rows per triplet, so a bare
/// [SingleOrNullSelectable.getSingleOrNull] throws [StateError] the
/// moment two or more tombstones coexist. Both methods therefore
/// use the same ordered+limited lookup helper, [_findCanonicalRow]:
///
/// ```text
/// ORDER BY (deletedAt IS NULL) DESC, updatedAt DESC, rowId DESC LIMIT 1
/// ```
///
/// which picks the live row if any, else the most recent tombstone,
/// else nothing — deterministically, never throws. The `rowId DESC`
/// tail breaks ties when multiple rows share the same `updatedAt`
/// (microsecond-precision collision on a fast machine).
///
/// `addToCollection` branches on the result:
///
/// - **No row exists**: fresh insert with a new cuid2 id.
/// - **Live row exists**: increment `quantity` by the requested
///   amount (rating/comment overwritten only if the caller supplied
///   them; existing values otherwise preserved).
/// - **Tombstoned row(s) exist, no live row**: resurrect the **most
///   recent** tombstone — see "Resurrection preserves play history"
///   above for the field-by-field semantics. Older tombstones are
///   left alone.
///
/// Whatever branch fires, an `AddToCollectionOperation` is enqueued
/// with the final post-write quantity; the server is expected to
/// dedup or merge on its side.
///
/// `reconcileFromServer` uses the same helper to detect id
/// reassignment and tombstone confirmation — see [reconcileFromServer]
/// for the full flow.
class GameCollectionRepositoryImpl
    with WatchDisposal
    implements GameCollectionRepository {
  GameCollectionRepositoryImpl({
    required this._db,
    required this._syncQueue,
    required String currentUserId,
    required this._clock,
  }) : _userId = currentUserId;

  final ServerDatabase _db;
  final SyncQueueRepository _syncQueue;
  final String _userId;

  /// Server-corrected time source (#12). Every consensus-relevant
  /// timestamp this repository produces — tombstone [deletedAt],
  /// [updatedAt] (including resurrection), fresh-insert [createdAt] —
  /// comes from [ClockService.nowUtc], never `DateTime.now()`, so a
  /// device with a skewed wall clock cannot win (or lose) cross-device
  /// tombstone tiebreaks by virtue of the skew. UI-display timestamps
  /// carried on the model (`lastPlayed`, `lastUpdated`) are caller- or
  /// server-supplied and are not produced here.
  final ClockService _clock;

  @override
  String get disposedRepositoryName => 'GameCollectionRepository';

  // ── Reads ──────────────────────────────────────────────────────────────────────

  @override
  Future<List<GameCollection>> getCollection() async {
    checkNotDisposed();
    final rows = await (_db.select(
      _db.gameCollectionsTable,
    )..where((t) => t.userId.equals(_userId) & t.deletedAt.isNull())).get();
    return rows.map(_mapRow).toList();
  }

  @override
  Future<GameCollection?> getCollectionEntry({
    required String platformGameId,
    required GameMedium medium,
  }) async {
    checkNotDisposed();
    final row =
        await (_db.select(_db.gameCollectionsTable)..where(
              (t) =>
                  t.userId.equals(_userId) &
                  t.platformGameId.equals(platformGameId) &
                  t.medium.equals(medium.toWire()) &
                  t.deletedAt.isNull(),
            ))
            .getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

  // ── Mutations ─────────────────────────────────────────────────────────────────

  @override
  Future<GameCollection> addToCollection({
    required String platformGameId,
    required GameMedium medium,
    int quantity = 1,
    int? rating,
    String? comment,
  }) async {
    checkNotDisposed();
    // Validate BEFORE opening the transaction so the cache and the
    // sync queue stay untouched on bad input. A zero or negative
    // quantity makes no business sense — the duplicate-triplet path
    // would increment a live row by 0 (no-op DB write that still
    // enqueues an Add op) or DECREMENT it (silently corrupts the
    // count). Use [removeFromCollection] to delete an entry.
    if (quantity <= 0) {
      throw ArgumentError.value(
        quantity,
        'quantity',
        'must be positive (use removeFromCollection to delete an entry)',
      );
    }

    return _db.transaction(() async {
      final now = _clock.nowUtc();
      final wireMedium = medium.toWire();

      final existing = await _findCanonicalRow(
        platformGameId: platformGameId,
        wireMedium: wireMedium,
      );

      final String entryId;
      final int finalQuantity;

      if (existing == null) {
        // Fresh insert. cuid2 id — matches the backend's id format
        // (the backend uses cuid2 explicitly). The server assigns its
        // own id (the create DTO has no id field), so a different
        // canonical id comes back and `reconcileFromServer` calls
        // `_syncQueue.remapCollectionId` to rewrite any pending
        // ops still referencing this local id.
        entryId = cuid();
        finalQuantity = quantity;
        await _db
            .into(_db.gameCollectionsTable)
            .insert(
              GameCollectionsTableCompanion.insert(
                id: entryId,
                userId: _userId,
                platformGameId: platformGameId,
                medium: wireMedium,
                quantity: Value(quantity),
                rating: Value(rating),
                comment: Value(comment),
                isDirty: const Value(true),
                isLocalOnly: const Value(true),
                createdAt: now,
                updatedAt: now,
              ),
            );
      } else if (existing.deletedAt != null) {
        // Resurrect the most recent tombstone. Keep the id (server
        // may still know about it from a prior sync) and the
        // per-game metadata that survives ownership toggles — see
        // the "Resurrection preserves play history" section in the
        // class doc for the full rationale.
        //
        // What this write TOUCHES (lifecycle + caller-supplied):
        //   - deletedAt:    cleared (alive again)
        //   - isDirty:      true (queued for sync)
        //   - isLocalOnly:  true (server hasn't seen this
        //                   re-add yet; reconcileFromServer
        //                   will flip it back after the AddOp
        //                   completes)
        //   - updatedAt:    now
        //   - quantity:     caller-supplied value (a fresh
        //                   ownership declaration, NOT an
        //                   increment of the prior quantity)
        //   - rating:       caller-supplied IF provided;
        //                   else preserved
        //   - comment:      caller-supplied IF provided;
        //                   else preserved
        //
        // What this write LEAVES UNTOUCHED (preserved per-game
        // metadata):
        //   - playCount:    factual play history
        //   - lastPlayed:   factual play history
        //   - playAgain:    opinion about the game itself
        //   - favorite:     opinion about the game itself
        //   - releaseId:    server-managed edition reference
        //   - lastUpdated:  display-only timestamp
        //
        // The Value.absent() guards on rating/comment match the
        // live-row branch's "null means leave-unchanged" semantic,
        // closing an asymmetry where the resurrection
        // branch always overwrote with whatever the caller passed
        // (including null) while the live-row branch preserved.
        entryId = existing.id;
        finalQuantity = quantity;
        await (_db.update(
          _db.gameCollectionsTable,
        )..where((t) => t.id.equals(entryId))).write(
          GameCollectionsTableCompanion(
            quantity: Value(quantity),
            rating: rating != null ? Value(rating) : const Value.absent(),
            comment: comment != null ? Value(comment) : const Value.absent(),
            deletedAt: const Value(null),
            isDirty: const Value(true),
            isLocalOnly: const Value(true),
            updatedAt: Value(now),
          ),
        );
      } else {
        // Live row: increment quantity by the requested amount.
        // Preserve existing rating/comment unless the caller supplied
        // a new value.
        entryId = existing.id;
        finalQuantity = existing.quantity + quantity;
        await (_db.update(
          _db.gameCollectionsTable,
        )..where((t) => t.id.equals(entryId))).write(
          GameCollectionsTableCompanion(
            quantity: Value(finalQuantity),
            rating: rating != null ? Value(rating) : const Value.absent(),
            comment: comment != null ? Value(comment) : const Value.absent(),
            isDirty: const Value(true),
            updatedAt: Value(now),
          ),
        );
      }

      await _syncQueue.enqueue(
        AddToCollectionOperation(
          localId: entryId,
          platformGameId: platformGameId,
          medium: wireMedium,
          quantity: finalQuantity,
          rating: rating,
          comment: comment,
        ),
      );

      final row = await (_db.select(
        _db.gameCollectionsTable,
      )..where((t) => t.id.equals(entryId))).getSingle();
      return _mapRow(row);
    });
  }

  @override
  Future<GameCollection> updateCollectionEntry({
    required String id,
    int? quantity,
    int? rating,
    bool? playAgain,
    bool? favorite,
    String? comment,
  }) async {
    checkNotDisposed();
    // Every field null is an update with nothing in it: the transport
    // rejects that as an empty patch, so queueing it would leave an
    // operation that can never be delivered.
    if (quantity == null &&
        rating == null &&
        playAgain == null &&
        favorite == null &&
        comment == null) {
      throw ArgumentError.value(
        null,
        'fields',
        'at least one field must be supplied — an update with nothing in '
            'it cannot be sent',
      );
    }
    // null = "leave unchanged" by the API contract; only validate
    // when the caller actually supplied a value. Same pre-transaction
    // fail-fast rationale as addToCollection.
    if (quantity != null && quantity <= 0) {
      throw ArgumentError.value(
        quantity,
        'quantity',
        'must be positive when provided (omit to leave unchanged; '
            'use removeFromCollection to delete the entry entirely)',
      );
    }

    return _db.transaction(() async {
      final now = _clock.nowUtc();

      // Preflight: the row must exist, belong to the current user,
      // AND be live (not tombstoned). A tombstoned row is treated as
      // "not found" — mutating a removed entry would leave the local
      // state inconsistent with what the user can see in the UI.
      final existing =
          await (_db.select(_db.gameCollectionsTable)..where(
                (t) =>
                    t.id.equals(id) &
                    t.userId.equals(_userId) &
                    t.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (existing == null) {
        throw StateError(
          'GameCollection entry $id not found for current user '
          '(either absent or already removed)',
        );
      }

      await (_db.update(
        _db.gameCollectionsTable,
      )..where((t) => t.id.equals(id) & t.userId.equals(_userId))).write(
        GameCollectionsTableCompanion(
          quantity: quantity != null ? Value(quantity) : const Value.absent(),
          rating: rating != null ? Value(rating) : const Value.absent(),
          playAgain: playAgain != null
              ? Value(playAgain)
              : const Value.absent(),
          favorite: favorite != null ? Value(favorite) : const Value.absent(),
          comment: comment != null ? Value(comment) : const Value.absent(),
          isDirty: const Value(true),
          updatedAt: Value(now),
        ),
      );

      await _syncQueue.enqueue(
        UpdateCollectionOperation(
          collectionId: id,
          quantity: quantity,
          rating: rating,
          playAgain: playAgain,
          favorite: favorite,
          comment: comment,
        ),
      );

      final row = await (_db.select(
        _db.gameCollectionsTable,
      )..where((t) => t.id.equals(id) & t.userId.equals(_userId))).getSingle();
      return _mapRow(row);
    });
  }

  @override
  Future<void> removeFromCollection(String id) async {
    checkNotDisposed();
    return _db.transaction(() async {
      final now = _clock.nowUtc();

      final existing =
          await (_db.select(_db.gameCollectionsTable)
                ..where((t) => t.id.equals(id) & t.userId.equals(_userId)))
              .getSingleOrNull();
      if (existing == null) {
        // Genuinely missing or cross-user: throw to keep the existing
        // contract for callers that pass an id they shouldn't.
        throw StateError('GameCollection entry $id not found for current user');
      }
      if (existing.deletedAt != null) {
        // Already tombstoned. Re-remove is an idempotent silent
        // no-op: no DB write, no second
        // [RemoveFromCollectionOperation] enqueued. The server
        // already received the original removal.
        return;
      }

      // Tombstone via deletedAt. The partial unique index ignores
      // tombstoned rows, so a subsequent addToCollection on the same
      // triplet can resurrect this row (see addToCollection).
      // Physical purge happens later via reconcileFromServer.
      await (_db.update(
        _db.gameCollectionsTable,
      )..where((t) => t.id.equals(id) & t.userId.equals(_userId))).write(
        GameCollectionsTableCompanion(
          deletedAt: Value(now),
          isDirty: const Value(true),
          updatedAt: Value(now),
        ),
      );

      await _syncQueue.enqueue(RemoveFromCollectionOperation(collectionId: id));
    });
  }

  /// Reconciles a confirmed server response.
  ///
  /// ## Current-user boundary
  ///
  /// Verifies `serverEntry.userId == _userId` and throws [StateError]
  /// otherwise. The repository is scoped to a single user and cannot
  /// silently persist another user's row — a wrong/stale server
  /// response or a buggy caller is a programming error, not a data
  /// condition to absorb.
  ///
  /// ## Id reassignment + pending-op remap
  ///
  /// If the server returns a canonical id different from the local
  /// row's id (always, today: the server assigns ids itself, and the
  /// create DTO has no id field), every op still queued against the local
  /// id would otherwise be sent to the server with an id the server
  /// doesn't know, and drop out of this entry's later acknowledgements.
  /// This method calls [SyncQueueRepository.remapCollectionId] to rewrite
  /// those payloads BEFORE dropping the stale local row. If the backend ever honours
  /// client ids, this branch becomes a no-op (local.id ==
  /// serverEntry.id always) without any client-side change.
  ///
  /// ## Tombstone confirmation (surgical purge)
  ///
  /// When `serverEntry.deletedAt` is non-null, the server has
  /// confirmed a removal. This call deletes every tombstone and
  /// every server-confirmed live row for the matching triplet —
  /// but preserves local-only resurrections
  /// (`deletedAt == null && isLocalOnly == true`) so the
  /// remove→add→stale-confirmation race doesn't clobber the user's
  /// pending re-add. See the interface doc for the race scenario;
  /// the predicate's exclusion clause is the carve-out.
  ///
  /// No upsert of the server entry happens in this branch; row
  /// identity is owned by the queue from here on.
  ///
  /// ## Live-entry upsert, then replay
  ///
  /// When `serverEntry.deletedAt` is null, the local row is
  /// upserted with `isDirty: false, isLocalOnly: false`. If the
  /// local row had a different id, that stale row is dropped
  /// before the upsert (after the remap). Then the ops still queued
  /// for the entry are replayed over it, and the row stays dirty while
  /// any remain (#429) — see [_replayOutstanding].
  ///
  /// A server-driven pull uses [mergeFromServer] instead, which
  /// gives way to a dirty or local-only row (#259).
  ///
  /// ## Sync-queue closure
  ///
  /// If [completedSyncQueueId] is provided, the matching queue
  /// entry is marked completed in the same Drift transaction. If
  /// any step throws, all writes roll back together.
  ///
  /// This is the one method whose caller is a background drain (#121)
  /// rather than the UI, so its post-disposal behaviour is worth stating:
  /// if the user-session scope pops between the send and the reconcile,
  /// this throws and the queue entry stays `pending`. Relaxing the
  /// [checkNotDisposed] guard would not change that — [SyncQueueRepository]
  /// is disposed by the same scope pop, so `markCompleted` (and
  /// `remapCollectionId`) would throw inside the transaction and roll the
  /// whole thing back anyway. The op is then sent again. A re-sent add
  /// can't duplicate the server row, because adding is an upsert on
  /// `(userId, platformGameId, medium)`; but it re-applies an absolute
  /// quantity and clears a tombstone, so if the user changed or removed
  /// the entry since, the stale op overwrites the newer intent. That
  /// ordering is the drain worker's problem, tracked on #121.
  @override
  Future<void> reconcileFromServer(
    GameCollection serverEntry, {
    String? completedSyncQueueId,
  }) async {
    checkNotDisposed();
    // Boundary check: fail fast BEFORE opening the transaction so
    // the local cache and sync queue stay untouched on a
    // misrouted server response.
    _checkServerEntryUser(serverEntry, caller: 'reconcileFromServer');

    return _db.transaction(() async {
      await _writeServerEntry(serverEntry);

      // Put back what is still queued for the entry (#429). Before the
      // markCompleted below, so the lookup still sees the acknowledged op
      // and can tell which of the others came after it.
      if (serverEntry.deletedAt == null) {
        await _replayOutstanding(
          serverEntry,
          acknowledgedSyncQueueId: completedSyncQueueId,
        );
      }

      // Close the loop with the queued op that triggered this server
      // write, if the caller knows which one it was. Drift's
      // zone-scoped transactions mean the sync-queue update
      // participates in the same transaction as the writes above:
      // if either step throws, both roll back together.
      if (completedSyncQueueId != null) {
        await _syncQueue.markCompleted(completedSyncQueueId);
      }
    });
  }

  /// Re-applies the ops still queued for [serverEntry] over the clean row
  /// [_writeServerEntry] just wrote, and keeps it dirty while any remain
  /// (#429). Runs inside the caller's transaction.
  ///
  /// "Still queued" is every op for the entry that isn't completed,
  /// claimed and exhausted ones included. The remap in [_writeServerEntry]
  /// has already moved all of them to the server id, so they are found by
  /// it on this acknowledgement and on every later one.
  ///
  /// Only the ops queued **after** the acknowledged one are replayed. The
  /// server's answer already reflects the acknowledged op, so an older op
  /// still outstanding (an exhausted one, say) would put back a value the
  /// newer change replaced. An older op still keeps the row dirty: the
  /// change it carries never reached the server. The lookup returns the
  /// acknowledged op even once completed, so a second delivery's
  /// acknowledgement, after the first completed it, still places it. When
  /// it can't be placed (the caller didn't name it, or it was purged), its
  /// position is unknown, and every outstanding op is replayed.
  ///
  /// The ops carry what the local writes recorded, so replaying them is
  /// those writes again: an add sets its absolute quantity and any rating
  /// or comment it carried, and revives the entry; an update sets the
  /// fields it carries and leaves the rest; a remove tombstones. An add
  /// that revives an entry the replay had tombstoned is a re-add the
  /// server hasn't seen, so the row is local-only, as `addToCollection`
  /// leaves it. That keeps the tombstone purge, when the removal is
  /// acknowledged, from deleting the re-add.
  Future<void> _replayOutstanding(
    GameCollection serverEntry, {
    required String? acknowledgedSyncQueueId,
  }) async {
    final outstanding = await _syncQueue.getOutstandingOpsFor(
      serverEntry.id,
      including: acknowledgedSyncQueueId,
    );
    final acknowledgedIndex = outstanding.indexWhere(
      (queued) => queued.id == acknowledgedSyncQueueId,
    );
    final stillQueued = outstanding.length - (acknowledgedIndex < 0 ? 0 : 1);
    if (stillQueued == 0) return;

    final now = _clock.nowUtc();
    var replayed = serverEntry;
    var isLocalOnly = false;
    for (final queued in outstanding.skip(acknowledgedIndex + 1)) {
      switch (queued.operation) {
        case AddToCollectionOperation(
          :final quantity,
          :final rating,
          :final comment,
        ):
          if (replayed.deletedAt != null) isLocalOnly = true;
          replayed = replayed.copyWith(
            quantity: quantity,
            rating: rating ?? replayed.rating,
            comment: comment ?? replayed.comment,
            deletedAt: null,
          );
        case UpdateCollectionOperation(
          :final quantity,
          :final rating,
          :final playAgain,
          :final favorite,
          :final comment,
        ):
          replayed = replayed.copyWith(
            quantity: quantity ?? replayed.quantity,
            rating: rating ?? replayed.rating,
            playAgain: playAgain ?? replayed.playAgain,
            favorite: favorite ?? replayed.favorite,
            comment: comment ?? replayed.comment,
          );
        case RemoveFromCollectionOperation():
          replayed = replayed.copyWith(deletedAt: now);
        case CreateHouseholdOperation():
          // The lookup returns collection ops only.
          break;
      }
    }

    await _db
        .into(_db.gameCollectionsTable)
        .insertOnConflictUpdate(
          _modelToCompanion(
            replayed.copyWith(
              isDirty: true,
              isLocalOnly: isLocalOnly,
              updatedAt: now,
            ),
          ),
        );
  }

  /// Merges server entries no local mutation asked for (#259).
  ///
  /// The checks and the writes share one transaction, so a local edit
  /// cannot land between "no row is dirty" and the upsert that would
  /// overwrite it. See the interface doc for the
  /// cases the check covers.
  @override
  Future<void> mergeFromServer(List<GameCollection> serverEntries) async {
    checkNotDisposed();
    for (final serverEntry in serverEntries) {
      _checkServerEntryUser(serverEntry, caller: 'mergeFromServer');
    }
    if (serverEntries.isEmpty) return;

    return _db.transaction(() async {
      for (final serverEntry in serverEntries) {
        if (await _localRowWins(serverEntry)) continue;
        await _writeServerEntry(serverEntry);
      }
    });
  }

  /// Throws [StateError] when [serverEntry] belongs to another user.
  void _checkServerEntryUser(
    GameCollection serverEntry, {
    required String caller,
  }) {
    if (serverEntry.userId != _userId) {
      throw StateError(
        '$caller received an entry for userId '
        '"${serverEntry.userId}" but this repository is scoped to '
        '"$_userId". Server response routing is misconfigured.',
      );
    }
  }

  /// Whether a row standing where [serverEntry] would land must be kept:
  /// one with its id, or any row for its triplet, that is dirty or
  /// local-only, or that is clean and holds a copy the server stamped
  /// later than [serverEntry].
  ///
  /// The whole triplet, tombstones included, rather than only the
  /// canonical row: the tombstone purge deletes every row for the
  /// triplet, so a dirty tombstone behind a clean live row would
  /// otherwise be purged along with it.
  ///
  /// The `updatedAt` comparison is sound only for a clean row, whose
  /// stamp is the server's: [_writeServerEntry] is the one write that
  /// clears the flags, and it stores the server's `updatedAt`. A dirty
  /// row's stamp is the local clock's, but a dirty row is kept anyway.
  Future<bool> _localRowWins(GameCollection serverEntry) async {
    final rows =
        await (_db.select(_db.gameCollectionsTable)..where(
              (t) =>
                  t.userId.equals(_userId) &
                  (t.id.equals(serverEntry.id) |
                      (t.platformGameId.equals(serverEntry.platformGameId) &
                          t.medium.equals(serverEntry.medium.toWire()))),
            ))
            .get();
    return rows.any(
      (row) =>
          row.isDirty ||
          row.isLocalOnly ||
          row.updatedAt.isAfter(serverEntry.updatedAt),
    );
  }

  /// The write both server paths share: remap on id reassignment, then
  /// purge on a tombstone or upsert a live entry clean. Runs inside the
  /// caller's transaction.
  Future<void> _writeServerEntry(GameCollection serverEntry) async {
    // Look up any local row for the same triplet (live or
    // tombstoned). The schema permits multiple tombstones per
    // triplet, so this uses the same ordered+limited helper as
    // addToCollection: picks the live row if any, else the most
    // recent tombstone, else nothing — never throws.
    final local = await _findCanonicalRow(
      platformGameId: serverEntry.platformGameId,
      wireMedium: serverEntry.medium.toWire(),
    );

    // Id reassignment: rewrite every op still queued against the
    // OLD local id, so none gets sent to the server with an unknown
    // id once we drop the local row below, and the replay finds
    // them all under the server id (#429).
    if (local != null && local.id != serverEntry.id) {
      await _syncQueue.remapCollectionId(
        oldCollectionId: local.id,
        newCollectionId: serverEntry.id,
      );
    }

    final serverIsTombstone = serverEntry.deletedAt != null;

    if (serverIsTombstone) {
      await (_db.delete(_db.gameCollectionsTable)..where(
            (t) =>
                t.userId.equals(_userId) &
                t.platformGameId.equals(serverEntry.platformGameId) &
                t.medium.equals(serverEntry.medium.toWire()) &
                (t.deletedAt.isNotNull() | t.isLocalOnly.equals(false)),
          ))
          .go();
    } else {
      // Live entry path. Drop the stale local row if its id
      // differs (after we already remapped any pending ops
      // referencing it above), then upsert with the canonical
      // server id.
      if (local != null && local.id != serverEntry.id) {
        await (_db.delete(
          _db.gameCollectionsTable,
        )..where((t) => t.id.equals(local.id))).go();
      }
      await _db
          .into(_db.gameCollectionsTable)
          .insertOnConflictUpdate(
            _modelToCompanion(
              serverEntry.copyWith(isDirty: false, isLocalOnly: false),
            ),
          );
    }
  }

  // ── Streams ──────────────────────────────────────────────────────────────────

  @override
  Stream<List<GameCollection>> watchCollection() => untilDisposed(
    () =>
        (_db.select(_db.gameCollectionsTable)
              ..where((t) => t.userId.equals(_userId) & t.deletedAt.isNull()))
            .watch()
            .map((rows) => rows.map(_mapRow).toList()),
  );

  /// One query joining the entry to its platform game and game, so
  /// Drift re-runs it when any of the three tables changes (#259).
  ///
  /// Inner joins: `game_collections.platform_game_id` and
  /// `platform_games.game_id` are enforced foreign keys, so an outer
  /// join would only add a null case that cannot occur.
  @override
  Stream<List<GameCollectionListItem>> watchCollectionListItems() =>
      untilDisposed(() {
        final entries = _db.gameCollectionsTable;
        final platformGames = _db.platformGamesTable;
        final games = _db.gamesTable;

        final query =
            _db.select(entries).join([
                innerJoin(
                  platformGames,
                  platformGames.id.equalsExp(entries.platformGameId),
                ),
                innerJoin(games, games.id.equalsExp(platformGames.gameId)),
              ])
              ..where(
                entries.userId.equals(_userId) & entries.deletedAt.isNull(),
              )
              ..orderBy([
                OrderingTerm.asc(games.title.collate(Collate.noCase)),
                OrderingTerm.asc(entries.id),
              ]);

        return query.watch().map(
          (rows) => [
            for (final row in rows)
              _mapListItem(
                row.readTable(entries),
                row.readTable(platformGames),
                row.readTable(games),
              ),
          ],
        );
      });

  @override
  Stream<GameCollection?> watchEntry(String id) => untilDisposed(
    () =>
        (_db.select(_db.gameCollectionsTable)..where(
              (t) =>
                  t.id.equals(id) &
                  t.userId.equals(_userId) &
                  t.deletedAt.isNull(),
            ))
            .watchSingleOrNull()
            .map((row) => row == null ? null : _mapRow(row)),
  );

  // ── Helpers ──────────────────────────────────────────────────────────────────────

  /// Look up the canonical row for a `(_userId, platformGameId,
  /// medium)` triplet. See the class doc for the ordering rationale.
  Future<GameCollectionsTableData?> _findCanonicalRow({
    required String platformGameId,
    required String wireMedium,
  }) async {
    return ((_db.select(_db.gameCollectionsTable)..where(
            (t) =>
                t.userId.equals(_userId) &
                t.platformGameId.equals(platformGameId) &
                t.medium.equals(wireMedium),
          ))
          ..orderBy([
            // Live row first: `deletedAt IS NULL` evaluates to 1 for
            // live rows, 0 for tombstones; DESC ranks 1 ahead of 0.
            (t) => OrderingTerm(
              expression: t.deletedAt.isNull(),
              mode: OrderingMode.desc,
            ),
            // Among tombstones (or as tiebreaker among live rows —
            // there's at most one but the partial index doesn't
            // prevent older orphans from a corrupt state), prefer
            // the most recently touched row.
            (t) => OrderingTerm.desc(t.updatedAt),
            // Deterministic tiebreaker when multiple rows share the
            // same updatedAt. ClockService.nowUtc() resolves to
            // microseconds, so two tombstones produced by a fast
            // addToCollection → removeFromCollection burst on a
            // quick machine can land on the same microsecond (the
            // skew clock's monotonic guard can even pin successive
            // calls to an identical instant) — in
            // which case the prior `(deletedAt IS NULL) DESC,
            // updatedAt DESC` ordering would let SQLite pick either
            // row implementation-definedly, so the resurrection path
            // in addToCollection could revive different tombstones
            // across runs. SQLite assigns rowids in insertion order
            // on non-WITHOUT-ROWID tables; `.desc(rowId)` therefore
            // selects the most recently inserted row when updatedAt
            // is identical, which is the consistent extension of
            // "prefer the most recent tombstone" already encoded in
            // the previous term.
            (t) => OrderingTerm.desc(t.rowId),
          ])
          ..limit(1))
        .getSingleOrNull();
  }

  // ── Mappers ───────────────────────────────────────────────────────────────────

  GameCollection _mapRow(GameCollectionsTableData row) => GameCollection(
    id: row.id,
    userId: row.userId,
    platformGameId: row.platformGameId,
    medium: GameMedium.fromWire(row.medium),
    releaseId: row.releaseId,
    quantity: row.quantity,
    rating: row.rating,
    playCount: row.playCount,
    playAgain: row.playAgain,
    favorite: row.favorite,
    comment: row.comment,
    lastPlayed: row.lastPlayed,
    lastUpdated: row.lastUpdated,
    isDirty: row.isDirty,
    isLocalOnly: row.isLocalOnly,
    deletedAt: row.deletedAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  GameCollectionListItem _mapListItem(
    GameCollectionsTableData entry,
    PlatformGamesTableData platformGame,
    GamesTableData game,
  ) => GameCollectionListItem(
    entry: _mapRow(entry),
    title: game.title,
    subtitle: game.subtitle,
    platformName: platformGame.platformName,
    thumbnail: platformGame.thumbnail ?? game.thumbnail,
  );

  GameCollectionsTableCompanion _modelToCompanion(GameCollection m) =>
      GameCollectionsTableCompanion.insert(
        id: m.id,
        userId: m.userId,
        platformGameId: m.platformGameId,
        medium: m.medium.toWire(),
        releaseId: Value(m.releaseId),
        quantity: Value(m.quantity),
        rating: Value(m.rating),
        playCount: Value(m.playCount),
        playAgain: Value(m.playAgain),
        favorite: Value(m.favorite),
        comment: Value(m.comment),
        lastPlayed: Value(m.lastPlayed),
        lastUpdated: Value(m.lastUpdated),
        isDirty: Value(m.isDirty),
        isLocalOnly: Value(m.isLocalOnly),
        deletedAt: Value(m.deletedAt),
        createdAt: m.createdAt,
        updatedAt: m.updatedAt,
      );
}
