import 'dart:convert';

import 'package:drift/drift.dart' show Value;
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
    await seedPlatformGame(db, readableBy: _kUserId);
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

    test('discarding the only local-only entry ends the record', () async {
      await add();
      final addOp = await parkNewest();

      expect(await repo.discardQueuedOp(addOp.id), isTrue);

      expect(await platformGameRecords(db, _kUserId), isEmpty);
      expect(await gameRecords(db, _kUserId), isEmpty);
      expect(await db.select(db.platformGamesTable).get(), isEmpty);
      expect(await db.select(db.gamesTable).get(), isEmpty);
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

    test('of a re-add over a removal, after a stuck add that raised the '
        "quantity of a confirmed entry, keeps the server's id known", () async {
      await seedConfirmed();
      await add();
      final raiseOp = await parkNewest();
      await repo.removeFromCollection(_kServerId);
      final removeOp = (await queue.getOutstandingEntries()).last;
      await add(quantity: 2);
      final readdOp = await parkNewest();

      await repo.discardQueuedOp(readdOp.id);

      expect((await rows()).single.isLocalOnly, isFalse);
      expect((await queue.getAllEntries()).map((e) => e.id), [
        raiseOp.id,
        removeOp.id,
      ]);

      // So discarding the raise takes the removal with it, and leaves the
      // entry as the server has it.
      await repo.discardQueuedOp(raiseOp.id);

      final row = (await rows()).single;
      expect(row.deletedAt, isNull);
      expect(row.isDirty, isFalse);
      expect(row.isLocalOnly, isFalse);
      expect(await queue.getAllEntries(), isEmpty);
    });

    test('of a re-add over a removal, once the add that created the entry '
        'is acknowledged, keeps the entry known', () async {
      await add();
      final addOp = (await queue.getOutstandingEntries()).single;
      final added = (await rows()).single;
      await repo.removeFromCollection(added.id);
      await add(quantity: 2);
      final readdOp = await parkNewest();
      await repo.reconcileFromServer(_server(), completedSyncQueueId: addOp.id);

      await repo.discardQueuedOp(readdOp.id);

      final row = (await rows()).single;
      expect(row.id, _kServerId);
      expect(row.deletedAt, isNotNull);
      expect(row.isLocalOnly, isFalse, reason: 'the server knows it now');
    });

    test('of a re-add, once the server has confirmed the removal it revived '
        'over, deletes the row', () async {
      await seedConfirmed();
      await repo.updateCollectionEntry(id: _kServerId, rating: 8);
      final updateOp = await parkNewest();
      await repo.removeFromCollection(_kServerId);
      final removeOp = (await queue.getOutstandingEntries()).last;
      await add(quantity: 2);
      final readdOp = await parkNewest();
      await repo.confirmRemoved(_kServerId, completedSyncQueueId: removeOp.id);

      await repo.discardQueuedOp(readdOp.id);

      expect(await rows(), isEmpty, reason: 'the server no longer has it');
      expect((await queue.getOutstandingEntries()).map((e) => e.id), [
        updateOp.id,
      ]);
    });

    test('keeps the entry once a later add has reached the server', () async {
      await add();
      final addOp = await parkNewest();
      await add();
      final laterAdd = (await queue.getOutstandingEntries()).last;
      await repo.reconcileFromServer(
        _server(quantity: 2),
        completedSyncQueueId: laterAdd.id,
      );

      await repo.discardQueuedOp(addOp.id);

      final row = (await rows()).single;
      expect(row.deletedAt, isNull);
      expect(row.isLocalOnly, isFalse);
      expect(row.isDirty, isFalse);
      expect(await queue.getOutstandingEntries(), isEmpty);
    });

    test('of a raise queued before raises were recorded, keeps the entry the '
        'add before it created', () async {
      await add();
      final [addOp] = await queue.getOutstandingEntries();
      await add();
      final raiseOp = (await queue.getOutstandingEntries()).last;
      // As an older version queued it: nothing says it raised the quantity.
      final payload = jsonDecode(raiseOp.payload) as Map<String, Object?>;
      expect(payload.remove('raised'), isTrue);
      await (db.update(db.syncQueueTable)
            ..where((t) => t.id.equals(raiseOp.id)))
          .write(SyncQueueTableCompanion(payload: Value(jsonEncode(payload))));
      await queue.park(raiseOp.id, error: 'rejected: 400');

      expect(await repo.discardQueuedOp(raiseOp.id), isTrue);

      final row = (await rows()).single;
      expect(row.deletedAt, isNull);
      expect(row.isLocalOnly, isTrue, reason: 'the first add is still queued');
      expect(row.isDirty, isTrue);
      expect((await queue.getAllEntries()).map((e) => e.id), [addOp.id]);
    });

    test('refuses while a later add for the entry is being sent, changing '
        'nothing', () async {
      await add();
      final addOp = await parkNewest();
      await add();
      final laterAdd = (await queue.getOutstandingEntries()).last;
      expect(await queue.claim(laterAdd.id), isTrue);
      final before = await rows();

      await expectLater(repo.discardQueuedOp(addOp.id), throwsStateError);

      expect(await rows(), before);
      expect((await queue.getAllEntries()).map((e) => e.id), [
        addOp.id,
        laterAdd.id,
      ]);
    });
  });

  group('an add for an entry the server knows', () {
    test('that raised its quantity takes a later removal and re-add with '
        'it, and the next hydrate brings back the server copy', () async {
      await seedConfirmed();
      await add();
      final raiseOp = await parkNewest();
      await repo.removeFromCollection(_kServerId);
      await add(quantity: 3);

      expect(await repo.discardQueuedOp(raiseOp.id), isTrue);

      final row = (await rows()).single;
      expect(row.deletedAt, isNull);
      expect(row.isLocalOnly, isFalse);
      expect(row.isDirty, isFalse);
      expect(await queue.getAllEntries(), isEmpty);

      await hydrate(_server());

      expect((await rows()).single.quantity, 1);
    });

    test('that revived it from a removal since discarded leaves it known, '
        'and takes the later ops with it', () async {
      await seedConfirmed();
      await repo.removeFromCollection(_kServerId);
      final removeOp = await parkNewest();
      await add(quantity: 2);
      final readdOp = await parkNewest();
      await repo.removeFromCollection(_kServerId);

      // Discarding the re-add first goes back to the first removal.
      await repo.discardQueuedOp(readdOp.id);

      var row = (await rows()).single;
      expect(row.deletedAt, isNotNull);
      expect(row.isLocalOnly, isFalse, reason: 'the server knows this id');
      expect((await queue.getAllEntries()).map((e) => e.id), [removeOp.id]);

      // And then the removal brings the entry back as the server has it.
      await repo.discardQueuedOp(removeOp.id);

      row = (await rows()).single;
      expect(row.deletedAt, isNull);
      expect(row.isDirty, isFalse);
      expect(await queue.getAllEntries(), isEmpty);
    });

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

    test('with nothing else queued, waits for a hydrate that asked after '
        'the discard', () async {
      await seedConfirmed();
      await repo.updateCollectionEntry(id: _kServerId, quantity: 2);
      final quantityOp = (await queue.getPendingEntries()).single;
      // A hydrate asks for its page before that update is acknowledged.
      final askedBefore = await repo.removalMark();
      await repo.reconcileFromServer(
        _server(quantity: 2),
        completedSyncQueueId: quantityOp.id,
      );
      await repo.updateCollectionEntry(id: _kServerId, rating: 7);
      final ratingOp = await parkNewest();

      await repo.discardQueuedOp(ratingOp.id);
      await repo.mergeFromServer([_server()], removalsSince: askedBefore);

      expect(
        (await rows()).single.quantity,
        2,
        reason: 'the acknowledged copy, not the page',
      );

      await hydrate(_server(quantity: 2));

      final row = (await rows()).single;
      expect(row.quantity, 2);
      expect(row.rating, isNull, reason: 'the discarded update is undone');
      expect(row.isDirty, isFalse);
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

    test('with another op still queued, has the next hydrate put back the '
        "server's values, with that op's over them", () async {
      await seedConfirmed(rating: 5);
      await repo.updateCollectionEntry(id: _kServerId, rating: 7);
      final ratingOp = await parkNewest();
      await repo.updateCollectionEntry(id: _kServerId, quantity: 3);
      final quantityOp = await parkNewest();

      await repo.discardQueuedOp(quantityOp.id);
      await hydrate(_server(rating: 5));

      final row = (await rows()).single;
      expect(row.quantity, 1, reason: "the server's, as before the discard");
      expect(row.rating, 7, reason: 'the op still queued');
      expect(row.isDirty, isTrue);
      expect((await queue.getAllEntries()).map((e) => e.id), [ratingOp.id]);
    });

    test('with another op still queued, leaves the row alone once that op '
        'is acknowledged before the hydrate', () async {
      await seedConfirmed(rating: 5);
      await repo.updateCollectionEntry(id: _kServerId, rating: 7);
      final ratingOp = await parkNewest();
      await repo.updateCollectionEntry(id: _kServerId, quantity: 3);
      final quantityOp = await parkNewest();
      await repo.updateCollectionEntry(id: _kServerId, favorite: true);

      await repo.discardQueuedOp(quantityOp.id);
      await repo.reconcileFromServer(
        _server(rating: 7),
        completedSyncQueueId: ratingOp.id,
      );
      // Read before that acknowledgement.
      await hydrate(_server(rating: 5));

      final row = (await rows()).single;
      expect(row.rating, 7);
      expect(row.favorite, isTrue);
    });

    test('with another op still queued, waits for a hydrate that asked '
        'after the discard', () async {
      await seedConfirmed();
      await repo.updateCollectionEntry(id: _kServerId, quantity: 2);
      final quantityOp = (await queue.getPendingEntries()).single;
      // A hydrate asks for its page before that update is acknowledged.
      final askedBefore = await repo.removalMark();
      await repo.reconcileFromServer(
        _server(quantity: 2),
        completedSyncQueueId: quantityOp.id,
      );
      await repo.updateCollectionEntry(id: _kServerId, rating: 7);
      await parkNewest();
      await repo.updateCollectionEntry(id: _kServerId, favorite: true);
      final favoriteOp = await parkNewest();

      await repo.discardQueuedOp(favoriteOp.id);
      await repo.mergeFromServer([_server()], removalsSince: askedBefore);

      var row = (await rows()).single;
      expect(row.quantity, 2, reason: 'the acknowledged copy, not the page');
      expect(row.rating, 7);

      await hydrate(_server(quantity: 2));

      row = (await rows()).single;
      expect(row.quantity, 2);
      expect(row.rating, 7, reason: 'the op still queued');
      expect(row.favorite, isNull, reason: 'the discarded update is undone');
      expect(row.isDirty, isTrue);
    });

    test('with another op still queued, waits past a removal the server '
        'reports for a live copy', () async {
      await seedConfirmed(rating: 5);
      await repo.updateCollectionEntry(id: _kServerId, rating: 7);
      await parkNewest();
      await repo.updateCollectionEntry(id: _kServerId, quantity: 3);
      final quantityOp = await parkNewest();

      await repo.discardQueuedOp(quantityOp.id);
      // Removed on another device, and then added back under the same id.
      await hydrate(_server(rating: 5, deletedAt: DateTime.utc(2026, 3)));
      await hydrate(_server(rating: 5));

      final row = (await rows()).single;
      expect(row.quantity, 1, reason: 'the discarded update is undone');
      expect(row.rating, 7, reason: 'the op still queued');
      expect(row.deletedAt, isNull);
      expect(row.isDirty, isTrue);
    });

    test('with another op still queued, keeps a copy acknowledged while the '
        'discard ran against a page read before it', () async {
      await seedConfirmed(rating: 5);
      await repo.updateCollectionEntry(id: _kServerId, rating: 7);
      final ratingOp = await parkNewest();
      await repo.updateCollectionEntry(id: _kServerId, quantity: 2);
      final quantityOp = (await queue.getPendingEntries()).single;
      await repo.updateCollectionEntry(id: _kServerId, favorite: true);
      await parkNewest();

      // The quantity is acknowledged while the discard is still running.
      await Future.wait([
        repo.discardQueuedOp(ratingOp.id),
        repo.reconcileFromServer(
          _server(
            quantity: 2,
            rating: 5,
          ).copyWith(updatedAt: DateTime.utc(2026, 3)),
          completedSyncQueueId: quantityOp.id,
        ),
      ]);
      // Asked after the discard, and read before the quantity arrived.
      await hydrate(_server(rating: 5));

      final row = (await rows()).single;
      expect(row.quantity, 2, reason: 'the acknowledged copy, not the page');
      expect(row.rating, 5, reason: 'the discarded update is undone');
      expect(row.favorite, isTrue, reason: 'the op still queued');
      expect(row.isDirty, isTrue);
    });

    test('with nothing else queued, keeps a newer copy another tab cached '
        'from a page read before it', () async {
      await seedConfirmed(rating: 5);
      await repo.updateCollectionEntry(id: _kServerId, rating: 7);
      final ratingOp = await parkNewest();
      final otherTab = GameCollectionRepositoryImpl(
        db: db,
        syncQueue: queue,
        currentUserId: _kUserId,
        clock: FixedClockService(DateTime.utc(2026, 10, 17, 12)),
      );

      await repo.discardQueuedOp(ratingOp.id);
      final askedAfter = await repo.removalMark();
      await otherTab.mergeFromServer([
        _server(
          quantity: 2,
          rating: 5,
        ).copyWith(updatedAt: DateTime.utc(2026, 3)),
      ], removalsSince: await otherTab.removalMark());
      await repo.mergeFromServer([
        _server(rating: 5),
      ], removalsSince: askedAfter);

      final row = (await rows()).single;
      expect(row.quantity, 2, reason: "the other tab's newer copy");
      expect(row.rating, 5);
      expect(row.isDirty, isFalse);
    });

    test('with another op still queued, leaves out a stuck edit that one '
        'acknowledged since replaced', () async {
      await seedConfirmed(rating: 5);
      await repo.updateCollectionEntry(id: _kServerId, rating: 9);
      final stuckRating = await parkNewest();
      await repo.updateCollectionEntry(id: _kServerId, rating: 7);
      final laterRating = (await queue.getPendingEntries()).single;
      await repo.reconcileFromServer(
        _server(rating: 7),
        completedSyncQueueId: laterRating.id,
      );
      await repo.updateCollectionEntry(id: _kServerId, quantity: 3);
      final quantityOp = await parkNewest();

      await repo.discardQueuedOp(quantityOp.id);
      await hydrate(_server(rating: 7));

      final row = (await rows()).single;
      expect(row.rating, 7, reason: 'as the acknowledgement left it');
      expect(row.quantity, 1, reason: "the server's");
      expect(row.isDirty, isTrue);
      expect((await queue.getOutstandingEntries()).map((e) => e.id), [
        stuckRating.id,
      ]);
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

    test('takes a later re-add and removal with it, and brings the entry '
        'back as the server has it', () async {
      await seedConfirmed();
      await repo.removeFromCollection(_kServerId);
      final removeOp = await parkNewest();
      await add(quantity: 2);
      final readdOp = await parkNewest();
      await repo.removeFromCollection(_kServerId);

      await repo.discardQueuedOp(removeOp.id);

      final row = (await rows()).single;
      expect(row.deletedAt, isNull);
      expect(row.isDirty, isFalse);
      expect(row.isLocalOnly, isFalse);
      expect(await queue.getAllEntries(), isEmpty);
      expect(await repo.getCollection(), hasLength(1));

      // The re-add went with it.
      expect(await repo.discardQueuedOp(readdOp.id), isFalse);
    });

    test('takes a later re-add and update with it', () async {
      await seedConfirmed();
      await repo.removeFromCollection(_kServerId);
      final removeOp = await parkNewest();
      await add(quantity: 2);
      await parkNewest();
      await repo.updateCollectionEntry(id: _kServerId, rating: 8);

      await repo.discardQueuedOp(removeOp.id);

      final row = (await rows()).single;
      expect(row.deletedAt, isNull);
      expect(row.isDirty, isFalse);
      expect(await queue.getAllEntries(), isEmpty);
    });

    test('after an update still queued, has the next hydrate put back the '
        "server's values under that update's", () async {
      await seedConfirmed(rating: 5);
      await repo.updateCollectionEntry(id: _kServerId, rating: 7);
      final ratingOp = await parkNewest();
      await repo.removeFromCollection(_kServerId);
      final removeOp = await parkNewest();
      await add(quantity: 3);

      await repo.discardQueuedOp(removeOp.id);
      await hydrate(_server(rating: 5));

      final row = (await rows()).single;
      expect(row.deletedAt, isNull);
      expect(row.quantity, 1, reason: 'the re-add went with the removal');
      expect(row.rating, 7);
      expect(row.isDirty, isTrue);
      expect((await queue.getAllEntries()).map((e) => e.id), [ratingOp.id]);
    });

    test('refuses while a later op for the entry is being sent, changing '
        'nothing', () async {
      await seedConfirmed();
      await repo.removeFromCollection(_kServerId);
      final removeOp = await parkNewest();
      await add(quantity: 2);
      final readdOp = (await queue.getOutstandingEntries()).last;
      expect(await queue.claim(readdOp.id), isTrue);
      final before = await rows();

      await expectLater(repo.discardQueuedOp(removeOp.id), throwsStateError);

      expect(await rows(), before);
      expect(await queue.getAllEntries(), hasLength(2));
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

  // A discard through another tab leaves the row for a merge to rebuild, as
  // one through this tab does, but moves only that tab's mark. A hydrate
  // here reads the mark to choose between a delta and a full drain, and the
  // server's copy did not change, so only a full drain rebuilds the row.
  group("another tab's discard", () {
    late GameCollectionRepositoryImpl otherTab;

    setUp(() {
      otherTab = GameCollectionRepositoryImpl(
        db: db,
        syncQueue: queue,
        currentUserId: _kUserId,
        clock: FixedClockService(DateTime.utc(2026, 10, 17, 12)),
      );
    });

    /// Has [otherTab] edit the entry, the server refuse it, and the user
    /// discard it there.
    Future<void> discardThere() async {
      await otherTab.updateCollectionEntry(id: _kServerId, rating: 9);
      final updateOp = await parkNewest();
      expect(await otherTab.discardQueuedOp(updateOp.id), isTrue);
    }

    test('moves the removal mark once, at its next read', () async {
      await seedConfirmed(rating: 5);
      final before = await repo.removalMark();

      await discardThere();
      final first = await repo.removalMark();
      final second = await repo.removalMark();

      expect(first, greaterThan(before));
      expect(second, first);
    });

    test('moves it again after a merge here rebuilt the row', () async {
      await seedConfirmed(rating: 5);
      await discardThere();
      await hydrate(_server(rating: 5));
      expect((await rows()).single.rating, 5);
      final rebuilt = await repo.removalMark();

      await discardThere();

      expect(await repo.removalMark(), greaterThan(rebuilt));
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
