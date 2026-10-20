import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/household_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/fixed_clock.dart';

const _kUserId = 'user-abc';

/// Discarding a stuck household create undoes it locally (#190).
void main() {
  late ServerDatabase db;
  late SyncQueueRepositoryImpl queue;
  late HouseholdRepositoryImpl repo;

  setUp(() {
    db = inMemoryServerDatabase();
    final clock = FixedClockService(DateTime.utc(2026, 10, 17, 12));
    queue = SyncQueueRepositoryImpl(db, clock, userId: _kUserId);
    repo = HouseholdRepositoryImpl(
      db: db,
      currentUserId: () => _kUserId,
      syncQueue: queue,
      clock: clock,
    );
  });

  tearDown(() async => db.close());

  test('deletes the local-only household, its members and the op', () async {
    final created = await repo.create(name: 'Smiths');
    await queue.park(created.syncQueueId, error: 'rejected: 400');

    expect(await repo.discardQueuedOp(created.syncQueueId), isTrue);

    expect(await db.select(db.householdsTable).get(), isEmpty);
    expect(await db.select(db.householdMembersTable).get(), isEmpty);
    expect(await queue.getAllEntries(), isEmpty);
    expect(await repo.getHouseholds(), isEmpty);
  });

  test('leaves other households alone', () async {
    final kept = await repo.create(name: 'Joneses');
    final discarded = await repo.create(name: 'Smiths');
    await queue.park(discarded.syncQueueId, error: 'rejected: 400');

    await repo.discardQueuedOp(discarded.syncQueueId);

    expect((await repo.getHouseholds()).map((h) => h.id), [kept.household.id]);
    expect((await queue.getAllEntries()).map((e) => e.id), [kept.syncQueueId]);
  });

  test('changes nothing for a create that is no longer stuck, such as one '
      'another tab retried', () async {
    final created = await repo.create(name: 'Smiths');
    await queue.park(created.syncQueueId, error: 'rejected: 400');
    await queue.retry(created.syncQueueId);

    expect(await repo.discardQueuedOp(created.syncQueueId), isFalse);

    expect(await repo.getHouseholds(), hasLength(1));
    expect(await queue.getAllEntries(), hasLength(1));
  });

  test('changes nothing for a completed or unknown entry', () async {
    final created = await repo.create(name: 'Smiths');
    await queue.markCompleted(created.syncQueueId);

    await repo.discardQueuedOp(created.syncQueueId);
    await repo.discardQueuedOp('nonexistent');

    expect(await repo.getHouseholds(), hasLength(1));
    expect(await queue.getAllEntries(), hasLength(1));
  });

  test('throws for a collection op, which is not its to discard', () async {
    final entry = await queue.enqueue(
      const RemoveFromCollectionOperation(collectionId: 'col-1'),
    );

    await expectLater(repo.discardQueuedOp(entry.id), throwsArgumentError);

    expect(await queue.getAllEntries(), hasLength(1));
  });
}
