import 'package:cuid2/cuid2.dart';
import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';
import 'game_cache_access.dart';
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
/// Tombstones are physically purged when the server confirms a
/// removal: by [reconcileFromServer] when it returns a tombstone, or
/// by [confirmRemoved] when it reports the removal already done. The
/// purge is SURGICAL, and the same for both: it deletes tombstones
/// and server-confirmed live rows for the matching triplet, but
/// preserves any local-only live row
/// (`deletedAt == null && isLocalOnly == true`) that represents
/// an unsynced re-add intent. See [reconcileFromServer] for the
/// race scenario the carve-out defends against.
///
/// A purge can end the user's `collection` records (#469). Their record
/// for a platform game ends once they have no entry on it, in any medium,
/// live, tombstoned or local-only. Their record for the game ends once
/// they have no entry on any of its platform games. Cached `games` and
/// `platform_games` rows that no one can read then are deleted.
///
/// Each transaction that purges, a merge of a server tombstone included,
/// releases the platform games it purged in one call, after its last
/// write to `game_collections`. So a spared re-add, or a live entry the
/// same merge writes after a tombstone, still holds the record. A discard
/// releases right after it deletes a local-only entry. A hydrate page in
/// flight can lose its rows to a release: see `GameCollectionHydrator`.
///
/// A confirmed removal is also counted, so a hydrate page the server
/// answered before it cannot write the entry back: see [removalMark].
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
/// ORDER BY (deletedAt IS NULL) DESC, JULIANDAY(updatedAt) DESC,
///   rowId DESC LIMIT 1
/// ```
///
/// which picks the live row if any, else the most recent tombstone,
/// else nothing — deterministically, never throws. `updatedAt` is
/// compared as an instant, not as its ISO-8601 text, which misorders
/// two values within one millisecond (#441). The `rowId DESC` tail
/// breaks ties when multiple rows fall in the same millisecond.
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
  }) : _userId = currentUserId,
       _access = GameCacheAccess(_db);

  final ServerDatabase _db;
  final SyncQueueRepository _syncQueue;
  final String _userId;

  /// Ends the user's `collection` records once their last entry for a
  /// platform game goes (#469).
  final GameCacheAccess _access;

  /// The platform games the open transaction purged entries on, for it to
  /// release once its other writes are done (#469). Open only inside
  /// [_purgingTransaction], which [reconcileFromServer], [confirmRemoved]
  /// and [mergeFromServer] run in, and null again once they release or
  /// throw, so a purge anywhere else throws rather than skipping its
  /// release.
  ///
  /// A field, not a parameter through [_writeServerEntry]: drift runs the
  /// transactions on one database one at a time, so two never share it.
  Set<String>? _released;

  /// Server-corrected time source (#12). Every consensus-relevant
  /// timestamp this repository produces — tombstone [deletedAt],
  /// [updatedAt] (including resurrection), fresh-insert [createdAt] —
  /// comes from [ClockService.nowUtc], never `DateTime.now()`, so a
  /// device with a skewed wall clock cannot win (or lose) cross-device
  /// tombstone tiebreaks by virtue of the skew. UI-display timestamps
  /// carried on the model (`lastPlayed`, `lastUpdated`) are caller- or
  /// server-supplied and are not produced here.
  final ClockService _clock;

  /// What [removalMark] reads. It moves on each removal
  /// [reconcileFromServer] and [confirmRemoved] confirm through this
  /// instance, and on each discard that leaves a row to rebuild (#190).
  int _mark = 0;

  /// Where [_mark] stood after each triplet's latest confirmed removal,
  /// keyed by `(platformGameId, wire medium)`.
  final Map<(String, String), int> _removedAt = {};

  /// Entries a discard left holding values no queued op set, each with where
  /// [_mark] stood after the discard: the first [mergeFromServer] of a read
  /// made since that writes the server's copy rebuilds the entry from it,
  /// and an earlier read leaves it alone (#190). In memory, so a restart
  /// before that merge leaves the values on an entry another op keeps dirty
  /// until that op settles. An entry nothing keeps dirty takes the next
  /// read's copy then. Nor does another tab's acknowledgement clear it: on
  /// an entry another op keeps dirty, a read asked for before that
  /// acknowledgement rebuilds over it, until that op settles.
  final Map<String, int> _rebuildFromServer = {};

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

  @override
  Future<Set<String>> getLocalOnlyIds() async {
    checkNotDisposed();
    final rows =
        await (_db.select(_db.gameCollectionsTable)..where(
              (t) => t.userId.equals(_userId) & t.isLocalOnly.equals(true),
            ))
            .get();
    return {for (final row in rows) row.id};
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
      bool? raised;

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
        raised = true;
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
          raised: raised,
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
      // Physical purge happens later, via reconcileFromServer or
      // confirmRemoved.
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
  /// identity is owned by the queue from here on. The removal is counted
  /// for [removalMark].
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
  /// this throws and the queue entry stays claimed until its lease runs
  /// out. Relaxing the [checkNotDisposed] guard would not change that —
  /// [SyncQueueRepository] is disposed by the same scope pop, so
  /// `markCompleted` (and `remapCollectionId`) would throw inside the
  /// transaction and roll the whole thing back anyway. The op is then sent
  /// again. A re-sent add can't duplicate the server row, because adding is
  /// an upsert on `(userId, platformGameId, medium)`. The drain keeps one
  /// entry's ops in queue order, so the re-send goes out before any op
  /// queued behind it; the cost accepted is an op delivered while the
  /// re-send's claim still held it, which the re-send then overwrites
  /// (#430).
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

    return _purgingTransaction(() async {
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
      await _releasePurged();

      if (serverEntry.deletedAt != null) {
        _countRemoval(
          platformGameId: serverEntry.platformGameId,
          wireMedium: serverEntry.medium.toWire(),
        );
      }
      // The acknowledgement rebuilds the row itself, from a newer copy than a
      // hydrate page read before it. Cleared in the transaction, so a discard
      // that runs while this waits for it records its rebuild first.
      _rebuildFromServer.remove(serverEntry.id);
    });
  }

  /// Purges the triplet of the row [collectionId] names, as a tombstone
  /// confirmation does, and completes [completedSyncQueueId] in the same
  /// transaction (#121).
  ///
  /// The drain's answer to an already-removed 404, which carries no entry to
  /// reconcile. The triplet comes from the local row instead; with no row
  /// under that id there is nothing to purge, and only the op is completed.
  /// A purge is counted for [removalMark], as a returned tombstone's is.
  /// Like [reconcileFromServer], a scope popping mid-call throws and rolls
  /// both writes back, and the op is sent again.
  @override
  Future<void> confirmRemoved(
    String collectionId, {
    required String completedSyncQueueId,
  }) async {
    checkNotDisposed();
    return _purgingTransaction(() async {
      final local =
          await (_db.select(_db.gameCollectionsTable)..where(
                (t) => t.id.equals(collectionId) & t.userId.equals(_userId),
              ))
              .getSingleOrNull();
      if (local != null) {
        await _purgeRemovedTriplet(
          platformGameId: local.platformGameId,
          wireMedium: local.medium,
        );
      }
      await _syncQueue.markCompleted(completedSyncQueueId);
      await _releasePurged();
      if (local != null) {
        _countRemoval(
          platformGameId: local.platformGameId,
          wireMedium: local.medium,
        );
      }
      _rebuildFromServer.remove(collectionId);
    });
  }

  /// The stamp a discard leaves on a row it settles (#190): older than any
  /// copy the server holds.
  ///
  /// A clean row's `updatedAt` is otherwise the server's, and a merge keeps
  /// a clean row stamped later than the copy it brings. The settled row
  /// holds values the server never had, so it must lose that comparison.
  static final DateTime _olderThanAnyServerCopy = DateTime.utc(1970);

  @override
  Future<bool> discardQueuedOp(String syncQueueId) async {
    checkNotDisposed();
    return _db.transaction(() async {
      final entry = await _syncQueue.getEntry(syncQueueId);
      if (entry == null) return false;

      final SyncOperation op;
      try {
        op = entry.operation;
      } on Object {
        // Nothing it did can be read back, so there is nothing to undo.
        return _syncQueue.discardStuck(entry.id);
      }
      final target = switch (op) {
        AddToCollectionOperation(:final localId) => localId,
        UpdateCollectionOperation(:final collectionId) => collectionId,
        RemoveFromCollectionOperation(:final collectionId) => collectionId,
        CreateHouseholdOperation() => throw ArgumentError.value(
          syncQueueId,
          'syncQueueId',
          'names a household op; HouseholdRepository discards those',
        ),
        CreateEventOperation() => throw ArgumentError.value(
          syncQueueId,
          'syncQueueId',
          'names an event op; EventRepository discards those',
        ),
      };

      final row =
          await (_db.select(_db.gameCollectionsTable)
                ..where((t) => t.id.equals(target) & t.userId.equals(_userId)))
              .getSingleOrNull();
      final queued = await _syncQueue.getOutstandingOpsFor(target);
      final at = queued.indexWhere((q) => q.id == entry.id);
      final earlier = queued.take(at < 0 ? queued.length : at).toList();
      final later = at < 0 ? const <SyncQueueEntry>[] : queued.sublist(at + 1);

      // An add or a removal goes with every op queued after it for the
      // entry, which all assumed it: the entry goes back to how it was before
      // it. An update goes alone.
      final rollsBack = op is! UpdateCollectionOperation;
      // One of those may be on its way to the server: an op behind a stuck
      // one is sent unless it is held. Its acknowledgement would bring back
      // what this discards.
      if (rollsBack &&
          later.any((queuedOp) => queuedOp.status == SyncStatus.inProgress)) {
        throw StateError(
          'A later op for this entry is being sent; discard it once that '
          'settles',
        );
      }

      // Checked in the statement that deletes it: an op another tab retried
      // since may be on its way to the server, so nothing is undone for it.
      if (!await _syncQueue.discardStuck(entry.id)) return false;
      if (rollsBack) {
        for (final queuedOp in later) {
          await _syncQueue.discard(queuedOp.id);
        }
      }
      if (row == null) return true;

      final kept = rollsBack ? earlier : [...earlier, ...later];
      final settled = kept.isEmpty;
      if (!rollsBack) {
        await (_db.update(
          _db.gameCollectionsTable,
        )..where((t) => t.id.equals(row.id))).write(
          GameCollectionsTableCompanion(
            isDirty: Value(!settled),
            updatedAt: settled
                ? Value(_olderThanAnyServerCopy)
                : const Value.absent(),
          ),
        );
        if (!row.isLocalOnly) _rebuildFromServer[row.id] = ++_mark;
        return true;
      }

      // A row that isn't local-only is one the server has now. Otherwise the
      // server sees it only once an add still queued before this op arrives.
      final unseen =
          row.isLocalOnly &&
          kept.any((queuedOp) => _createsEntry(queuedOp.operation));
      var removed = false;
      if (_createsEntry(op)) {
        final before = earlier
            .map((queuedOp) => queuedOp.operation)
            .where(
              (queued) =>
                  queued is AddToCollectionOperation ||
                  queued is RemoveFromCollectionOperation,
            )
            .lastOrNull;
        if (before is RemoveFromCollectionOperation) {
          // A re-add over a removal still queued: back to its tombstone.
          removed = true;
        } else if (before != null && _createsEntry(before)) {
          // Queued over an entry an earlier add still queued created, so it
          // raised the quantity, though an add queued before raises were
          // recorded doesn't say so. The entry stays that add's.
        } else if (row.isLocalOnly) {
          // It created the entry, or revived it once the server had
          // confirmed the removal. Nothing else on this device holds it.
          await (_db.delete(
            _db.gameCollectionsTable,
          )..where((t) => t.id.equals(row.id))).go();
          await _access.releaseCollection(
            userId: _userId,
            platformGameIds: {row.platformGameId},
          );
          return true;
        }
        // Otherwise a later add reached the server while this one was stuck,
        // and the server has the entry.
      }
      final now = _clock.nowUtc();
      await (_db.update(
        _db.gameCollectionsTable,
      )..where((t) => t.id.equals(row.id))).write(
        GameCollectionsTableCompanion(
          deletedAt: Value(removed ? now : null),
          isDirty: Value(!settled),
          isLocalOnly: Value(unseen),
          updatedAt: Value(settled ? _olderThanAnyServerCopy : now),
        ),
      );
      if (!unseen) _rebuildFromServer[row.id] = ++_mark;
      return true;
    });
  }

  /// Whether [op] puts the entry on the server: an add that created it or
  /// revived it from a removal, rather than one that raised its quantity.
  static bool _createsEntry(SyncOperation op) =>
      op is AddToCollectionOperation && op.raised != true;

  @override
  Future<String?> titleOf(String collectionId) async {
    checkNotDisposed();
    final entries = _db.gameCollectionsTable;
    final platformGames = _db.platformGamesTable;
    final games = _db.gamesTable;
    // Inner joins, as the list query's: both parents are enforced keys.
    final row =
        await (_db.selectOnly(entries).join([
                innerJoin(
                  platformGames,
                  platformGames.id.equalsExp(entries.platformGameId),
                  useColumns: false,
                ),
                innerJoin(
                  games,
                  games.id.equalsExp(platformGames.gameId),
                  useColumns: false,
                ),
              ])
              ..addColumns([games.title])
              ..where(
                entries.id.equals(collectionId) &
                    entries.userId.equals(_userId),
              ))
            .getSingleOrNull();
    return row?.read(games.title);
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
  /// change it carries never reached the server. Its edit stops showing,
  /// though, even in fields the newer change didn't carry: an exhausted
  /// rating edit is gone from the row once a later quantity edit is
  /// acknowledged. Those fields are not replayed (#190): the row shows the
  /// server's value until the stuck op is retried or discarded. The lookup
  /// returns the acknowledged op even once completed, so a second
  /// delivery's acknowledgement, after the first completed it, still places
  /// it. When it can't be placed (the caller didn't name it, or it was
  /// purged), its position is unknown, and every outstanding op is
  /// replayed.
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
        case CreateEventOperation():
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

  @override
  Future<int> removalMark() async {
    checkNotDisposed();
    return _mark;
  }

  /// Merges server entries no local mutation asked for (#259).
  ///
  /// The checks and the writes share one transaction, so a local edit
  /// cannot land between "no row is dirty" and the upsert that would
  /// overwrite it. See the interface doc for the
  /// cases the check covers.
  @override
  Future<void> mergeFromServer(
    List<GameCollection> serverEntries, {
    required int removalsSince,
  }) async {
    checkNotDisposed();
    for (final serverEntry in serverEntries) {
      _checkServerEntryUser(serverEntry, caller: 'mergeFromServer');
    }
    if (serverEntries.isEmpty) return;

    return _purgingTransaction(() async {
      for (final serverEntry in serverEntries) {
        // A read made before the discard can predate an acknowledgement
        // that came before it, so it leaves the entry to a later read. The
        // entry may be clean by then, with nothing left to keep it. A copy
        // the row keeps out, such as a removal, leaves it to a later one too.
        final discardedAt = _rebuildFromServer[serverEntry.id];
        if (discardedAt != null) {
          if (removalsSince < discardedAt) continue;
          if (await _rebuild(serverEntry, removalsSince: removalsSince)) {
            _rebuildFromServer.remove(serverEntry.id);
            continue;
          }
        }
        if (await _localRowWins(serverEntry)) continue;
        if (_removedSince(serverEntry, removalsSince)) continue;
        _rebuildFromServer.remove(serverEntry.id);
        await _writeServerEntry(serverEntry);
      }
      // After the whole page: a live entry later in it may hold a platform
      // game an earlier tombstone purged.
      await _releasePurged();
    });
  }

  /// Writes [serverEntry] over the row a discard left under its id,
  /// then replays the ops still queued for it (#190). Returns false,
  /// writing nothing, when anything else would keep the row: a server
  /// tombstone, a removal confirmed since the read, the row being
  /// local-only, another row for the triplet that is dirty or local-only, or
  /// a clean row the server stamped later than [serverEntry].
  ///
  /// The ops are placed against the one delivered last, as its
  /// acknowledgement placed them, so a stuck op queued before it stays out
  /// of the row. Once the queue has purged that op, every op still queued
  /// is replayed, and an older stuck edit shows again over a newer one the
  /// server has.
  Future<bool> _rebuild(
    GameCollection serverEntry, {
    required int removalsSince,
  }) async {
    if (serverEntry.deletedAt != null) return false;
    if (_removedSince(serverEntry, removalsSince)) return false;
    final rows =
        await (_db.select(_db.gameCollectionsTable)..where(
              (t) =>
                  t.userId.equals(_userId) &
                  (t.id.equals(serverEntry.id) |
                      (t.platformGameId.equals(serverEntry.platformGameId) &
                          t.medium.equals(serverEntry.medium.toWire()))),
            ))
            .get();
    // A clean row stamped later than the copy holds one written since the
    // read, such as by another tab, which has no record of the discard.
    final ownsIt = rows.every(
      (row) =>
          !row.isLocalOnly &&
          (row.isDirty
              ? row.id == serverEntry.id
              : !row.updatedAt.isAfter(serverEntry.updatedAt)),
    );
    if (!ownsIt || rows.every((row) => row.id != serverEntry.id)) {
      return false;
    }
    await _writeServerEntry(serverEntry);
    final lastDelivered = await _syncQueue.lastDeliveredOpFor(serverEntry.id);
    await _replayOutstanding(
      serverEntry,
      acknowledgedSyncQueueId: lastDelivered?.id,
    );
    return true;
  }

  /// Counts a confirmed removal of the triplet, for [mergeFromServer]'s
  /// `removalsSince`.
  ///
  /// Called inside the confirming transaction, after its last write. A
  /// merge's transaction then either runs before this one, while the row
  /// is still dirty, or after it commits, and finds the count.
  void _countRemoval({
    required String platformGameId,
    required String wireMedium,
  }) {
    _removedAt[(platformGameId, wireMedium)] = ++_mark;
  }

  /// Whether [serverEntry] is a live copy of a triplet this instance
  /// confirmed removed after [removalsSince] was read.
  bool _removedSince(GameCollection serverEntry, int removalsSince) {
    if (serverEntry.deletedAt != null) return false;
    final removedAt =
        _removedAt[(serverEntry.platformGameId, serverEntry.medium.toWire())];
    return removedAt != null && removedAt > removalsSince;
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
      await _purgeRemovedTriplet(
        platformGameId: serverEntry.platformGameId,
        wireMedium: serverEntry.medium.toWire(),
      );
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

  /// Deletes what a confirmed removal leaves behind for a triplet: every
  /// tombstone and every server-confirmed live row. A local-only live row is
  /// kept, because it is a re-add the queue has yet to send (see
  /// [reconcileFromServer]'s race). Runs inside the caller's transaction.
  ///
  /// Shared by the two confirmations, a tombstone the server returned and a
  /// removal it reports as already done, so they spare the same rows. The
  /// platform game goes in [_released], for the caller to release once its
  /// other writes are done (#469).
  Future<void> _purgeRemovedTriplet({
    required String platformGameId,
    required String wireMedium,
  }) async {
    await (_db.delete(_db.gameCollectionsTable)..where(
          (t) =>
              t.userId.equals(_userId) &
              t.platformGameId.equals(platformGameId) &
              t.medium.equals(wireMedium) &
              (t.deletedAt.isNotNull() | t.isLocalOnly.equals(false)),
        ))
        .go();
    _released!.add(platformGameId);
  }

  /// Runs [body] in a transaction with [_released] open for the platform
  /// games it purges, and null again however [body] ends (#469). [body]
  /// releases them itself, with [_releasePurged], once its other writes are
  /// done.
  Future<void> _purgingTransaction(Future<void> Function() body) =>
      _db.transaction(() async {
        _released = {};
        try {
          await body();
          assert(
            _released == null,
            'A purging transaction ended without releasing what it purged',
          );
        } finally {
          _released = null;
        }
      });

  /// Releases the platform games the open transaction purged (#469), and
  /// closes [_released]. Runs inside the caller's transaction, after its
  /// last write to `game_collections`.
  Future<void> _releasePurged() async {
    final purged = _released!;
    _released = null;
    await _access.releaseCollection(userId: _userId, platformGameIds: purged);
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
            // the most recently touched row, compared as an instant:
            // as ISO-8601 text, `…00.345Z` sorts after `…00.345001Z`
            // (#441).
            (t) => OrderingTerm.desc(t.updatedAt.julianday),
            // Deterministic tiebreaker when multiple rows share the
            // same updatedAt to the millisecond, which is all
            // `JULIANDAY` resolves. Two tombstones produced by a fast
            // addToCollection → removeFromCollection burst on a
            // quick machine can land within one millisecond (the
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
