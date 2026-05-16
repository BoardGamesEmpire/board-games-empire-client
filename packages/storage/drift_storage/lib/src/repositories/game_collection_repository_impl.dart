import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:uuid/uuid.dart';

import '../databases/server_database.dart';

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

  @override
  Future<List<GameCollection>> getCollection() async {
    final rows = await (_db.select(
      _db.gameCollectionsTable,
    )..where((t) => t.userId.equals(_userId))).get();
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
                  t.medium.equals(medium.toWire()),
            ))
            .getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

  @override
  Future<GameCollection> addToCollection({
    required String platformGameId,
    required GameMedium medium,
    int quantity = 1,
    int? rating,
    String? comment,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().toUtc();

    final companion = GameCollectionsTableCompanion.insert(
      id: id,
      userId: _userId,
      platformGameId: platformGameId,
      medium: medium.toWire(),
      quantity: Value(quantity),
      rating: Value(rating),
      comment: Value(comment),
      isDirty: const Value(true),
      isLocalOnly: const Value(true),
      createdAt: now,
      updatedAt: now,
    );

    await _db.into(_db.gameCollectionsTable).insert(companion);

    await _syncQueue.enqueue(
      AddToCollectionOperation(
        localId: id,
        platformGameId: platformGameId,
        medium: medium.toWire(),
        quantity: quantity,
        rating: rating,
        comment: comment,
      ),
    );

    final row = await (_db.select(
      _db.gameCollectionsTable,
    )..where((t) => t.id.equals(id))).getSingle();
    return _mapRow(row);
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
    final now = DateTime.now().toUtc();

    await (_db.update(
      _db.gameCollectionsTable,
    )..where((t) => t.id.equals(id))).write(
      GameCollectionsTableCompanion(
        quantity: quantity != null ? Value(quantity) : const Value.absent(),
        rating: rating != null ? Value(rating) : const Value.absent(),
        playCount: playCount != null ? Value(playCount) : const Value.absent(),
        playAgain: playAgain != null ? Value(playAgain) : const Value.absent(),
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
    )..where((t) => t.id.equals(id))).getSingle();
    return _mapRow(row);
  }

  @override
  Future<void> removeFromCollection(String id) async {
    await _syncQueue.enqueue(RemoveFromCollectionOperation(collectionId: id));

    // Tombstone: mark deleted locally until server confirms and we purge
    await (_db.update(
      _db.gameCollectionsTable,
    )..where((t) => t.id.equals(id))).write(
      GameCollectionsTableCompanion(
        isDirty: const Value(true),
        quantity: const Value(0),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  @override
  Future<void> reconcileFromServer(GameCollection serverEntry) async {
    // Find the local entry with same platformGameId and medium
    final local =
        await (_db.select(_db.gameCollectionsTable)..where(
              (t) =>
                  t.userId.equals(_userId) &
                  t.platformGameId.equals(serverEntry.platformGameId) &
                  t.medium.equals(serverEntry.medium.toWire()),
            ))
            .getSingleOrNull();

    // Delete the local entry if it exists (it has a different ID)
    if (local != null && local.id != serverEntry.id) {
      await (_db.delete(
        _db.gameCollectionsTable,
      )..where((t) => t.id.equals(local.id))).go();
    }

    // Insert/update the server entry
    await _db
        .into(_db.gameCollectionsTable)
        .insertOnConflictUpdate(
          _modelToCompanion(
            serverEntry.copyWith(isDirty: false, isLocalOnly: false),
          ),
        );
  }

  @override
  Stream<List<GameCollection>> watchCollection() =>
      (_db.select(_db.gameCollectionsTable)..where(
            (t) => t.userId.equals(_userId) & t.quantity.isBiggerThanValue(0),
          ))
          .watch()
          .map((rows) => rows.map(_mapRow).toList());

  @override
  Stream<GameCollection?> watchEntry(String id) =>
      (_db.select(_db.gameCollectionsTable)..where((t) => t.id.equals(id)))
          .watchSingleOrNull()
          .map((row) => row == null ? null : _mapRow(row));

  // ── Mappers ───────────────────────────────────────────────────────────────

  GameCollection _mapRow(GameCollectionsTableData row) => GameCollection(
    id: row.id,
    userId: row.userId,
    platformGameId: row.platformGameId,
    medium: GameMedium.fromWire(row.medium),
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
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  GameCollectionsTableCompanion _modelToCompanion(GameCollection m) =>
      GameCollectionsTableCompanion.insert(
        id: m.id,
        userId: m.userId,
        platformGameId: m.platformGameId,
        medium: m.medium.toWire(),
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
        createdAt: m.createdAt,
        updatedAt: m.updatedAt,
      );
}
