import 'dart:async';

import 'package:drift/drift.dart'
    show
        ApplyInterceptor,
        QueryExecutor,
        QueryInterceptor,
        Value,
        driftRuntimeOptions;
import 'package:drift/native.dart' show NativeDatabase;
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
      // went (#306), in whichever tab it is open (#442).

      // Reconciles [created] onto `hh_server`, closing its queued op.
      Future<void> reconcile(
        ({Household household, String syncQueueId}) created,
      ) => repo.reconcileCreatedHousehold(
        created.household.copyWith(
          id: 'hh_server',
          isDirty: false,
          isLocalOnly: false,
        ),
        localId: created.household.id,
        completedSyncQueueId: created.syncQueueId,
      );

      // A second repository over the same database: what another web tab
      // holds.
      HouseholdRepositoryImpl otherTab() => HouseholdRepositoryImpl(
        db: db,
        currentUserId: () => _kUserId,
        syncQueue: syncQueue,
        clock: clock,
      );

      // Each emission's ids, with what [of] answered for [localId] when it
      // was delivered.
      Future<List<({List<String> ids, String? answer})>> watchAnswers(
        HouseholdRepositoryImpl of,
        String localId,
      ) async {
        final seen = <({List<String> ids, String? answer})>[];
        final sub = of.watchHouseholds().listen(
          (households) => seen.add((
            ids: households.map((h) => h.id).toList(),
            answer: of.reconciledHouseholdId(localId),
          )),
        );
        addTearDown(sub.cancel);
        await pumpEventQueue();
        return seen;
      }

      test('answers the server id for a local id it reconciled', () async {
        final created = await repo.create(name: 'HQ');

        await reconcile(created);

        expect(repo.reconciledHouseholdId(created.household.id), 'hh_server');
      });

      test('a household watcher sees the move on the emission that drops '
          'the local row', () async {
        // The screen asks on every emission, and the one without the local
        // row must already answer, or the screen takes it for a removal.
        final created = await repo.create(name: 'HQ');
        final seen = await watchAnswers(repo, created.household.id);

        await reconcile(created);
        await pumpEventQueue();

        final moved = seen.firstWhere(
          (s) => !s.ids.contains(created.household.id),
        );
        expect(moved.ids, ['hh_server']);
        expect(moved.answer, 'hh_server');
      });

      test('another repository over the database sees the move on the '
          'emission that drops the local row (#442)', () async {
        final created = await repo.create(name: 'HQ');
        final other = otherTab();
        final seen = await watchAnswers(other, created.household.id);

        await reconcile(created);
        await pumpEventQueue();

        final moved = seen.firstWhere(
          (s) => !s.ids.contains(created.household.id),
        );
        expect(moved.ids, ['hh_server']);
        expect(moved.answer, 'hh_server');
      });

      test('another repository over the database sees the move on the '
          'emission that empties the local roster (#442)', () async {
        // A screen makes the move on whichever of its streams hears of the
        // reconcile first (#306), and in another tab the roster can be
        // first.
        final created = await repo.create(name: 'HQ');
        final other = otherTab();
        final seen = <({int members, String? answer})>[];
        final sub = other
            .watchMembers(created.household.id)
            .listen(
              (members) => seen.add((
                members: members.length,
                answer: other.reconciledHouseholdId(created.household.id),
              )),
            );
        addTearDown(sub.cancel);
        await pumpEventQueue();

        await reconcile(created);
        await pumpEventQueue();

        final emptied = seen.firstWhere((s) => s.members == 0);
        expect(emptied.answer, 'hh_server');
      });

      test('a repository opened after the reconcile answers once its '
          'household stream has emitted (#442)', () async {
        final created = await repo.create(name: 'HQ');
        await reconcile(created);
        final later = otherTab();

        // Nothing read yet: the screen recovers on the first emission.
        expect(later.reconciledHouseholdId(created.household.id), isNull);
        await later.watchHouseholds().first;
        expect(later.reconciledHouseholdId(created.household.id), 'hh_server');
      });

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

      test('disposal waits for a moves read a watch has under way', () async {
        // The suspend path closes the database as soon as disposal returns,
        // and cancelling a watch does not wait for a read it started.
        final reads = _HeldMovesReads();
        // A second database, on its own executor: not the race drift warns
        // of.
        final warned = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
        addTearDown(
          () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = warned,
        );
        final held = ServerDatabase(
          NativeDatabase.memory().interceptWith(reads),
        );
        addTearDown(held.close);
        final heldRepo = HouseholdRepositoryImpl(
          db: held,
          currentUserId: () => _kUserId,
          syncQueue: SyncQueueRepositoryImpl(held, clock, userId: _kUserId),
          clock: clock,
        );
        final sub = heldRepo.watchHouseholds().listen((_) {});
        addTearDown(sub.cancel);
        await reads.started;

        var disposed = false;
        final disposing = heldRepo.onDispose().then((_) => disposed = true);
        await pumpEventQueue();
        expect(disposed, isFalse);

        reads.release();
        await disposing;
      });

      test('records nothing when the reconcile rolls back', () async {
        final created = await repo.create(name: 'HQ');
        // The session scope popping between send and reconcile: completing
        // the queue entry throws inside the transaction.
        await syncQueue.onDispose();

        await expectLater(reconcile(created), throwsStateError);

        expect(repo.reconciledHouseholdId(created.household.id), isNull);
        expect(await rawHousehold(created.household.id), isNotNull);
        // Nor does the database: another repository reads no move.
        final other = otherTab();
        await other.watchHouseholds().first;
        expect(other.reconciledHouseholdId(created.household.id), isNull);
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

/// Holds every `household_moves` read until [release], so a test can act
/// while one is under way.
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
    if (statement.contains('household_moves')) {
      if (!_started.isCompleted) _started.complete();
      await _released.future;
    }
    return executor.runSelect(statement, args);
  }
}
