import 'dart:async';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, driftRuntimeOptions;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_collection_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/fixed_clock.dart';
import '../support/platform_game_fixture.dart';

const _kUserId = 'user-abc';
const _kServerId = 'gc-server';

/// The server's answer to the add of the fixture platform game.
GameCollection _server({String id = _kServerId}) => GameCollection(
  id: id,
  userId: _kUserId,
  platformGameId: kFixturePlatformGameId,
  medium: GameMedium.physical,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026, 2),
);

/// An offline add's entry moves to the server's id when the add is
/// reconciled, and a screen holding the local id has to find where it went
/// (#693), in whichever tab it is open and after a reload.
void main() {
  late _Faults faults;
  late ServerDatabase db;
  late FixedClockService clock;
  late SyncQueueRepositoryImpl queue;
  late GameCollectionRepositoryImpl repo;

  setUp(() async {
    faults = _Faults();
    db = ServerDatabase(NativeDatabase.memory().interceptWith(faults));
    clock = FixedClockService(DateTime.utc(2026, 10, 5, 12));
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

  // A second repository over the same database: what another web tab holds.
  GameCollectionRepositoryImpl otherTab() => GameCollectionRepositoryImpl(
    db: db,
    syncQueue: queue,
    currentUserId: _kUserId,
    clock: clock,
  );

  Future<List<CollectionMovesTableData>> moves() =>
      db.select(db.collectionMovesTable).get();

  Future<({GameCollection entry, String syncQueueId})> add() async {
    final added = await repo.addToCollection(
      platformGameId: kFixturePlatformGameId,
      medium: GameMedium.physical,
    );
    final op = (await queue.getAllEntries()).single;
    return (entry: added.entry, syncQueueId: op.id);
  }

  Future<void> reconcile(
    ({GameCollection entry, String syncQueueId}) added, {
    String id = _kServerId,
  }) => repo.reconcileFromServer(
    _server(id: id),
    completedSyncQueueId: added.syncQueueId,
  );

  test("an add's reconcile records the move and reconciledCollectionEntryId "
      'returns the server id', () async {
    final added = await add();

    await reconcile(added);

    expect(repo.reconciledCollectionEntryId(added.entry.id), _kServerId);
    final [move] = await moves();
    expect(move.localId, added.entry.id);
    expect(move.serverId, _kServerId);
  });

  test('the move is written in the transaction that deletes the local '
      'row', () async {
    final added = await add();
    faults.failCollectionUpserts = true;

    await expectLater(reconcile(added), throwsA(isA<_UpsertFault>()));
    faults.failCollectionUpserts = false;

    expect(await moves(), isEmpty);
    final rows = await db.select(db.gameCollectionsTable).get();
    expect(rows.map((r) => r.id), [added.entry.id]);
    expect(repo.reconciledCollectionEntryId(added.entry.id), isNull);
  });

  test('an entry already on its server id records no move', () async {
    final added = await add();

    await reconcile(added, id: added.entry.id);

    expect(await moves(), isEmpty);
    expect(repo.reconciledCollectionEntryId(added.entry.id), isNull);
  });

  test('answers null for an id nothing reconciled', () async {
    final added = await add();

    expect(repo.reconciledCollectionEntryId(added.entry.id), isNull);
  });

  test('still answers a move after disposal, one another repository '
      'recorded included', () async {
    // A screen's queued cache emission can still be handled while the
    // user-session scope tears down. Disposal must not forget the moves,
    // or the screen would read its moved entry as removed.
    final added = await add();
    await reconcile(added);
    final other = otherTab();
    // Its emission on the local id reads the move from the table.
    await other.watchCollectionListItem(added.entry.id).first;
    await repo.onDispose();
    await other.onDispose();

    expect(repo.reconciledCollectionEntryId(added.entry.id), _kServerId);
    expect(other.reconciledCollectionEntryId(added.entry.id), _kServerId);
  });

  group('a move recorded by another connection is seen on the next '
      'emission', () {
    test('of the entry watch, the one that drops the local id', () async {
      final added = await add();
      final other = otherTab();
      final seen = <({String? id, String? answer})>[];
      final sub = other
          .watchCollectionListItem(added.entry.id)
          .listen(
            (item) => seen.add((
              id: item?.entry.id,
              answer: other.reconciledCollectionEntryId(added.entry.id),
            )),
          );
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(seen, [(id: added.entry.id, answer: null)]);

      await reconcile(added);
      await pumpEventQueue();

      expect(seen.last, (id: null, answer: _kServerId));
    });

    test("the entry watch reads only its own id's move", () async {
      final added = await add();
      await reconcile(added);
      await db
          .into(db.collectionMovesTable)
          .insert(
            CollectionMovesTableCompanion.insert(
              localId: 'gc-other-local',
              serverId: 'gc-other-server',
            ),
          );
      final other = otherTab();

      await other.watchCollectionListItem(added.entry.id).first;

      expect(other.reconciledCollectionEntryId(added.entry.id), _kServerId);
      expect(other.reconciledCollectionEntryId('gc-other-local'), isNull);
    });

    test('not by the list watch, which reads no moves', () async {
      final added = await add();
      final other = otherTab();
      final seen = <List<String>>[];
      final sub = other.watchCollectionListItems().listen(
        (items) => seen.add([for (final item in items) item.entry.id]),
      );
      addTearDown(sub.cancel);
      await pumpEventQueue();

      await reconcile(added);
      await pumpEventQueue();

      // The list has the server's row in place of the local one.
      expect(seen.last, [_kServerId]);
      expect(other.reconciledCollectionEntryId(added.entry.id), isNull);
    });

    test('of a repository opened after the reconcile, as on a '
        'reload', () async {
      final added = await add();
      await reconcile(added);
      final later = otherTab();

      // Nothing read yet: the screen recovers on the first emission.
      expect(later.reconciledCollectionEntryId(added.entry.id), isNull);
      await later.watchCollectionListItem(added.entry.id).first;
      expect(later.reconciledCollectionEntryId(added.entry.id), _kServerId);
    });
  });

  group('an edit or a removal begun before the move goes to the server '
      'id', () {
    Future<GameCollectionsTableData?> serverRow() => (db.select(
      db.gameCollectionsTable,
    )..where((t) => t.id.equals(_kServerId))).getSingleOrNull();

    test('an edit sent on the local id in the turn the reconcile starts '
        'applies to the server row', () async {
      final added = await add();

      // Drift runs the two transactions one after the other, the
      // reconcile's first: the edit finds the local row gone.
      final reconciling = reconcile(added);
      final updated = await repo.updateCollectionEntry(
        id: added.entry.id,
        quantity: 3,
      );
      await reconciling;

      expect(updated.entry.id, _kServerId);
      expect(updated.entry.quantity, 3);
      expect(updated.operation.collectionId, _kServerId);
      final row = await serverRow();
      expect(row?.quantity, 3);
      expect(row?.isDirty, isTrue);
    });

    test('a removal sent on the local id in the turn the reconcile starts '
        'removes the server row', () async {
      final added = await add();

      final reconciling = reconcile(added);
      final removed = await repo.removeFromCollection(added.entry.id);
      await reconciling;

      expect(removed?.operation.collectionId, _kServerId);
      expect((await serverRow())?.deletedAt, isNotNull);
      final queued = await queue.getAllEntries();
      expect(
        queued.map((op) => op.id),
        contains(removed?.syncQueueId),
      );
    });

    test('the move is read from the table, so a repository that has not '
        'seen it still follows it', () async {
      final added = await add();
      await reconcile(added);
      // Nothing it has watched has read the move.
      final later = otherTab();
      expect(later.reconciledCollectionEntryId(added.entry.id), isNull);

      final updated = await later.updateCollectionEntry(
        id: added.entry.id,
        favorite: true,
      );
      final removed = await later.removeFromCollection(added.entry.id);

      expect(updated.entry.id, _kServerId);
      expect(updated.entry.favorite, isTrue);
      expect(removed?.operation.collectionId, _kServerId);
      expect((await serverRow())?.deletedAt, isNotNull);
    });

    test('an id with no row and no move still throws', () async {
      await expectLater(
        repo.updateCollectionEntry(id: 'gc-unknown', quantity: 2),
        throwsStateError,
      );
      await expectLater(
        repo.removeFromCollection('gc-unknown'),
        throwsStateError,
      );
    });
  });

  test('disposal waits for a moves read a watch has under way', () async {
    // The suspend path closes the database as soon as disposal returns,
    // and cancelling a watch does not wait for a read it started.
    final reads = _HeldMovesReads();
    // A second database, on its own executor: not the race drift warns of.
    final warned = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(
      () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = warned,
    );
    final held = ServerDatabase(NativeDatabase.memory().interceptWith(reads));
    addTearDown(held.close);
    final heldRepo = GameCollectionRepositoryImpl(
      db: held,
      syncQueue: SyncQueueRepositoryImpl(held, clock, userId: _kUserId),
      currentUserId: _kUserId,
      clock: clock,
    );
    // No row for the id, so the watch reads its move before answering.
    final sub = heldRepo.watchCollectionListItem('gc-missing').listen((_) {});
    addTearDown(sub.cancel);
    await reads.started;

    var disposed = false;
    final disposing = heldRepo.onDispose().then((_) => disposed = true);
    await pumpEventQueue();
    expect(disposed, isFalse);

    reads.release();
    await disposing;
  });
}

/// Thrown by [_Faults] in place of the server row's upsert.
class _UpsertFault implements Exception {}

/// Fails the upsert that writes a server row into `game_collections`
/// while [failCollectionUpserts] is set.
class _Faults extends QueryInterceptor {
  bool failCollectionUpserts = false;

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (failCollectionUpserts &&
        statement.contains('INSERT INTO "game_collections"') &&
        statement.contains('ON CONFLICT')) {
      throw _UpsertFault();
    }
    return executor.runInsert(statement, args);
  }
}

/// Holds the first `collection_moves` read until [release].
class _HeldMovesReads extends QueryInterceptor {
  final _started = Completer<void>();
  final _released = Completer<void>();

  /// Completes when the first moves read reaches the database.
  Future<void> get started => _started.future;

  void release() => _released.complete();

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('collection_moves')) {
      if (!_started.isCompleted) _started.complete();
      await _released.future;
    }
    return executor.runSelect(statement, args);
  }
}
