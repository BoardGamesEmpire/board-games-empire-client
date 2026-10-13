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

/// The server's copy of the fixture game's entry.
GameCollection _server({
  String id = _kServerId,
  GameMedium medium = GameMedium.physical,
  int quantity = 1,
  DateTime? deletedAt,
  DateTime? updatedAt,
}) => GameCollection(
  id: id,
  userId: _kUserId,
  platformGameId: kFixturePlatformGameId,
  medium: medium,
  quantity: quantity,
  deletedAt: deletedAt,
  createdAt: DateTime.utc(2026),
  updatedAt: updatedAt ?? DateTime.utc(2026, 2),
);

/// The server's tombstone for the fixture game's entry.
GameCollection _tombstone() =>
    _server(deletedAt: DateTime.utc(2026, 3), updatedAt: DateTime.utc(2026, 3));

/// A hydrate page the server answered before the drain confirmed a removal
/// still holds the entry live (#121). The confirmation has already purged the
/// rows a merge compares a copy against, so merged as read, that copy brings
/// the entry back. The hydrate passes the mark it read before requesting the
/// page, and a removal confirmed since keeps the copy out.
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

  /// Every row, tombstones included.
  Future<List<GameCollectionsTableData>> rows() =>
      db.select(db.gameCollectionsTable).get();

  /// A hydrated entry the user then removed: a dirty tombstone, with its
  /// removal queued. Returns the removal's queue id.
  Future<String> removedEntry() async {
    await repo.mergeFromServer([_server()]);
    await repo.removeFromCollection(_kServerId);
    return (await queue.getPendingEntries()).single.id;
  }

  group('a page read before a removal was confirmed', () {
    test('leaves the entry removed when the server answered with a '
        'tombstone', () async {
      final removal = await removedEntry();
      final mark = await repo.removalMark();
      await repo.reconcileFromServer(
        _tombstone(),
        completedSyncQueueId: removal,
      );

      await repo.mergeFromServer([_server()], removalsSince: mark);

      expect(await rows(), isEmpty);
    });

    test('leaves the entry removed when the server answered that it was '
        'already removed', () async {
      final removal = await removedEntry();
      final mark = await repo.removalMark();
      await repo.confirmRemoved(_kServerId, completedSyncQueueId: removal);

      await repo.mergeFromServer([_server()], removalsSince: mark);

      expect(await rows(), isEmpty);
    });

    test("still writes the page's other entries", () async {
      final removal = await removedEntry();
      final mark = await repo.removalMark();
      await repo.confirmRemoved(_kServerId, completedSyncQueueId: removal);

      await repo.mergeFromServer([
        _server(),
        _server(id: 'gc-digital', medium: GameMedium.digital),
      ], removalsSince: mark);

      expect((await rows()).single.id, 'gc-digital');
    });
  });

  test('a page read after the removal was confirmed writes the entry, live '
      'again on the server', () async {
    // Re-added on another device: the next hydrate reads its mark after the
    // confirmation.
    final removal = await removedEntry();
    await repo.confirmRemoved(_kServerId, completedSyncQueueId: removal);
    final mark = await repo.removalMark();

    await repo.mergeFromServer([
      _server(quantity: 3, updatedAt: DateTime.utc(2026, 11)),
    ], removalsSince: mark);

    final row = (await rows()).single;
    expect(row.deletedAt, isNull);
    expect(row.quantity, 3);
  });

  test('a tombstone a hydrate merges holds nothing back', () async {
    // Removed and then re-added on another device: one pass can read the
    // tombstone on a page and the re-add on its catch-up.
    await repo.mergeFromServer([_server()]);
    final mark = await repo.removalMark();

    await repo.mergeFromServer([_tombstone()], removalsSince: mark);
    await repo.mergeFromServer([
      _server(quantity: 2, updatedAt: DateTime.utc(2026, 4)),
    ], removalsSince: mark);

    final row = (await rows()).single;
    expect(row.deletedAt, isNull);
    expect(row.quantity, 2);
  });
}
