import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_collection_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/fixed_clock.dart';
import '../support/platform_game_fixture.dart';

const _kUserId = 'user-abc';
const _kServerId = 'gc-server';

GameCollection _server({int quantity = 1, DateTime? updatedAt}) =>
    GameCollection(
      id: _kServerId,
      userId: _kUserId,
      platformGameId: kFixturePlatformGameId,
      medium: GameMedium.physical,
      quantity: quantity,
      createdAt: DateTime.utc(2026),
      updatedAt: updatedAt ?? DateTime.utc(2026, 2),
    );

/// A removal the server reports as already done is settled locally (#121).
///
/// The server answers a re-sent removal with a 404 that carries no entry, so
/// there is nothing to hand `reconcileFromServer`. Completing only the queue
/// entry would leave the tombstone dirty, and `mergeFromServer` never writes
/// over a dirty row, so the entry would be frozen for good.
void main() {
  late ServerDatabase db;
  late SyncQueueRepositoryImpl queue;
  late GameCollectionRepositoryImpl repo;

  setUp(() async {
    db = inMemoryServerDatabase();
    final clock = FixedClockService(DateTime.utc(2026, 10, 12, 12));
    queue = SyncQueueRepositoryImpl(db, clock, userId: _kUserId);
    repo = GameCollectionRepositoryImpl(
      db: db,
      syncQueue: queue,
      currentUserId: _kUserId,
      clock: clock,
    );
    await seedPlatformGame(db);
  });

  tearDown(() async => db.close());

  Future<List<GameCollectionsTableData>> rows() =>
      db.select(db.gameCollectionsTable).get();

  /// A server-confirmed entry the user then removed: a dirty tombstone under
  /// the server id, with its removal queued. Returns the removal's queue id.
  Future<String> removedEntry() async {
    await repo.addToCollection(
      platformGameId: kFixturePlatformGameId,
      medium: GameMedium.physical,
      quantity: 1,
    );
    final addOp = (await queue.getAllEntries()).single;
    await repo.reconcileFromServer(_server(), completedSyncQueueId: addOp.id);
    await repo.removeFromCollection(_kServerId);
    return (await queue.getPendingEntries()).single.id;
  }

  group('confirmRemoved (#121)', () {
    test('purges the tombstone and completes the removal', () async {
      final removeOp = await removedEntry();

      await repo.confirmRemoved(_kServerId, completedSyncQueueId: removeOp);

      expect(await rows(), isEmpty);
      final entry = (await queue.getAllEntries()).singleWhere(
        (e) => e.id == removeOp,
      );
      expect(entry.status, SyncStatus.completed);
      expect(await queue.getPendingEntries(), isEmpty);
    });

    test('leaves the entry free for the next hydrate to write', () async {
      // The bug completing the op alone would leave: a dirty tombstone that
      // mergeFromServer skips, hiding a later re-add made on another device.
      final removeOp = await removedEntry();
      await repo.confirmRemoved(_kServerId, completedSyncQueueId: removeOp);

      final mark = await repo.removalMark();
      await repo.mergeFromServer([
        _server(quantity: 3, updatedAt: DateTime.utc(2026, 11)),
      ], removalsSince: mark);

      final row = (await rows()).single;
      expect(row.id, _kServerId);
      expect(row.quantity, 3);
      expect(row.deletedAt, isNull);
      expect(row.isDirty, isFalse);
    });

    test('keeps a re-add the queue has yet to send', () async {
      // Remove, then add the same game again before the removal's answer
      // arrives. The re-add revives the tombstone as a local-only row, which
      // the reconcile's purge already spares; this must spare it too.
      final removeOp = await removedEntry();
      await repo.addToCollection(
        platformGameId: kFixturePlatformGameId,
        medium: GameMedium.physical,
        quantity: 2,
      );

      await repo.confirmRemoved(_kServerId, completedSyncQueueId: removeOp);

      final row = (await rows()).single;
      expect(row.id, _kServerId);
      expect(row.deletedAt, isNull);
      expect(row.isLocalOnly, isTrue);
      expect(row.quantity, 2);
      final pending = await queue.getPendingEntries();
      expect(pending.single.operation, isA<AddToCollectionOperation>());
    });

    test('with no local row, completes the removal alone', () async {
      final removeOp = await queue.enqueue(
        const RemoveFromCollectionOperation(collectionId: 'gc-gone'),
      );

      await repo.confirmRemoved('gc-gone', completedSyncQueueId: removeOp.id);

      expect((await queue.getAllEntries()).single.status, SyncStatus.completed);
    });

    test('rolls the purge back when the removal cannot be completed', () async {
      final removeOp = await removedEntry();
      await queue.onDispose();

      await expectLater(
        repo.confirmRemoved(_kServerId, completedSyncQueueId: removeOp),
        throwsStateError,
      );

      final row = (await rows()).single;
      expect(row.deletedAt, isNotNull);
      expect(row.isDirty, isTrue);
    });
  });
}
