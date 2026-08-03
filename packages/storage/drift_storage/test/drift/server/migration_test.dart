import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'generated/schema.dart';

import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;
import 'generated/schema_v3.dart' as v3;

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

  // Data-integrity coverage for v2 → v3 (#147): the step user-scopes the
  // sync queue by dropping and recreating `sync_queue` with the new
  // `user_id TEXT NOT NULL` column and the `(user_id, status, created_at)`
  // index. Two contracts are pinned here, both **deliberate**:
  //
  // 1. **Legacy sync_queue rows are DROPPED.** Pre-v3 rows carry no user
  //    attribution, and backfilling them from whichever session happens to
  //    run the migration would attribute work that may not be theirs —
  //    the exact cross-user hazard #147 exists to close. Destructive for
  //    this table by locked decision (acceptable pre-alpha; no production
  //    DBs exist).
  // 2. **Every other table is untouched.** The step names only
  //    `sync_queue`; households and members (seeded with live data,
  //    exercising the member FK across the migration) must survive
  //    byte-for-byte.
  test('migration from v2 to v3 drops legacy sync_queue rows and preserves '
      'everything else (#147)', () async {
    const householdId = 'hh_v2_1';
    const createdAt = '2024-01-15T10:30:00.000Z';
    const updatedAt = '2024-01-16T09:00:00.000Z';

    final oldHouseholdsData = <v2.HouseholdsData>[
      const v2.HouseholdsData(
        id: householdId,
        name: 'Game Night HQ',
        description: 'Where we play',
        isDirty: 0,
        isLocalOnly: 0,
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    ];
    final expectedNewHouseholdsData = <v3.HouseholdsData>[
      const v3.HouseholdsData(
        id: householdId,
        name: 'Game Night HQ',
        description: 'Where we play',
        isDirty: 0,
        isLocalOnly: 0,
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    ];

    final oldHouseholdMembersData = <v2.HouseholdMembersData>[
      const v2.HouseholdMembersData(
        id: 'hm_v2_1',
        userId: 'user_v2_1',
        householdId: householdId,
        showAllGames: 1,
        roleName: 'HouseholdOwner',
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    ];
    final expectedNewHouseholdMembersData = <v3.HouseholdMembersData>[
      const v3.HouseholdMembersData(
        id: 'hm_v2_1',
        userId: 'user_v2_1',
        householdId: householdId,
        showAllGames: 1,
        roleName: 'HouseholdOwner',
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    ];

    // Two queued rows in different states — both unattributed at v2,
    // both dropped at v3. A pending row is the D8-sensitive case (a
    // departed user's surviving offline write); pinning its removal
    // documents that the pre-alpha destructive default was chosen over
    // a wrong backfill, not overlooked.
    const payload =
        '{"type":"create_household","local_id":"hh_local_1","name":"HQ"}';
    final oldSyncQueueData = <v2.SyncQueueData>[
      const v2.SyncQueueData(
        id: 'sq_v2_pending',
        payload: payload,
        status: 'pending',
        retryCount: 0,
        createdAt: createdAt,
      ),
      const v2.SyncQueueData(
        id: 'sq_v2_completed',
        payload: payload,
        status: 'completed',
        retryCount: 0,
        createdAt: createdAt,
      ),
    ];

    await verifier.testWithDataIntegrity(
      oldVersion: 2,
      newVersion: 3,
      createOld: v2.DatabaseAtV2.new,
      createNew: v3.DatabaseAtV3.new,
      openTestedDatabase: ServerDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.households, oldHouseholdsData);
        batch.insertAll(oldDb.householdMembers, oldHouseholdMembersData);
        batch.insertAll(oldDb.syncQueue, oldSyncQueueData);
      },
      validateItems: (newDb) async {
        expect(
          expectedNewHouseholdsData,
          await newDb.select(newDb.households).get(),
        );
        expect(
          expectedNewHouseholdMembersData,
          await newDb.select(newDb.householdMembers).get(),
        );
        // The locked #147 contract: legacy rows are gone, not carried.
        expect(await newDb.select(newDb.syncQueue).get(), isEmpty);
      },
    );
  });
}
