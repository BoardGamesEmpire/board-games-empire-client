import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'generated/schema.dart';

import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = ServerDatabase(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  // Data-integrity coverage for v1 → v2 (#39): the step adds
  // `households.is_dirty` and `households.is_local_only` via `addColumn`.
  // Both are `BOOLEAN NOT NULL DEFAULT 0`, so the migration must preserve
  // every pre-existing row and back-fill the two new columns with `false`
  // (`0`) rather than dropping or rebuilding the table.
  //
  // Seeded rows are deliberately minimal but representative of the tables the
  // household create path touches: a household, its owner member (exercising
  // the `household_members.household_id` foreign key across the migration),
  // and a queued sync operation. `games` / `platform_games` /
  // `game_collections` are untouched by this step and stay empty.
  //
  // Timestamps are opaque strings here: `store_date_time_values_as_text: true`
  // means Drift persists them as text, and this step neither reads nor
  // rewrites them — they must survive byte-for-byte.
  test('migration from v1 to v2 does not corrupt data', () async {
    const householdId = 'hh_v1_1';
    const deletedHouseholdId = 'hh_v1_deleted';
    const createdAt = '2024-01-15T10:30:00.000Z';
    const updatedAt = '2024-01-16T09:00:00.000Z';
    const deletedAt = '2024-01-17T12:00:00.000Z';

    final oldGamesData = <v1.GamesData>[];
    final expectedNewGamesData = <v2.GamesData>[];

    final oldPlatformGamesData = <v1.PlatformGamesData>[];
    final expectedNewPlatformGamesData = <v2.PlatformGamesData>[];

    final oldGameCollectionsData = <v1.GameCollectionsData>[];
    final expectedNewGameCollectionsData = <v2.GameCollectionsData>[];

    // A live household and a tombstoned one, so the nullable `deleted_at`
    // column is covered in both states.
    final oldHouseholdsData = <v1.HouseholdsData>[
      const v1.HouseholdsData(
        id: householdId,
        name: 'Game Night HQ',
        description: 'Where we play',
        image: 'hq.png',
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
      const v1.HouseholdsData(
        id: deletedHouseholdId,
        name: 'Old Household',
        deletedAt: deletedAt,
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    ];
    // Same rows, with the two new flags back-filled to false (0).
    final expectedNewHouseholdsData = <v2.HouseholdsData>[
      const v2.HouseholdsData(
        id: householdId,
        name: 'Game Night HQ',
        description: 'Where we play',
        image: 'hq.png',
        isDirty: 0,
        isLocalOnly: 0,
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
      const v2.HouseholdsData(
        id: deletedHouseholdId,
        name: 'Old Household',
        isDirty: 0,
        isLocalOnly: 0,
        deletedAt: deletedAt,
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    ];

    // Owner member of the live household: its FK must still resolve after the
    // parent table is altered.
    final oldHouseholdMembersData = <v1.HouseholdMembersData>[
      const v1.HouseholdMembersData(
        id: 'hm_v1_1',
        userId: 'user_v1_1',
        householdId: householdId,
        showAllGames: 1,
        roleName: 'HouseholdOwner',
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    ];
    final expectedNewHouseholdMembersData = <v2.HouseholdMembersData>[
      const v2.HouseholdMembersData(
        id: 'hm_v1_1',
        userId: 'user_v1_1',
        householdId: householdId,
        showAllGames: 1,
        roleName: 'HouseholdOwner',
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    ];

    // A pending queued operation, so an un-drained queue is proven to survive
    // the upgrade (there is no drain worker yet — see #121). The payload is
    // the real `CreateHouseholdOperation.toJson()` shape: snake_case `type`
    // discriminator matching `CreateHouseholdOperation.type`, `local_id` for
    // the client-side cuid2, and optional fields omitted when null.
    const payload =
        '{"type":"create_household","local_id":"hh_local_1","name":"HQ"}';
    final oldSyncQueueData = <v1.SyncQueueData>[
      const v1.SyncQueueData(
        id: 'sq_v1_1',
        payload: payload,
        status: 'pending',
        retryCount: 0,
        createdAt: createdAt,
      ),
    ];
    final expectedNewSyncQueueData = <v2.SyncQueueData>[
      const v2.SyncQueueData(
        id: 'sq_v1_1',
        payload: payload,
        status: 'pending',
        retryCount: 0,
        createdAt: createdAt,
      ),
    ];

    await verifier.testWithDataIntegrity(
      oldVersion: 1,
      newVersion: 2,
      createOld: v1.DatabaseAtV1.new,
      createNew: v2.DatabaseAtV2.new,
      openTestedDatabase: ServerDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.games, oldGamesData);
        batch.insertAll(oldDb.platformGames, oldPlatformGamesData);
        batch.insertAll(oldDb.gameCollections, oldGameCollectionsData);
        batch.insertAll(oldDb.households, oldHouseholdsData);
        batch.insertAll(oldDb.householdMembers, oldHouseholdMembersData);
        batch.insertAll(oldDb.syncQueue, oldSyncQueueData);
      },
      validateItems: (newDb) async {
        expect(expectedNewGamesData, await newDb.select(newDb.games).get());
        expect(
          expectedNewPlatformGamesData,
          await newDb.select(newDb.platformGames).get(),
        );
        expect(
          expectedNewGameCollectionsData,
          await newDb.select(newDb.gameCollections).get(),
        );
        expect(
          expectedNewHouseholdsData,
          await newDb.select(newDb.households).get(),
        );
        expect(
          expectedNewHouseholdMembersData,
          await newDb.select(newDb.householdMembers).get(),
        );
        expect(
          expectedNewSyncQueueData,
          await newDb.select(newDb.syncQueue).get(),
        );
      },
    );
  });
}
