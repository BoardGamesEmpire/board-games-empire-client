import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:uuid/uuid.dart';

import '../databases/server_database.dart';

/// Offline-first implementation of [GameCollectionRepository] backed by
/// the per-server [ServerDatabase] plus a [SyncQueueRepository] for
/// outbound mutations.
///
/// ## Atomicity
///
/// Every mutation method wraps its local write **and** the matching
/// sync-queue enqueue in a single [GeneratedDatabase.transaction]. If
/// the enqueue fails (e.g. queue table constraint), the local write
/// rolls back so the on-disk state cannot drift away from the sync
/// log.
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
/// ## Tombstones
///
/// `deletedAt` is the canonical tombstone marker (matches the model's
/// [GameCollection.isDeleted] / [GameCollection.deletedAt]). The
/// partial unique index on `(user_id, platform_game_id, medium)
/// WHERE deleted_at IS NULL` lets tombstoned rows coexist with a
/// fresh row for the same triplet, which is what makes the
/// resurrect path in [addToCollection] safe.
///
/// ## addToCollection semantics on duplicate triplet
///
/// - **Tombstoned row exists**: resurrect (clear `deletedAt`,
///   overwrite fields, keep the original id, mark dirty + localOnly).
/// - **Live row exists**: increment `quantity` by the requested
///   amount (rating/comment overwritten only if the caller supplied
///   them; existing values otherwise preserved).
/// - **No row exists**: fresh insert with a new cuid.
///
/// Whatever branch fires, an `AddToCollectionOperation` is enqueued
/// with the final post-write quantity; the server is expected to
/// dedup or merge on its side.
class GameCollectionRepositoryImpl implements GameCollectionRepository {
  GameCollectionRepositoryImpl({
    required ServerDatabase db,
    required SyncQueueRepository syncQueue,
    required String currentUserId,
  }) : _db = db,
       _syncQueue = syncQueue,
       _userId = currentUserId;

  final ServerDatabase _db;
  final SyncQueueRepository _syncQueue;
  final String _userId;
  static const _uuid = Uuid();

  // ── Reads ─────────────────────────────────────────────────────────────────────────

