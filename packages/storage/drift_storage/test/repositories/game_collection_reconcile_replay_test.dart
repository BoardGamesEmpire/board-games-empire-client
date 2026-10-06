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

/// The server's answer to an acknowledged op for the fixture platform game.
GameCollection _server({
  String id = _kServerId,
  int quantity = 1,
  int? rating,
  int? playCount,
  String? comment,
  DateTime? deletedAt,
}) => GameCollection(
  id: id,
  userId: _kUserId,
  platformGameId: kFixturePlatformGameId,
  medium: GameMedium.physical,
  quantity: quantity,
  rating: rating,
  playCount: playCount,
  comment: comment,
  deletedAt: deletedAt,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026, 2),
);

/// An acknowledgement must not undo the ops still queued behind it (#429).
///
/// Runs the real collection repository over the real queue on one database,
/// as the probe on #429 did, so the remap, the lookup and the replay all
/// meet the same rows a drain would leave.
void main() {
  late ServerDatabase db;
  late SyncQueueRepositoryImpl queue;
  late GameCollectionRepositoryImpl repo;

  setUp(() async {
    db = inMemoryServerDatabase();
    // One fixed instant: entries then order by insertion (the rowid
    // tiebreak), which is the order the ops were made in.
    final clock = FixedClockService(DateTime.utc(2026, 10, 5, 12));
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

  Future<GameCollectionsTableData> onlyRow() async =>
      (await db.select(db.gameCollectionsTable).get()).single;

  Future<GameCollection> add({int quantity = 1}) => repo.addToCollection(
    platformGameId: kFixturePlatformGameId,
    medium: GameMedium.physical,
    quantity: quantity,
  );

  Future<void> exhaust(String syncQueueId) async {
    for (var i = 0; i < SyncQueueEntry.maxRetries; i++) {
      await queue.markFailed(syncQueueId, error: 'rejected $i');
    }
  }

  group('reconcileFromServer replays the ops still queued (#429)', () {
    test('an edit queued behind the acknowledged add stays applied, '
        'and the row stays dirty', () async {
      final added = await add();
      await repo.updateCollectionEntry(id: added.id, quantity: 2);
      final [addOp, updateOp] = await queue.getAllEntries();

      await repo.reconcileFromServer(
        _server(quantity: 1),
        completedSyncQueueId: addOp.id,
      );

      final row = await onlyRow();
      expect(row.id, _kServerId);
      expect(row.quantity, 2);
      expect(row.isDirty, isTrue);
      expect(row.isLocalOnly, isFalse);
      expect(row.deletedAt, isNull);

      final pending = await queue.getPendingEntries();
      expect(pending.map((e) => e.id), [updateOp.id]);
      expect(
        (pending.single.operation as UpdateCollectionOperation).collectionId,
        _kServerId,
        reason: 'remapped to the server id, so its send finds the row',
      );
    });

    test('the same when the server keeps the local id', () async {
      // Today's backend always assigns its own id; this pins the client
      // branch that skips the remap.
      final added = await add();
      await repo.updateCollectionEntry(id: added.id, quantity: 2);
      final [addOp, _] = await queue.getAllEntries();

      await repo.reconcileFromServer(
        _server(id: added.id, quantity: 1),
        completedSyncQueueId: addOp.id,
      );

      final row = await onlyRow();
      expect(row.id, added.id);
      expect(row.quantity, 2);
      expect(row.isDirty, isTrue);
    });

    test('a removal queued behind the acknowledged add keeps the entry '
        'removed', () async {
      final added = await add();
      await repo.removeFromCollection(added.id);
      final [addOp, removeOp] = await queue.getAllEntries();

      await repo.reconcileFromServer(_server(), completedSyncQueueId: addOp.id);

      expect(await repo.getCollection(), isEmpty);
      final row = await onlyRow();
      expect(row.id, _kServerId);
      expect(row.deletedAt, isNotNull);
      expect(row.isDirty, isTrue);
      expect((await queue.getPendingEntries()).map((e) => e.id), [removeOp.id]);
    });

    test('an edit that exhausts after the acknowledgement never reads '
        'as cleanly synced', () async {
      final added = await add();
      await repo.updateCollectionEntry(id: added.id, quantity: 2);
      final [addOp, updateOp] = await queue.getAllEntries();

      await repo.reconcileFromServer(
        _server(quantity: 1),
        completedSyncQueueId: addOp.id,
      );
      await exhaust(updateOp.id);

      final row = await onlyRow();
      expect(row.quantity, 2);
      expect(row.isDirty, isTrue);
      // The count no longer includes the edit. Surfacing an exhausted op is
      // #190's; this suite only pins that the row doesn't say "synced".
      expect(await queue.getPendingCount(), 0);
    });

    test('an edit that exhausted before the acknowledgement is still '
        'replayed', () async {
      final added = await add();
      await repo.updateCollectionEntry(id: added.id, quantity: 2);
      final [addOp, updateOp] = await queue.getAllEntries();
      await exhaust(updateOp.id);

      await repo.reconcileFromServer(
        _server(quantity: 1),
        completedSyncQueueId: addOp.id,
      );

      final row = await onlyRow();
      expect(row.quantity, 2);
      expect(row.isDirty, isTrue);
    });

    test('an edit a sender holds right now is replayed, and moved to the '
        'server id for its retry', () async {
      final added = await add();
      await repo.updateCollectionEntry(id: added.id, quantity: 2);
      final [addOp, updateOp] = await queue.getAllEntries();
      expect(await queue.claim(updateOp.id), isTrue);

      await repo.reconcileFromServer(
        _server(quantity: 1),
        completedSyncQueueId: addOp.id,
      );

      final row = await onlyRow();
      expect(row.quantity, 2);
      expect(row.isDirty, isTrue);
      final claimed = (await queue.getAllEntries()).singleWhere(
        (e) => e.id == updateOp.id,
      );
      expect(claimed.status, SyncStatus.inProgress);
      expect(
        (claimed.operation as UpdateCollectionOperation).collectionId,
        _kServerId,
      );
    });

    test('an exhausted edit keeps the row dirty through later '
        'acknowledgements, not only the first', () async {
      // The first acknowledgement moves the id. Every later one must still
      // find the exhausted op, under the server id.
      final added = await add();
      await repo.updateCollectionEntry(id: added.id, quantity: 2);
      final [addOp, quantityOp] = await queue.getAllEntries();
      await exhaust(quantityOp.id);
      await repo.reconcileFromServer(
        _server(quantity: 1),
        completedSyncQueueId: addOp.id,
      );

      await repo.updateCollectionEntry(id: _kServerId, rating: 5);
      final ratingOp = (await queue.getPendingEntries()).single;
      await repo.reconcileFromServer(
        _server(quantity: 1, rating: 5),
        completedSyncQueueId: ratingOp.id,
      );

      final row = await onlyRow();
      expect(row.rating, 5);
      expect(row.isDirty, isTrue, reason: 'the quantity edit never landed');
    });

    test(
      'an update replays field by field over the server\'s answer',
      () async {
        final added = await add();
        await repo.updateCollectionEntry(id: added.id, favorite: true);
        final [addOp, _] = await queue.getAllEntries();

        await repo.reconcileFromServer(
          _server(quantity: 1, playCount: 3, comment: 'From the server'),
          completedSyncQueueId: addOp.id,
        );

        final row = await onlyRow();
        expect(row.favorite, isTrue, reason: 'the queued edit');
        expect(row.playCount, 3, reason: 'server-owned, untouched by the edit');
        expect(row.comment, 'From the server');
        expect(row.quantity, 1);
      },
    );

    test('add -> remove -> add: the re-add survives the removal\'s own '
        'acknowledgement', () async {
      final added = await add();
      await repo.removeFromCollection(added.id);
      await add(quantity: 3);
      final [addOp, removeOp, _] = await queue.getAllEntries();

      await repo.reconcileFromServer(
        _server(quantity: 1),
        completedSyncQueueId: addOp.id,
      );

      var row = await onlyRow();
      expect(row.deletedAt, isNull);
      expect(row.quantity, 3);
      expect(row.isDirty, isTrue);
      expect(
        row.isLocalOnly,
        isTrue,
        reason:
            'a re-add the server has not seen; without it the removal\'s '
            'acknowledgement purges the row',
      );

      await repo.reconcileFromServer(
        _server(quantity: 1, deletedAt: DateTime.utc(2026, 3)),
        completedSyncQueueId: removeOp.id,
      );

      final live = await repo.getCollection();
      expect(live, hasLength(1));
      expect(live.single.quantity, 3);
      row = await onlyRow();
      expect(row.isLocalOnly, isTrue);
    });

    test('acknowledging the last queued op leaves the row clean', () async {
      final added = await add();
      await repo.updateCollectionEntry(id: added.id, quantity: 2);
      final [addOp, updateOp] = await queue.getAllEntries();

      await repo.reconcileFromServer(
        _server(quantity: 1),
        completedSyncQueueId: addOp.id,
      );
      await repo.reconcileFromServer(
        _server(quantity: 2),
        completedSyncQueueId: updateOp.id,
      );

      final row = await onlyRow();
      expect(row.quantity, 2);
      expect(row.isDirty, isFalse);
      expect(row.isLocalOnly, isFalse);
    });

    test('an op older than the acknowledged one keeps the row dirty but is '
        'not replayed over it', () async {
      // Replaying the exhausted rating 9 over the server's answer to the
      // newer rating 7 would show a value neither the server holds nor the
      // user last chose. The row still says it isn't synced.
      await repo.mergeFromServer([_server(rating: 5)]);
      await repo.updateCollectionEntry(id: _kServerId, rating: 9);
      await repo.updateCollectionEntry(id: _kServerId, rating: 7);
      final [olderOp, newerOp] = await queue.getAllEntries();
      await exhaust(olderOp.id);

      await repo.reconcileFromServer(
        _server(rating: 7),
        completedSyncQueueId: newerOp.id,
      );

      final row = await onlyRow();
      expect(row.rating, 7);
      expect(row.isDirty, isTrue);
    });

    test('a second acknowledgement of one op replays only what was queued '
        'after it', () async {
      // An expired lease lets one op be delivered twice. By the second
      // acknowledgement the first has completed it, so it is no longer
      // outstanding; it must still be placed among the others, or the
      // exhausted quantity 2 is replayed over the server's 5.
      await repo.mergeFromServer([_server(quantity: 1)]);
      await repo.updateCollectionEntry(id: _kServerId, quantity: 2);
      await repo.updateCollectionEntry(id: _kServerId, quantity: 5);
      await repo.updateCollectionEntry(id: _kServerId, rating: 4);
      final [olderOp, deliveredTwice, _] = await queue.getAllEntries();
      await exhaust(olderOp.id);

      await repo.reconcileFromServer(
        _server(quantity: 5),
        completedSyncQueueId: deliveredTwice.id,
      );
      await repo.reconcileFromServer(
        _server(quantity: 5),
        completedSyncQueueId: deliveredTwice.id,
      );

      final row = await onlyRow();
      expect(row.quantity, 5);
      expect(row.rating, 4, reason: 'the newer edit is still replayed');
      expect(row.isDirty, isTrue);
    });

    test('an acknowledgement that cannot name its op leaves the row dirty '
        'while that op is queued', () async {
      await add();

      await repo.reconcileFromServer(_server(quantity: 1));

      final row = await onlyRow();
      expect(row.quantity, 1);
      expect(row.isDirty, isTrue);
    });
  });
}
