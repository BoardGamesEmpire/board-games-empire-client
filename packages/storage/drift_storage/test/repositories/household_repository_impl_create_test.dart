import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/household_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/fixed_clock.dart';

// Create + reconcile write path (#39). Uses a real SyncQueueRepositoryImpl
// over the same in-memory DB so the enqueued op and its completion are
// asserted end-to-end, and a FixedClockService so timestamps are pinned.

const _kUserId = 'user-abc';
final _fixed = DateTime.utc(2024, 1, 15, 10, 30);

void main() {
  late ServerDatabase db;
  late FixedClockService clock;
  late SyncQueueRepositoryImpl syncQueue;
  late HouseholdRepositoryImpl repo;

  setUp(() {
    db = ServerDatabase.memory();
    clock = FixedClockService(_fixed);
    syncQueue = SyncQueueRepositoryImpl(db, clock);
    repo = HouseholdRepositoryImpl(
      db: db,
      currentUserId: () => _kUserId,
      syncQueue: syncQueue,
      clock: clock,
    );
  });

  tearDown(() async => db.close());

  Future<HouseholdsTableData?> rawHousehold(String id) => (db.select(
    db.householdsTable,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  group('create', () {
    test(
      'writes an optimistic household with sync flags set + trimmed name',
      () async {
        final created = await repo.create(name: '  Game Night HQ  ');

        expect(created.household.name, 'Game Night HQ');
        expect(created.household.isLocalOnly, isTrue);
        expect(created.household.isDirty, isTrue);
        expect(created.household.createdAt, _fixed);
        expect(created.household.updatedAt, _fixed);
      },
    );

    test('returns the enqueued op id as syncQueueId', () async {
      final created = await repo.create(name: 'HQ');
      final entry = (await syncQueue.getPendingEntries()).single;
      expect(created.syncQueueId, entry.id);
    });

    test('synthesizes a HouseholdOwner member for the current user', () async {
      final created = await repo.create(name: 'HQ');

      final member = await repo.getCurrentUserMember(created.household.id);
      expect(member, isNotNull);
      expect(member!.userId, _kUserId);
      expect(member.householdId, created.household.id);
      expect(member.role, HouseholdRole.householdOwner);
    });

    test(
      'makes the household immediately visible through the read gate',
      () async {
        final created = await repo.create(name: 'HQ');

        expect(await repo.getHousehold(created.household.id), isNotNull);
        final list = await repo.getHouseholds();
        expect(list.map((h) => h.id), contains(created.household.id));
      },
    );

    test(
      'enqueues a CreateHouseholdOperation with the localId and fields',
      () async {
        final created = await repo.create(
          name: 'HQ',
          description: 'desc',
          image: 'x.png',
          language: 'pt-BR',
          visibility: 'Friends',
        );

        final entries = await syncQueue.getPendingEntries();
        expect(entries, hasLength(1));

        final op = entries.single.operation;
        expect(op, isA<CreateHouseholdOperation>());
        final create = op as CreateHouseholdOperation;
        expect(create.localId, created.household.id);
        expect(create.name, 'HQ');
        expect(create.description, 'desc');
        expect(create.image, 'x.png');
        expect(create.language, 'pt-BR');
        expect(create.visibility, 'Friends');
      },
    );

    test(
      'rejects a blank name without touching the cache or the queue',
      () async {
        await expectLater(
          repo.create(name: '   '),
          throwsA(isA<ArgumentError>()),
        );

        expect(await repo.getHouseholds(), isEmpty);
        expect(await syncQueue.getAllEntries(), isEmpty);
      },
    );
  });

  group('reconcileCreatedHousehold', () {
    test('server id == localId: clears flags and completes the op', () async {
      final created = await repo.create(name: 'HQ');

      await repo.reconcileCreatedHousehold(
        created.household.copyWith(isDirty: false, isLocalOnly: false),
        localId: created.household.id,
        completedSyncQueueId: created.syncQueueId,
      );

      final row = await rawHousehold(created.household.id);
      expect(row, isNotNull);
      expect(row!.isDirty, isFalse);
      expect(row.isLocalOnly, isFalse);

      expect(
        (await syncQueue.getAllEntries()).single.status,
        SyncStatus.completed,
      );
    });

    test(
      'server id != localId: migrates member, drops stale row, completes op',
      () async {
        final created = await repo.create(name: 'HQ');
        final server = created.household.copyWith(
          id: 'hh_server',
          isDirty: false,
          isLocalOnly: false,
        );

        await repo.reconcileCreatedHousehold(
          server,
          localId: created.household.id,
          completedSyncQueueId: created.syncQueueId,
        );

        // Stale optimistic row is gone; canonical row present + confirmed.
        expect(await rawHousehold(created.household.id), isNull);
        final canonical = await rawHousehold('hh_server');
        expect(canonical, isNotNull);
        expect(canonical!.isLocalOnly, isFalse);
        expect(canonical.isDirty, isFalse);

        // Owner member re-pointed onto the canonical id -> still visible.
        expect(await repo.getHousehold('hh_server'), isNotNull);
        final member = await repo.getCurrentUserMember('hh_server');
        expect(member, isNotNull);
        expect(member!.role, HouseholdRole.householdOwner);
        expect(await repo.getCurrentUserMember(created.household.id), isNull);

        expect(
          (await syncQueue.getAllEntries()).single.status,
          SyncStatus.completed,
        );
      },
    );

    test(
      'leaves the queue untouched when no completedSyncQueueId is given',
      () async {
        final created = await repo.create(name: 'HQ');

        await repo.reconcileCreatedHousehold(
          created.household.copyWith(
            id: 'hh_server',
            isDirty: false,
            isLocalOnly: false,
          ),
          localId: created.household.id,
        );

        expect(await syncQueue.getPendingEntries(), hasLength(1));
      },
    );
  });
}
