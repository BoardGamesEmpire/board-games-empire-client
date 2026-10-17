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

/// The server's copy of the fixture entry, stamped long before any local
/// write in this file.
GameCollection _server({
  int quantity = 1,
  int? rating,
  String? comment,
  DateTime? deletedAt,
}) => GameCollection(
  id: _kServerId,
  userId: _kUserId,
  platformGameId: kFixturePlatformGameId,
  medium: GameMedium.physical,
  quantity: quantity,
  rating: rating,
  comment: comment,
  deletedAt: deletedAt,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026, 2),
);

/// Discarding a stuck op undoes what it did to the collection (#190).
///
/// The real repository over the real queue on one database, so the undo and
/// the queue delete are seen landing together, and a later hydrate's merge
/// is seen bringing the server's copy back.
void main() {
  late ServerDatabase db;
  late SyncQueueRepositoryImpl queue;
  late GameCollectionRepositoryImpl repo;

  setUp(() async {
    db = inMemoryServerDatabase();
    // One fixed instant, so entries order by insertion.
    final clock = FixedClockService(DateTime.utc(2026, 10, 17, 12));
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

  Future<GameCollection> add({int quantity = 1, int? rating}) =>
      repo.addToCollection(
        platformGameId: kFixturePlatformGameId,
        medium: GameMedium.physical,
        quantity: quantity,
        rating: rating,
      );

  /// A clean row the server has confirmed, with nothing queued for it.
  Future<void> seedConfirmed({int quantity = 1, int? rating}) async {
    await add(quantity: quantity, rating: rating);
    final addOp = (await queue.getAllEntries()).single;
    await repo.reconcileFromServer(
      _server(quantity: quantity, rating: rating),
      completedSyncQueueId: addOp.id,
    );
    await queue.purgeCompleted();
  }

  /// The newest op in the queue, parked as the server refusing it would.
  Future<SyncQueueEntry> parkNewest() async {
    final newest = (await queue.getOutstandingEntries()).last;
    await queue.park(newest.id, error: 'rejected: 400');
    return newest;
  }

  Future<void> hydrate(GameCollection serverCopy) async => repo.mergeFromServer(
    [serverCopy],
    removalsSince: await repo.removalMark(),
  );

  group('an add for an entry the server has never seen', () {
    test('deletes the row, and every op held behind the add', () async {
      final added = await add();
      final addOp = await parkNewest();
      await repo.updateCollectionEntry(id: added.id, rating: 7);
      await repo.removeFromCollection(added.id);

      expect(await repo.discardQueuedOp(addOp.id), isTrue);

      expect(await rows(), isEmpty);
      expect(await queue.getAllEntries(), isEmpty);
    });

    test(
      'of a re-add over a removal still queued, puts the removal back',
      () async {
        await seedConfirmed();
        await repo.removeFromCollection(_kServerId);
        final [removeOp] = await queue.getOutstandingEntries();
        for (var i = 0; i < SyncQueueEntry.maxRetries; i++) {
          await queue.markFailed(removeOp.id, error: 'timeout $i');
        }
        await add(quantity: 2);
        final readdOp = await parkNewest();

        await repo.discardQueuedOp(readdOp.id);

        final row = (await rows()).single;
        expect(row.id, _kServerId);
        expect(
          row.deletedAt,
          isNotNull,
          reason: 'removed, as before the re-add',
        );
        expect(row.isLocalOnly, isFalse, reason: 'the server knows this id');
        expect(row.isDirty, isTrue, reason: 'the removal is still queued');
        expect((await queue.getAllEntries()).map((e) => e.id), [removeOp.id]);
      },
    );

    test('of a re-add over a removal of an entry the server has never seen '
        'either, keeps the entry local-only', () async {
      await add();
      final addOp = await parkNewest();
      final added = (await rows()).single;
      await repo.removeFromCollection(added.id);
      await add(quantity: 2);
      final readdOp = await parkNewest();

      await repo.discardQueuedOp(readdOp.id);

      final row = (await rows()).single;
      expect(row.deletedAt, isNotNull, reason: 'removed, as before the re-add');
      expect(row.isLocalOnly, isTrue, reason: 'the first add is still queued');

      // So discarding that first add still deletes the entry outright.
      await repo.discardQueuedOp(addOp.id);

      expect(await rows(), isEmpty);
      expect(await queue.getAllEntries(), isEmpty);
    });
  });

  group('an add for an entry the server knows', () {
    test(
      'drops the op, and the next hydrate brings back the server copy',
      () async {
        await seedConfirmed(quantity: 2);
        await add();
        final addOp = await parkNewest();

        await repo.discardQueuedOp(addOp.id);

        expect(await queue.getAllEntries(), isEmpty);
        expect((await rows()).single.isDirty, isFalse);

        await hydrate(_server(quantity: 2));

        expect((await rows()).single.quantity, 2);
      },
    );
  });

  group('an update', () {
    test('with nothing else queued, leaves the row clean for the next '
        'hydrate to restore', () async {
      await seedConfirmed(rating: 5);
      await repo.updateCollectionEntry(id: _kServerId, rating: 9);
      final updateOp = await parkNewest();

      await repo.discardQueuedOp(updateOp.id);

      final row = (await rows()).single;
      expect(row.isDirty, isFalse);
      expect(row.isLocalOnly, isFalse);
      expect(await queue.getAllEntries(), isEmpty);

      await hydrate(_server(rating: 5));

      expect((await rows()).single.rating, 5);
    });

    test('with a later op still queued, keeps the row dirty', () async {
      await seedConfirmed();
      await repo.updateCollectionEntry(id: _kServerId, rating: 9);
      final updateOp = await parkNewest();
      await repo.updateCollectionEntry(id: _kServerId, quantity: 3);

      await repo.discardQueuedOp(updateOp.id);

      expect((await rows()).single.isDirty, isTrue);
      final remaining = await queue.getAllEntries();
      expect(remaining, hasLength(1));
      expect(
        (remaining.single.operation as UpdateCollectionOperation).quantity,
        3,
      );
    });
  });

  group('a removal', () {
    test('brings the entry back, and the next hydrate restores it', () async {
      await seedConfirmed(quantity: 4);
      await repo.removeFromCollection(_kServerId);
      final removeOp = await parkNewest();

      await repo.discardQueuedOp(removeOp.id);

      final row = (await rows()).single;
      expect(row.deletedAt, isNull);
      expect(row.isDirty, isFalse);
      expect(await queue.getAllEntries(), isEmpty);
      expect(await repo.getCollection(), hasLength(1));

      // Changed on another device meanwhile.
      await hydrate(_server(quantity: 5));

      expect((await rows()).single.quantity, 5);
    });
  });

  group('titleOf()', () {
    test("names the entry's game, a removed entry included", () async {
      await seedConfirmed();
      expect(await repo.titleOf(_kServerId), 'Test Game');

      await repo.removeFromCollection(_kServerId);

      expect(await repo.titleOf(_kServerId), 'Test Game');
    });

    test("is null for an unknown id or another user's entry", () async {
      await seedConfirmed();
      final other = GameCollectionRepositoryImpl(
        db: db,
        syncQueue: queue,
        currentUserId: 'user-other',
        clock: FixedClockService(DateTime.utc(2026, 10, 17, 12)),
      );

      expect(await repo.titleOf('nonexistent'), isNull);
      expect(await other.titleOf(_kServerId), isNull);
    });
  });

  group('changes nothing', () {
    test('for an op that is no longer stuck, such as one another tab '
        'retried', () async {
      await add();
      final addOp = await parkNewest();
      await queue.retry(addOp.id);
      final before = await rows();

      expect(await repo.discardQueuedOp(addOp.id), isFalse);

      expect(await rows(), before);
      expect((await queue.getAllEntries()).single.id, addOp.id);
    });

    test('for an id that is gone or completed', () async {
      await seedConfirmed();
      await add();
      final addOp = (await queue.getOutstandingEntries()).single;
      await queue.markCompleted(addOp.id);
      final before = await rows();

      await repo.discardQueuedOp(addOp.id);
      await repo.discardQueuedOp('nonexistent');

      expect(await rows(), before);
      expect((await queue.getAllEntries()).single.id, addOp.id);
    });

    test("for a household op, which is not this repository's", () async {
      final household = await queue.enqueue(
        const CreateHouseholdOperation(localId: 'hh-1', name: 'Smiths'),
      );

      await expectLater(
        repo.discardQueuedOp(household.id),
        throwsArgumentError,
      );

      expect((await queue.getAllEntries()).single.id, household.id);
    });
  });
}