  @override
  Future<List<GameCollection>> getCollection() async {
    final rows =
        await (_db.select(_db.gameCollectionsTable)..where(
              (t) => t.userId.equals(_userId) & t.deletedAt.isNull(),
            ))
            .get();
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

  // ── Mutations ──────────────────────────────────────────────────────────────────

  @override
  Future<GameCollection> addToCollection({
    required String platformGameId,
    required GameMedium medium,
    int quantity = 1,
    int? rating,
    String? comment,
  }) async {
    return _db.transaction(() async {
      final now = DateTime.now().toUtc();
      final wireMedium = medium.toWire();

      // Look at ALL rows for the triplet (including tombstones).
      // The partial unique index ignores tombstoned rows for INSERT
      // uniqueness, but queries still see them — we need to in order
      // to choose between resurrect, increment, and fresh insert.
      final existing =
          await (_db.select(_db.gameCollectionsTable)..where(
                (t) =>
                    t.userId.equals(_userId) &
                    t.platformGameId.equals(platformGameId) &
                    t.medium.equals(wireMedium),
              ))
              .getSingleOrNull();

      final String entryId;
      final int finalQuantity;

      if (existing == null) {
        // Fresh insert.
        entryId = _uuid.v4();
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
        // Resurrect a tombstoned row. Keep the id (server may still
        // know about it from a prior sync); reset the lifecycle.
        entryId = existing.id;
        finalQuantity = quantity;
        await (_db.update(_db.gameCollectionsTable)
              ..where((t) => t.id.equals(entryId)))
            .write(
              GameCollectionsTableCompanion(
                quantity: Value(quantity),
                rating: Value(rating),
                comment: Value(comment),
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
        await (_db.update(_db.gameCollectionsTable)
              ..where((t) => t.id.equals(entryId)))
            .write(
              GameCollectionsTableCompanion(
                quantity: Value(finalQuantity),
                rating: rating != null ? Value(rating) : const Value.absent(),
                comment:
                    comment != null ? Value(comment) : const Value.absent(),
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

      final row = await (_db.select(_db.gameCollectionsTable)
            ..where((t) => t.id.equals(entryId)))
          .getSingle();
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
    return _db.transaction(() async {
      final now = DateTime.now().toUtc();

      // Preflight: the row must exist AND belong to the current user.
      final existing =
          await (_db.select(_db.gameCollectionsTable)..where(
                (t) => t.id.equals(id) & t.userId.equals(_userId),
              ))
              .getSingleOrNull();
      if (existing == null) {
        throw StateError(
          'GameCollection entry $id not found for current user',
        );
      }

      await (_db.update(_db.gameCollectionsTable)
            ..where((t) => t.id.equals(id) & t.userId.equals(_userId)))
          .write(
            GameCollectionsTableCompanion(
              quantity: quantity != null
                  ? Value(quantity)
                  : const Value.absent(),
              rating: rating != null ? Value(rating) : const Value.absent(),
              playCount: playCount != null
                  ? Value(playCount)
                  : const Value.absent(),
              playAgain: playAgain != null
                  ? Value(playAgain)
                  : const Value.absent(),
              favorite: favorite != null
                  ? Value(favorite)
                  : const Value.absent(),
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

      final row = await (_db.select(_db.gameCollectionsTable)
            ..where((t) => t.id.equals(id) & t.userId.equals(_userId)))
          .getSingle();
      return _mapRow(row);
    });
  }

  @override
  Future<void> removeFromCollection(String id) async {
    return _db.transaction(() async {
      final now = DateTime.now().toUtc();

      final existing =
          await (_db.select(_db.gameCollectionsTable)..where(
                (t) => t.id.equals(id) & t.userId.equals(_userId),
              ))
              .getSingleOrNull();
      if (existing == null) {
        throw StateError(
          'GameCollection entry $id not found for current user',
        );
      }

      // Tombstone via deletedAt. The partial unique index ignores
      // tombstoned rows, so a subsequent addToCollection on the same
      // triplet can resurrect this row (see addToCollection).
      await (_db.update(_db.gameCollectionsTable)
            ..where((t) => t.id.equals(id) & t.userId.equals(_userId)))
          .write(
            GameCollectionsTableCompanion(
              deletedAt: Value(now),
              isDirty: const Value(true),
              updatedAt: Value(now),
            ),
          );

      await _syncQueue.enqueue(
        RemoveFromCollectionOperation(collectionId: id),
      );
    });
  }

  @override
  Future<void> reconcileFromServer(GameCollection serverEntry) async {
    return _db.transaction(() async {
      // Find any local row for the same triplet (live or tombstoned).
      // We need to see tombstones too because the server-confirmed
      // entry may correspond to a row we already tombstoned locally.
      final local =
          await (_db.select(_db.gameCollectionsTable)..where(
                (t) =>
                    t.userId.equals(_userId) &
                    t.platformGameId.equals(serverEntry.platformGameId) &
                    t.medium.equals(serverEntry.medium.toWire()),
              ))
              .getSingleOrNull();

      // Drop the local row if its id differs from the server's
      // canonical id (server reassigned during sync).
      if (local != null && local.id != serverEntry.id) {
        await (_db.delete(_db.gameCollectionsTable)
              ..where((t) => t.id.equals(local.id)))
            .go();
      }

      await _db
          .into(_db.gameCollectionsTable)
          .insertOnConflictUpdate(
            _modelToCompanion(
              serverEntry.copyWith(isDirty: false, isLocalOnly: false),
            ),
          );
    });
  }

  // ── Streams ──────────────────────────────────────────────────────────────────

  @override
  Stream<List<GameCollection>> watchCollection() =>
      (_db.select(_db.gameCollectionsTable)..where(
            (t) => t.userId.equals(_userId) & t.deletedAt.isNull(),
          ))
          .watch()
          .map((rows) => rows.map(_mapRow).toList());

  @override
  Stream<GameCollection?> watchEntry(String id) =>
      (_db.select(_db.gameCollectionsTable)..where(
            (t) => t.id.equals(id) & t.userId.equals(_userId),
          ))
          .watchSingleOrNull()
          .map((row) => row == null ? null : _mapRow(row));

  // ── Mappers ──────────────────────────────────────────────────────────────────

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
