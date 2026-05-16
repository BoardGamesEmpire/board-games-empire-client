import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/household_repository_impl.dart';

// ── Fixtures ────────────────────────────────────────────────────────────────────

const _kUserId = 'user-abc';
const _kOtherUserId = 'user-other';

Future<void> _seedHousehold(
  ServerDatabase db, {
  required String id,
  String name = 'Test Household',
  DateTime? deletedAt,
}) async {
  final now = DateTime.now().toUtc();
  await db
      .into(db.householdsTable)
      .insert(
        HouseholdsTableCompanion.insert(
          id: id,
          name: name,
          deletedAt: Value(deletedAt),
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
  String? roleName,
}) async {
  final now = DateTime.now().toUtc();
  await db
      .into(db.householdMembersTable)
      .insert(
        HouseholdMembersTableCompanion.insert(
          id: id,
          userId: userId,
          householdId: householdId,
          roleName: Value(roleName),
          createdAt: now,
          updatedAt: now,
        ),
      );
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late ServerDatabase db;
  late HouseholdRepositoryImpl repo;

  setUp(() {
    db = ServerDatabase.memory();
    repo = HouseholdRepositoryImpl(db: db, currentUserId: _kUserId);
  });

  tearDown(() async => db.close());

  group('HouseholdRepositoryImpl', () {
    group('getHouseholds()', () {
      test(
        'returns only households the current user is a member of',
        () async {
          await _seedHousehold(db, id: 'h-1', name: 'Mine');
          await _seedHousehold(db, id: 'h-2', name: 'Not Mine');
          await _seedMember(
            db,
            id: 'm-1',
            userId: _kUserId,
            householdId: 'h-1',
          );
          await _seedMember(
            db,
            id: 'm-2',
            userId: _kOtherUserId,
            householdId: 'h-2',
          );

          final households = await repo.getHouseholds();
          expect(households, hasLength(1));
          expect(households.single.id, equals('h-1'));
        },
      );

      test('excludes tombstoned households', () async {
        final now = DateTime.now().toUtc();
        await _seedHousehold(
          db,
          id: 'h-1',
          name: 'Mine (deleted)',
          deletedAt: now,
        );
        await _seedMember(
          db,
          id: 'm-1',
          userId: _kUserId,
          householdId: 'h-1',
        );

        expect(await repo.getHouseholds(), isEmpty);
      });

      test(
        'returns empty when user is not a member of any household',
        () async {
          await _seedHousehold(db, id: 'h-1');
          // No membership for _kUserId.
          expect(await repo.getHouseholds(), isEmpty);
        },
      );
    });

    group('getHousehold()', () {
      test('returns the household when the user is a member', () async {
        await _seedHousehold(db, id: 'h-1', name: 'Mine');
        await _seedMember(
          db,
          id: 'm-1',
          userId: _kUserId,
          householdId: 'h-1',
        );

        final h = await repo.getHousehold('h-1');
        expect(h, isNotNull);
        expect(h!.name, equals('Mine'));
      });

      test('returns null when the user is not a member', () async {
        await _seedHousehold(db, id: 'h-1');
        await _seedMember(
          db,
          id: 'm-1',
          userId: _kOtherUserId,
          householdId: 'h-1',
        );

        expect(await repo.getHousehold('h-1'), isNull);
      });

      test('returns null when the household does not exist', () async {
        expect(await repo.getHousehold('nonexistent'), isNull);
      });
    });

    group('getMembers()', () {
      test('returns all members of a household (no user filter)', () async {
        await _seedHousehold(db, id: 'h-1');
        await _seedMember(
          db,
          id: 'm-1',
          userId: _kUserId,
          householdId: 'h-1',
          roleName: 'HouseholdOwner',
        );
        await _seedMember(
          db,
          id: 'm-2',
          userId: _kOtherUserId,
          householdId: 'h-1',
          roleName: 'HouseholdMember',
        );

        final members = await repo.getMembers('h-1');
        expect(members, hasLength(2));
      });
    });

    group('getCurrentUserMember()', () {
      test(
        'returns the member record for the current user in the household',
        () async {
          await _seedHousehold(db, id: 'h-1');
          await _seedMember(
            db,
            id: 'm-1',
            userId: _kUserId,
            householdId: 'h-1',
            roleName: 'HouseholdOwner',
          );
          await _seedMember(
            db,
            id: 'm-2',
            userId: _kOtherUserId,
            householdId: 'h-1',
            roleName: 'HouseholdMember',
          );

          final me = await repo.getCurrentUserMember('h-1');
          expect(me, isNotNull);
          expect(me!.id, equals('m-1'));
          expect(me.userId, equals(_kUserId));
          expect(me.role, equals(HouseholdRole.householdOwner));
        },
      );

      test('returns null when the user is not a member', () async {
        await _seedHousehold(db, id: 'h-1');
        await _seedMember(
          db,
          id: 'm-other',
          userId: _kOtherUserId,
          householdId: 'h-1',
        );

        expect(await repo.getCurrentUserMember('h-1'), isNull);
      });

      test('returns null when the household does not exist', () async {
        expect(await repo.getCurrentUserMember('nonexistent'), isNull);
      });
    });

    group('cacheHousehold()', () {
      test('upserts a household', () async {
        final now = DateTime.now().toUtc();
        final h = Household(
          id: 'h-1',
          name: 'Cached',
          createdAt: now,
          updatedAt: now,
        );

        await repo.cacheHousehold(h);

        // Make the user a member so getHousehold can see it through
        // the inner-join filter.
        await _seedMember(
          db,
          id: 'm-1',
          userId: _kUserId,
          householdId: 'h-1',
        );

        final retrieved = await repo.getHousehold('h-1');
        expect(retrieved, isNotNull);
        expect(retrieved!.name, equals('Cached'));
      });
    });

    group('watchHouseholds()', () {
      test('emits only households the user is a member of', () async {
        await _seedHousehold(db, id: 'h-1');
        await _seedHousehold(db, id: 'h-2');
        await _seedMember(
          db,
          id: 'm-1',
          userId: _kUserId,
          householdId: 'h-1',
        );
        await _seedMember(
          db,
          id: 'm-2',
          userId: _kOtherUserId,
          householdId: 'h-2',
        );

        await expectLater(
          repo.watchHouseholds().take(1),
          emits(hasLength(1)),
        );
      });

      test('excludes tombstoned households', () async {
        final now = DateTime.now().toUtc();
        await _seedHousehold(db, id: 'h-1', deletedAt: now);
        await _seedMember(
          db,
          id: 'm-1',
          userId: _kUserId,
          householdId: 'h-1',
        );

        await expectLater(repo.watchHouseholds().take(1), emits(isEmpty));
      });
    });
  });
}
