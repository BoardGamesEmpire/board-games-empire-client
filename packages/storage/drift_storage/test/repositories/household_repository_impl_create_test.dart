import 'package:drift/drift.dart' show TableUpdateQuery, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
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
    db = inMemoryServerDatabase();
    clock = FixedClockService(_fixed);
    syncQueue = SyncQueueRepositoryImpl(db, clock, userId: _kUserId);
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
      'server id != localId, with the server copy already hydrated: keeps '
      "the server's owner row, drops the synthesized one, completes the op",
      () async {
        // A hydrate that runs before the reconcile caches the server's
        // household and its owner membership. Until the reconcile, the
        // household is listed twice: once per id.
        final created = await repo.create(name: 'HQ');
        final server = created.household.copyWith(
          id: 'hh_server',
          isDirty: false,
          isLocalOnly: false,
        );
        await repo.cacheHousehold(server);
        await repo.cacheMembers([
          HouseholdMember(
            id: 'm_server',
            userId: _kUserId,
            householdId: 'hh_server',
            role: HouseholdRole.householdOwner,
            createdAt: _fixed,
            updatedAt: _fixed,
          ),
        ]);
        expect(await repo.getHouseholds(), hasLength(2));

        await repo.reconcileCreatedHousehold(
          server,
          localId: created.household.id,
          completedSyncQueueId: created.syncQueueId,
        );

        final households = await repo.getHouseholds();
        expect(households.map((h) => h.id), ['hh_server']);
        final members = await repo.getMembers('hh_server');
        expect(members.map((m) => m.id), ['m_server']);
        expect(await repo.getCurrentUserMember(created.household.id), isNull);
        expect(
          (await syncQueue.getAllEntries()).single.status,
          SyncStatus.completed,
        );
      },
    );

    test('server id != localId: a hydrated server row that is dirty keeps '
        'its changes', () async {
      // The canonical row is a server copy like any other, so the
      // reconcile writes it by the same rule as a hydrate: a row the
      // queue still owns is left alone. Only the create's own row is
      // acknowledged.
      final created = await repo.create(name: 'HQ');
      final server = created.household.copyWith(
        id: 'hh_server',
        isDirty: false,
        isLocalOnly: false,
      );
      await repo.cacheHousehold(server);
      await repo.cacheMembers([
        HouseholdMember(
          id: 'm_server',
          userId: _kUserId,
          householdId: 'hh_server',
          role: HouseholdRole.householdOwner,
          createdAt: _fixed,
          updatedAt: _fixed,
        ),
      ]);
      // Stands in for an offline edit of the hydrated copy.
      await (db.update(
        db.householdsTable,
      )..where((t) => t.id.equals('hh_server'))).write(
        const HouseholdsTableCompanion(
          name: Value('HQ renamed'),
          isDirty: Value(true),
        ),
      );

      await repo.reconcileCreatedHousehold(
        server,
        localId: created.household.id,
        completedSyncQueueId: created.syncQueueId,
      );

      final canonical = await repo.getHousehold('hh_server');
      expect(canonical!.name, equals('HQ renamed'));
      expect(canonical.isDirty, isTrue);
      expect(await rawHousehold(created.household.id), isNull);
      expect(
        (await syncQueue.getAllEntries()).single.status,
        SyncStatus.completed,
      );
    });

    group('the id it records', () {
      // A screen holding the local id — open when the reconcile runs, or
      // rebuilt on that id afterwards — needs to find where the household
      // went (#306).
      test('answers the server id for a local id it reconciled', () async {
        final created = await repo.create(name: 'HQ');

        await repo.reconcileCreatedHousehold(
          created.household.copyWith(
            id: 'hh_server',
            isDirty: false,
            isLocalOnly: false,
          ),
          localId: created.household.id,
          completedSyncQueueId: created.syncQueueId,
        );

        expect(repo.reconciledHouseholdId(created.household.id), 'hh_server');
      });

      test(
        'tells the household watchers once the record is readable',
        () async {
          // The reconcile's own table updates go out inside its transaction,
          // before the record exists, and a screen that hears them first
          // would take the vanished local row for a removal. An update after
          // the record makes every watcher re-read with it in place. Each
          // capture is the record as it stood when the update was delivered,
          // which for the transaction's own is before the record exists.
          final created = await repo.create(name: 'HQ');
          final seenAtDelivery = <String?>[];
          final sub = db
              .tableUpdates(TableUpdateQuery.onTable(db.householdsTable))
              .listen(
                (_) => seenAtDelivery.add(
                  repo.reconciledHouseholdId(created.household.id),
                ),
              );
          addTearDown(sub.cancel);

          await repo.reconcileCreatedHousehold(
            created.household.copyWith(
              id: 'hh_server',
              isDirty: false,
              isLocalOnly: false,
            ),
            localId: created.household.id,
            completedSyncQueueId: created.syncQueueId,
          );

          await pumpEventQueue();

          expect(seenAtDelivery, isNotEmpty);
          expect(seenAtDelivery.last, 'hh_server');
        },
      );

      test('answers null when the server kept the local id', () async {
        final created = await repo.create(name: 'HQ');

        await repo.reconcileCreatedHousehold(
          created.household.copyWith(isDirty: false, isLocalOnly: false),
          localId: created.household.id,
        );

        expect(repo.reconciledHouseholdId(created.household.id), isNull);
      });

      test('answers null for an id nothing reconciled', () async {
        final created = await repo.create(name: 'HQ');

        expect(repo.reconciledHouseholdId(created.household.id), isNull);
      });

      test('answers without throwing after disposal', () async {
        // A screen's queued cache emission can still be handled while the
        // user-session scope tears down, and asking must not crash it.
        final created = await repo.create(name: 'HQ');
        await repo.onDispose();

        expect(
          () => repo.reconciledHouseholdId(created.household.id),
          returnsNormally,
        );
      });

      test('records nothing when the reconcile rolls back', () async {
        final created = await repo.create(name: 'HQ');
        // The session scope popping between send and reconcile: completing
        // the queue entry throws inside the transaction.
        await syncQueue.onDispose();

        await expectLater(
          repo.reconcileCreatedHousehold(
            created.household.copyWith(
              id: 'hh_server',
              isDirty: false,
              isLocalOnly: false,
            ),
            localId: created.household.id,
            completedSyncQueueId: created.syncQueueId,
          ),
          throwsStateError,
        );

        expect(repo.reconciledHouseholdId(created.household.id), isNull);
        expect(await rawHousehold(created.household.id), isNotNull);
      });
    });

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
