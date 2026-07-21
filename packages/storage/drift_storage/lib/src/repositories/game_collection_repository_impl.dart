import 'package:cuid2/cuid2.dart';
import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';

/// Offline-first implementation of [GameCollectionRepository] backed by
/// the per-server [ServerDatabase] plus a [SyncQueueRepository] for
/// outbound mutations.
///
/// ## ID generation
///
/// Fresh local rows get a [cuid2] id. This matches the backend's id
/// format — the backend uses cuid2 explicitly — so a row's id is the
/// same string from local creation through to the server cache *when
/// the backend honours the client-supplied id*. Today the backend's
/// create DTO strips ids before forwarding to Prisma, so the server
/// returns a freshly-generated cuid2 on insert and
/// [reconcileFromServer] handles the id-reassignment path via
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
/// `reconcileFromServer` extends the same boundary to inbound server
/// responses: it verifies `serverEntry.userId == currentUserId` and
/// throws [StateError] if the response is for a different user. A
/// wrong/stale server response or a buggy caller cannot inject
/// another user's collection row into this repository's cache.
///
/// ## Quantity validation
///
/// `addToCollection.quantity` must be `> 0`. `updateCollectionEntry.quantity`
/// must be `> 0` when provided (`null` means "leave unchanged"). Both
/// methods throw [ArgumentError] **before** opening the transaction,
/// so the local cache and sync queue stay untouched on invalid input.
/// Removing an entry uses [removeFromCollection], not
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
class GameCollectionRepositoryImpl implements GameCollectionRepository {
  GameCollectionRepositoryImpl({
    required ServerDatabase db,
    required SyncQueueRepository syncQueue,
    required String currentUserId,
    required ClockService clock,
  }) : _db = db,
       _syncQueue = syncQueue,
       _userId = currentUserId,
       _clock = clock;

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

  // ── Reads ──────────────────────────────────────────────────────────────────────

  @override
  Future<List<GameCollection>> getCollection() async {
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
        // (the backend uses cuid2 explicitly). When the backend
        // honours the client-supplied id, the round-trip preserves
        // this id; today the backend's create DTO strips ids
        // before reaching Prisma so a different canonical id comes
        // back and `reconcileFromServer` calls
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
    int? playCount,
    bool? playAgain,
    bool? favorite,
    String? comment,
    DateTime? lastPlayed,
  }) async {
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
          playCount: playCount != null
              ? Value(playCount)
              : const Value.absent(),
          playAgain: playAgain != null
              ? Value(playAgain)
              : const Value.absent(),
          favorite: favorite != null ? Value(favorite) : const Value.absent(),
          comment: comment != null ? Value(comment) : const Value.absent(),
          lastPlayed: lastPlayed != null
              ? Value(lastPlayed)
              : const Value.absent(),
          isDirty: const Value(true),
          updatedAt: Value(now),
        ),
      );

      await _syncQueue.enqueue(
        UpdateCollectionOperation(
          collectionId: id,
          quantity: quantity,
          rating: rating,
          playCount: playCount,
          playAgain: playAgain,
          favorite: favorite,
          comment: comment,
          lastPlayed: lastPlayed,
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
  /// row's id (which is the steady state today: the backend's create
  /// DTO strips client ids before reaching Prisma), any pending
  /// Update/Remove ops queued against the local id would otherwise
  /// be sent to the server with an id the server doesn't know. This
  /// method calls [SyncQueueRepository.remapCollectionId] to rewrite
  /// those payloads BEFORE dropping the stale local row. If the
  /// backend's DTO is later updated to forward client ids, this
  /// branch becomes a no-op (local.id == serverEntry.id always)
  /// without any client-side change.
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
  /// ## Live-entry upsert
  ///
  /// When `serverEntry.deletedAt` is null, the local row is
  /// upserted with `isDirty: false, isLocalOnly: false`. If the
  /// local row had a different id, that stale row is dropped
  /// before the upsert (after the remap).
  ///
  /// **TODO(server-driven-dirty-merge)**: see the interface
  /// `reconcileFromServer` doc — this upsert clobbers unsynced
  /// local dirty edits when the reconcile is a server-driven
  /// background pull (no `completedSyncQueueId`). Phase 3 sync-
  /// orchestrator scope: split into `acknowledge` /
  /// `mergeFromServer` with explicit conflict resolution.
  ///
  /// ## Sync-queue closure
  ///
  /// If [completedSyncQueueId] is provided, the matching queue
  /// entry is marked completed in the same Drift transaction. If
  /// any step throws, all writes roll back together.
  @override
  Future<void> reconcileFromServer(
    GameCollection serverEntry, {
    String? completedSyncQueueId,
  }) async {
    // Boundary check: fail fast BEFORE opening the transaction so
    // the local cache and sync queue stay untouched on a
    // misrouted server response.
    if (serverEntry.userId != _userId) {
      throw StateError(
        'reconcileFromServer received an entry for userId '
        '"${serverEntry.userId}" but this repository is scoped to '
        '"$_userId". Server response routing is misconfigured.',
      );
    }

    return _db.transaction(() async {
      // Look up any local row for the same triplet (live or
      // tombstoned). The schema permits multiple tombstones per
      // triplet, so this uses the same ordered+limited helper as
      // addToCollection: picks the live row if any, else the most
      // recent tombstone, else nothing — never throws.
      final local = await _findCanonicalRow(
        platformGameId: serverEntry.platformGameId,
        wireMedium: serverEntry.medium.toWire(),
      );

      // Id reassignment: rewrite pending Update/Remove ops that
      // reference the OLD local id so they don't get sent to the
      // server with an unknown id once we drop the local row
      // below.
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

  // ── Streams ──────────────────────────────────────────────────────────────────

  @override
  Stream<List<GameCollection>> watchCollection() =>
      (_db.select(_db.gameCollectionsTable)
            ..where((t) => t.userId.equals(_userId) & t.deletedAt.isNull()))
          .watch()
          .map((rows) => rows.map(_mapRow).toList());

  @override
  Stream<GameCollection?> watchEntry(String id) =>
      (_db.select(_db.gameCollectionsTable)..where(
            (t) =>
                t.id.equals(id) &
                t.userId.equals(_userId) &
                t.deletedAt.isNull(),
          ))
          .watchSingleOrNull()
          .map((row) => row == null ? null : _mapRow(row));

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
