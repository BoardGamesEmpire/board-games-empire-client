import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/household_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/fixed_clock.dart';

// Coverage for the isDirty / isLocalOnly columns added to the households
// table. The broad read-gate / membership behaviour lives in
// household_repository_impl_test.dart; the create / reconcile write path in
// household_repository_impl_create_test.dart. This file only pins the
// sync-flag round-trip through the mapper, the cache writer and the
// reconcile that acknowledges a create.

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
    db = inMemoryServerDatabase();
    final clock = FixedClockService(DateTime.utc(2024, 1, 15, 10, 30));
    repo = HouseholdRepositoryImpl(
      db: db,
      currentUserId: () => _kUserId,
      syncQueue: SyncQueueRepositoryImpl(db, clock, userId: _kUserId),
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

    test('cacheHousehold writes a server row clean, whatever flags the payload '
        'carries', () async {
      // A server write cannot create local sync state: a row it marked
      // dirty or local-only would be one no later server write could refresh and no
      // acknowledgement would ever clear.
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
      expect(row.isDirty, isFalse);
      expect(row.isLocalOnly, isFalse);
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

    // A dirty or local-only row belongs to the sync queue until the server
    // acknowledges it (#298). A server write that lands first — a hydrate — must leave
    // both its flags and its values alone, or the list's pending badge
    // disappears and the displayed values revert before the queued
    // operation is even sent.
    test('cacheHousehold leaves a local-only row untouched', () async {
      final created = await repo.create(name: 'Optimistic');
      final before = await _rawRow(db, created.household.id);
      final now = DateTime.now().toUtc();

      await repo.cacheHousehold(
        Household(
          id: created.household.id,
          name: 'Server',
          createdAt: now,
          updatedAt: now,
        ),
      );

      expect(await _rawRow(db, created.household.id), equals(before));
    });

    test('cacheHousehold leaves a dirty row untouched', () async {
      await _seedHousehold(db, id: 'h-1', name: 'Edited', isDirty: true);
      await _seedMember(db, id: 'm-1', userId: _kUserId, householdId: 'h-1');
      final before = await _rawRow(db, 'h-1');
      final now = DateTime.now().toUtc();

      await repo.cacheHousehold(
        Household(id: 'h-1', name: 'Server', createdAt: now, updatedAt: now),
      );

      expect(await _rawRow(db, 'h-1'), equals(before));
    });

    test('cacheHousehold skips a server tombstone over a dirty row', () async {
      // The queued operation settles it when it drains.
      await _seedHousehold(db, id: 'h-1', name: 'Edited', isDirty: true);
      await _seedMember(db, id: 'm-1', userId: _kUserId, householdId: 'h-1');
      final now = DateTime.now().toUtc();

      await repo.cacheHousehold(
        Household(
          id: 'h-1',
          name: 'Edited',
          deletedAt: now,
          createdAt: now,
          updatedAt: now,
        ),
      );

      expect(await repo.getHousehold('h-1'), isNotNull);
    });

    test("the create's reconcile clears a local-only row and takes the "
        "server's values", () async {
      // Only the server's acknowledgement of the create may clear the
      // flags, and it goes through the reconcile, not cacheHousehold.
      final created = await repo.create(name: 'Optimistic');

      await repo.reconcileCreatedHousehold(
        created.household.copyWith(
          name: 'Confirmed',
          isDirty: false,
          isLocalOnly: false,
        ),
        localId: created.household.id,
      );

      final row = await _rawRow(db, created.household.id);
      expect(row.name, equals('Confirmed'));
      expect(row.isDirty, isFalse);
      expect(row.isLocalOnly, isFalse);
    });
  });
}
