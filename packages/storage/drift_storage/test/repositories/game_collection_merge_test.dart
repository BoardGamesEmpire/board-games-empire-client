import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_collection_repository_impl.dart';

import '../support/platform_game_fixture.dart';
import '../support/system_clock.dart';

class _MockSyncQueue extends Mock implements SyncQueueRepository {}

const _kUserId = 'user-abc';

/// A server-confirmed entry for the fixture platform game, as a hydrate reads
/// it.
GameCollection _server({
  String id = 'gc-server',
  int quantity = 3,
  String? comment = 'From the server',
  DateTime? deletedAt,
  DateTime? updatedAt,
}) => GameCollection(
  id: id,
  userId: _kUserId,
  platformGameId: kFixturePlatformGameId,
  medium: GameMedium.physical,
  quantity: quantity,
  comment: comment,
  deletedAt: deletedAt,
  createdAt: DateTime.utc(2026),
  updatedAt: updatedAt ?? DateTime.utc(2026, 2),
);

/// A server-driven write must leave a row the sync queue still owns alone
/// (#259). The hydrate is the first caller that writes server state over rows
/// the user may have changed offline, and `reconcileFromServer` would clear
/// their flags and overwrite their values — the bug #298 fixed for households.
void main() {
  setUpAll(() {
    registerFallbackValue(
      const AddToCollectionOperation(
        localId: '',
        platformGameId: '',
        medium: '',
        quantity: 0,
      ),
    );
  });

  late ServerDatabase db;
  late _MockSyncQueue queue;
  late GameCollectionRepositoryImpl repo;

  setUp(() async {
    db = inMemoryServerDatabase();
    queue = _MockSyncQueue();
    when(() => queue.enqueue(any())).thenAnswer(
      (_) async => SyncQueueEntry(
        id: 'sq-1',
        payload: '{}',
        createdAt: DateTime.now().toUtc(),
      ),
    );
    when(
      () => queue.remapCollectionId(
        oldCollectionId: any(named: 'oldCollectionId'),
        newCollectionId: any(named: 'newCollectionId'),
      ),
    ).thenAnswer((_) async => 0);
    repo = GameCollectionRepositoryImpl(
      db: db,
      syncQueue: queue,
      currentUserId: _kUserId,
      clock: const SystemClockService(),
    );
    await seedPlatformGame(db);
  });

  tearDown(() async => db.close());

  /// Every row for the user, tombstones included — what the read paths hide.
  Future<List<GameCollectionsTableData>> allRows() =>
      db.select(db.gameCollectionsTable).get();

  group('mergeFromServer (#259)', () {
    test('stores a server entry the cache does not have, clean', () async {
      await repo.mergeFromServer([_server()]);

      final entry = (await repo.getCollection()).single;
      expect(entry.id, 'gc-server');
      expect(entry.quantity, 3);
      expect(entry.isDirty, isFalse);
      expect(entry.isLocalOnly, isFalse);
    });

    test('refreshes a clean row with the server values', () async {
      await repo.mergeFromServer([_server()]);
      await repo.mergeFromServer([_server(quantity: 5, comment: 'Edited')]);

      final entry = (await repo.getCollection()).single;
      expect(entry.quantity, 5);
      expect(entry.comment, 'Edited');
    });

    test('leaves a dirty row untouched, values and flags', () async {
      await repo.mergeFromServer([_server()]);
      await repo.updateCollectionEntry(id: 'gc-server', quantity: 9);

      await repo.mergeFromServer([_server(quantity: 3)]);

      final entry = (await repo.getCollection()).single;
      expect(entry.quantity, 9);
      expect(entry.isDirty, isTrue);
    });

    test('leaves a local tombstone in place rather than bringing the entry '
        'back', () async {
      await repo.mergeFromServer([_server()]);
      await repo.removeFromCollection('gc-server');

      await repo.mergeFromServer([_server()]);

      expect(await repo.getCollection(), isEmpty);
      expect((await allRows()).single.deletedAt, isNotNull);
    });

    test('leaves a local-only entry alone when the server holds the same '
        'game under its own id', () async {
      final local = await repo.addToCollection(
        platformGameId: kFixturePlatformGameId,
        medium: GameMedium.physical,
        quantity: 2,
      );

      await repo.mergeFromServer([_server(id: 'gc-other-device')]);

      final entry = (await repo.getCollection()).single;
      expect(entry.id, local.id);
      expect(entry.quantity, 2);
      expect(entry.isLocalOnly, isTrue);
      verifyNever(
        () => queue.remapCollectionId(
          oldCollectionId: any(named: 'oldCollectionId'),
          newCollectionId: any(named: 'newCollectionId'),
        ),
      );
    });

    test('a server tombstone purges a clean row', () async {
      await repo.mergeFromServer([_server()]);

      await repo.mergeFromServer([_server(deletedAt: DateTime.utc(2026, 3))]);

      expect(await allRows(), isEmpty);
    });

    test('a server tombstone skips a dirty row', () async {
      await repo.mergeFromServer([_server()]);
      await repo.updateCollectionEntry(id: 'gc-server', quantity: 9);

      await repo.mergeFromServer([_server(deletedAt: DateTime.utc(2026, 3))]);

      final entry = (await repo.getCollection()).single;
      expect(entry.quantity, 9);
      expect(entry.isDirty, isTrue);
    });

    // An older read must not roll a clean row back: a hydrate page fetched
    // before the drain acknowledged an edit still carries the pre-edit copy.
    test('keeps a clean row the server stamped later than this copy', () async {
      await repo.mergeFromServer([
        _server(quantity: 5, updatedAt: DateTime.utc(2026, 3)),
      ]);

      await repo.mergeFromServer([_server(quantity: 3)]);

      expect((await repo.getCollection()).single.quantity, 5);
    });

    test('an older server tombstone keeps a clean row stamped later', () async {
      await repo.mergeFromServer([_server(updatedAt: DateTime.utc(2026, 4))]);

      await repo.mergeFromServer([
        _server(
          deletedAt: DateTime.utc(2026, 3),
          updatedAt: DateTime.utc(2026, 3),
        ),
      ]);

      expect(await repo.getCollection(), hasLength(1));
    });

    test('rejects a page holding another user\'s entry, and writes none of '
        'it', () async {
      final foreign = _server(id: 'gc-foreign')
          .copyWith(userId: 'someone-else');

      await expectLater(
        repo.mergeFromServer([_server(), foreign]),
        throwsStateError,
      );
      expect(await allRows(), isEmpty);
    });

    test('never closes a queue entry', () async {
      await repo.mergeFromServer([_server()]);

      verifyNever(() => queue.markCompleted(any()));
    });
  });
}
