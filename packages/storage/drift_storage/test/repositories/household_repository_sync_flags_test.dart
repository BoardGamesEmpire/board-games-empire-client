import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/household_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/fixed_clock.dart';

// Coverage for the isDirty / isLocalOnly columns added to the households
// table. The broad read-gate / membership behaviour lives in
// household_repository_impl_test.dart; the create / reconcile write path in
// household_repository_impl_create_test.dart. This file only pins the
// sync-flag round-trip through the mapper and the cache writer.

const _kUserId = 'user-abc';

Future<void> _seedHousehold(
  ServerDatabase db, {
  required String id,
  String name = 'Test Household',
  bool isDirty = false,
  bool isLocalOnly = false,
}) async {
  final now = DateTime.now().toUtc();
  await db
      .into(db.householdsTable)
      .insert(
        HouseholdsTableCompanion.insert(
          id: id,
          name: name,
          isDirty: Value(isDirty),
          isLocalOnly: Value(isLocalOnly),
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<void> _seedMember(
  ServerDatabase db, {
  required String id,
  required String userId,
  required String householdId,
}) async {
  final now = DateTime.now().toUtc();
  await db
      .into(db.householdMembersTable)
      .insert(
        HouseholdMembersTableCompanion.insert(
          id: id,
          userId: userId,
          householdId: householdId,
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<HouseholdsTableData> _rawRow(ServerDatabase db, String id) =>
    (db.select(db.householdsTable)..where((t) => t.id.equals(id))).getSingle();

void main() {
  late ServerDatabase db;
  late HouseholdRepositoryImpl repo;

  setUp(() {
    db = ServerDatabase.memory();
    final clock = FixedClockService(DateTime.utc(2024, 1, 15, 10, 30));
    repo = HouseholdRepositoryImpl(
      db: db,
      currentUserId: () => _kUserId,
      syncQueue: SyncQueueRepositoryImpl(db, clock),
      clock: clock,
    );
  });

  tearDown(() async => db.close());

  group('household sync flags', () {
    test('default to false for a plain row', () async {
      await _seedHousehold(db, id: 'h-1');
      await _seedMember(db, id: 'm-1', userId: _kUserId, householdId: 'h-1');

      final h = await repo.getHousehold('h-1');
      expect(h, isNotNull);
      expect(h!.isDirty, isFalse);
      expect(h.isLocalOnly, isFalse);
    });

    test('getHousehold maps isDirty / isLocalOnly from the row', () async {
      await _seedHousehold(db, id: 'h-1', isDirty: true, isLocalOnly: true);
      await _seedMember(db, id: 'm-1', userId: _kUserId, householdId: 'h-1');

      final h = await repo.getHousehold('h-1');
      expect(h!.isDirty, isTrue);
      expect(h.isLocalOnly, isTrue);
    });

    test('getHouseholds maps the flags for each row', () async {
      await _seedHousehold(db, id: 'h-1', isLocalOnly: true);
      await _seedMember(db, id: 'm-1', userId: _kUserId, householdId: 'h-1');

      final list = await repo.getHouseholds();
      expect(list, hasLength(1));
      expect(list.single.isLocalOnly, isTrue);
      expect(list.single.isDirty, isFalse);
    });

    test('cacheHousehold persists the flags to the row', () async {
      final now = DateTime.now().toUtc();
      await repo.cacheHousehold(
        Household(
          id: 'h-1',
          name: 'Cached',
          isDirty: true,
          isLocalOnly: true,
          createdAt: now,
          updatedAt: now,
        ),
      );

      final row = await _rawRow(db, 'h-1');
      expect(row.isDirty, isTrue);
      expect(row.isLocalOnly, isTrue);
    });

    test(
      'cacheHousehold defaults flags to false for a server-shaped row',
      () async {
        final now = DateTime.now().toUtc();
        await repo.cacheHousehold(
          Household(id: 'h-1', name: 'Server', createdAt: now, updatedAt: now),
        );

        final row = await _rawRow(db, 'h-1');
        expect(row.isDirty, isFalse);
        expect(row.isLocalOnly, isFalse);
      },
    );

    test(
      'cacheHousehold upsert can clear a previously local-only row',
      () async {
        final now = DateTime.now().toUtc();
        await repo.cacheHousehold(
          Household(
            id: 'h-1',
            name: 'Optimistic',
            isLocalOnly: true,
            isDirty: true,
            createdAt: now,
            updatedAt: now,
          ),
        );
        // Server confirmation re-caches the same id with flags cleared.
        await repo.cacheHousehold(
          Household(
            id: 'h-1',
            name: 'Confirmed',
            createdAt: now,
            updatedAt: now,
          ),
        );

        final row = await _rawRow(db, 'h-1');
        expect(row.name, equals('Confirmed'));
        expect(row.isDirty, isFalse);
        expect(row.isLocalOnly, isFalse);
      },
    );
  });
}
