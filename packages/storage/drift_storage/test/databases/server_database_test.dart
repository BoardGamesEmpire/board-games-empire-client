// Narrow drift import to `show Value`: drift's full export surface
// includes an `isNull` symbol (query-builder utility) that collides
// with matcher's `isNull` from flutter_test. Showing only `Value`
// keeps the companion-construction helper available while leaving
// matcher's `isNull` unambiguous.
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:drift_storage/src/databases/server_database.dart';

// ── Matchers ────────────────────────────────────────────────────────────────────

// Match against the underlying SqliteException's message text rather
// than its type so we don't need to import package:sqlite3 (which is a
// transitive dep of drift, not a direct dep of drift_storage).
final _isFkViolation = throwsA(
  predicate<Object>(
    (e) => e.toString().contains('FOREIGN KEY constraint failed'),
    'an FK constraint violation',
  ),
);

final _isUniqueViolation = throwsA(
  predicate<Object>(
    (e) => e.toString().contains('UNIQUE constraint failed'),
    'a UNIQUE constraint violation',
  ),
);

// ── Fixtures ───────────────────────────────────────────────────────────────────

const _kUserId = 'user-1';
const _kPlatformGameId = 'pg-1';

Future<void> _seedGame(ServerDatabase db, {String id = 'game-1'}) async {
  final now = DateTime.now().toUtc();
  // Upsert so repeat seeds in the same test don't trip the games PK.
  await db
      .into(db.gamesTable)
      .insertOnConflictUpdate(
        GamesTableCompanion.insert(
          id: id,
          title: 'Test Game',
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<void> _seedPlatformGame(
  ServerDatabase db, {
  String id = _kPlatformGameId,
}) async {
  await _seedGame(db);
  final now = DateTime.now().toUtc();
  await db
      .into(db.platformGamesTable)
      .insert(
        PlatformGamesTableCompanion.insert(
          id: id,
          gameId: 'game-1',
          platformId: 'plat-1',
          platformName: 'Tabletop',
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<void> _seedHousehold(ServerDatabase db, {String id = 'h-1'}) async {
  final now = DateTime.now().toUtc();
  await db
      .into(db.householdsTable)
      .insert(
        HouseholdsTableCompanion.insert(
          id: id,
          name: 'Test Household',
          createdAt: now,
          updatedAt: now,
        ),
      );
}

GameCollectionsTableCompanion _collection({
  required String id,
  String userId = _kUserId,
  String platformGameId = _kPlatformGameId,
  String medium = 'Physical',
  DateTime? deletedAt,
  String? releaseId,
  int quantity = 1,
}) {
  final now = DateTime.now().toUtc();
  return GameCollectionsTableCompanion.insert(
    id: id,
    userId: userId,
    platformGameId: platformGameId,
    medium: medium,
    quantity: Value(quantity),
    deletedAt: Value(deletedAt),
    releaseId: Value(releaseId),
    createdAt: now,
    updatedAt: now,
  );
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late ServerDatabase db;

  setUp(() {
    db = ServerDatabase.memory();
  });

  tearDown(() async => db.close());

  group('ServerDatabase', () {
    test('reports schemaVersion 1', () {
      expect(db.schemaVersion, equals(1));
    });

    group('PRAGMA foreign_keys', () {
      test('is enabled (pragma reads back as 1)', () async {
        final row = await db.customSelect('PRAGMA foreign_keys').getSingle();
        expect(row.data['foreign_keys'], equals(1));
      });

      test('rejects insert with non-existent household_id', () async {
        // household_members.household_id references households.id.
        // Without PRAGMA foreign_keys=ON this insert would silently
        // succeed; with FK enforcement it throws.
        final now = DateTime.now().toUtc();
        await expectLater(
          () => db
              .into(db.householdMembersTable)
              .insert(
                HouseholdMembersTableCompanion.insert(
                  id: 'hm-1',
                  userId: _kUserId,
                  householdId: 'nonexistent-household',
                  createdAt: now,
                  updatedAt: now,
                ),
              ),
          _isFkViolation,
        );
      });

      test('rejects insert with non-existent platform_game_id', () async {
        final now = DateTime.now().toUtc();
        await expectLater(
          () => db
              .into(db.gameCollectionsTable)
              .insert(
                GameCollectionsTableCompanion.insert(
                  id: 'col-1',
                  userId: _kUserId,
                  platformGameId: 'nonexistent-pg',
                  medium: 'Physical',
                  createdAt: now,
                  updatedAt: now,
                ),
              ),
          _isFkViolation,
        );
      });
    });

    group('DateTime storage format', () {
      // Regression guard for the UTC-flag loss that broke
      // game_collection_repository_impl_test's resurrection spec on
      // non-UTC machines: drift's default unix-timestamp DateTime
      // storage always reads values back as LOCAL DateTimes, and Dart's
      // `DateTime ==` compares the `isUtc` flag as well as the instant,
      // so a stored `DateTime.utc(...)` never compares equal to its
      // round-tripped self. `store_date_time_values_as_text: true`
      // (build.yaml) switches to ISO-8601 text storage, which preserves
      // the UTC marker. See
      // https://drift.simonbinder.eu/guides/datetime-migrations.
      test('UTC DateTime round-trips with isUtc preserved', () async {
        await _seedPlatformGame(db);
        final ts = DateTime.utc(2025, 6, 1);
        await db
            .into(db.gameCollectionsTable)
            .insert(_collection(id: 'col-1', deletedAt: ts));
        final row = await db.select(db.gameCollectionsTable).getSingle();
        expect(row.deletedAt!.isUtc, isTrue);
        // Full equality — instant AND zone flag — with no defensive
        // `.toUtc()` on the read side.
        expect(row.deletedAt, equals(ts));
      });

      test('datetime columns are stored as ISO-8601 text', () async {
        await _seedPlatformGame(db);
        await db
            .into(db.gameCollectionsTable)
            .insert(
              _collection(id: 'col-1', deletedAt: DateTime.utc(2025, 6, 1)),
            );
        final row = await db
            .customSelect(
              'SELECT typeof(deleted_at) AS t, deleted_at AS v '
              'FROM game_collections',
            )
            .getSingle();
        expect(row.read<String>('t'), equals('text'));
        // Exact serialisation (millisecond rendering etc.) is drift's
        // business; the contract worth pinning is ISO-8601 with the
        // UTC marker.
        final stored = row.read<String>('v');
        expect(stored, startsWith('2025-06-01T00:00:00'));
        expect(stored, endsWith('Z'));
      });
    });

    group('game_collections.deletedAt column', () {
      test('stores and reads back nullable DateTime', () async {
        await _seedPlatformGame(db);
        final ts = DateTime.parse('2024-01-15T10:30:00Z');
        await db
            .into(db.gameCollectionsTable)
            .insert(_collection(id: 'col-1', deletedAt: ts));
        final row = await db.select(db.gameCollectionsTable).getSingle();
        expect(row.deletedAt?.toUtc(), equals(ts));
      });

      test('defaults to null when omitted', () async {
        await _seedPlatformGame(db);
        await db.into(db.gameCollectionsTable).insert(_collection(id: 'col-1'));
        final row = await db.select(db.gameCollectionsTable).getSingle();
        expect(row.deletedAt, isNull);
      });
    });

    group('game_collections.releaseId column', () {
      test('stores and reads back nullable text', () async {
        await _seedPlatformGame(db);
        await db
            .into(db.gameCollectionsTable)
            .insert(_collection(id: 'col-1', releaseId: 'rel-42'));
        final row = await db.select(db.gameCollectionsTable).getSingle();
        expect(row.releaseId, equals('rel-42'));
      });

      test('defaults to null when omitted', () async {
        await _seedPlatformGame(db);
        await db.into(db.gameCollectionsTable).insert(_collection(id: 'col-1'));
        final row = await db.select(db.gameCollectionsTable).getSingle();
        expect(row.releaseId, isNull);
      });
    });

    group('partial unique index on game_collections', () {
      setUp(() async {
        await _seedPlatformGame(db);
      });

      test('rejects a second live row with same (user, pg, medium)', () async {
        await db.into(db.gameCollectionsTable).insert(_collection(id: 'col-1'));

        await expectLater(
          () =>
              db.into(db.gameCollectionsTable).insert(_collection(id: 'col-2')),
          _isUniqueViolation,
        );
      });

      test(
        'permits a new live row when the existing one is tombstoned',
        () async {
          final tombstone = DateTime.now().toUtc();
          await db
              .into(db.gameCollectionsTable)
              .insert(_collection(id: 'col-1', deletedAt: tombstone));

          await db
              .into(db.gameCollectionsTable)
              .insert(_collection(id: 'col-2'));

          final rows = await db.select(db.gameCollectionsTable).get();
          expect(rows, hasLength(2));
        },
      );

      test('permits multiple tombstoned rows with the same triplet', () async {
        final t1 = DateTime.parse('2024-01-15T10:30:00Z');
        final t2 = DateTime.parse('2024-01-16T10:30:00Z');

        await db
            .into(db.gameCollectionsTable)
            .insert(_collection(id: 'col-1', deletedAt: t1));
        await db
            .into(db.gameCollectionsTable)
            .insert(_collection(id: 'col-2', deletedAt: t2));

        final rows = await db.select(db.gameCollectionsTable).get();
        expect(rows, hasLength(2));
      });

      test('permits different medium for same (user, pg)', () async {
        await db
            .into(db.gameCollectionsTable)
            .insert(_collection(id: 'col-1', medium: 'Physical'));
        await db
            .into(db.gameCollectionsTable)
            .insert(_collection(id: 'col-2', medium: 'Digital'));

        final rows = await db.select(db.gameCollectionsTable).get();
        expect(rows, hasLength(2));
      });

      test('permits different users for same (pg, medium)', () async {
        await db
            .into(db.gameCollectionsTable)
            .insert(_collection(id: 'col-1', userId: 'user-a'));
        await db
            .into(db.gameCollectionsTable)
            .insert(_collection(id: 'col-2', userId: 'user-b'));

        final rows = await db.select(db.gameCollectionsTable).get();
        expect(rows, hasLength(2));
      });
    });

    group('household_members_household_user_unique_idx', () {
      test('rejects duplicate (household_id, user_id) memberships', () async {
        await _seedHousehold(db);

        final now = DateTime.now().toUtc();
        await db
            .into(db.householdMembersTable)
            .insert(
              HouseholdMembersTableCompanion.insert(
                id: 'hm-1',
                userId: _kUserId,
                householdId: 'h-1',
                createdAt: now,
                updatedAt: now,
              ),
            );

        await expectLater(
          () => db
              .into(db.householdMembersTable)
              .insert(
                HouseholdMembersTableCompanion.insert(
                  id: 'hm-2',
                  userId: _kUserId,
                  householdId: 'h-1',
                  createdAt: now,
                  updatedAt: now,
                ),
              ),
          _isUniqueViolation,
        );
      });

      test('permits the same user in different households', () async {
        await _seedHousehold(db, id: 'h-1');
        await _seedHousehold(db, id: 'h-2');

        final now = DateTime.now().toUtc();
        await db
            .into(db.householdMembersTable)
            .insert(
              HouseholdMembersTableCompanion.insert(
                id: 'hm-1',
                userId: _kUserId,
                householdId: 'h-1',
                createdAt: now,
                updatedAt: now,
              ),
            );
        await db
            .into(db.householdMembersTable)
            .insert(
              HouseholdMembersTableCompanion.insert(
                id: 'hm-2',
                userId: _kUserId,
                householdId: 'h-2',
                createdAt: now,
                updatedAt: now,
              ),
            );

        final rows = await db.select(db.householdMembersTable).get();
        expect(rows, hasLength(2));
      });
    });
  });
}
