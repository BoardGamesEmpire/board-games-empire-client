import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generated/schema.dart';

import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;
import 'generated/schema_v3.dart' as v3;
import 'generated/schema_v4.dart' as v4;
import 'generated/schema_v5.dart' as v5;
import 'generated/schema_v6.dart' as v6;
import 'generated/schema_v7.dart' as v7;
import 'generated/schema_v8.dart' as v8;
import 'generated/schema_v9.dart' as v9;

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

  // Data-integrity coverage for v3 → v4 (#442): the step only creates
  // `household_moves`. Every existing table must survive byte-for-byte —
  // households and members seeded with live data (the member FK crossing the
  // migration) and a queued row, which unlike v2 → v3 is carried, not
  // dropped — and the new table starts empty.
  test('migration from v3 to v4 adds an empty household_moves and preserves '
      'everything else (#442)', () async {
    const householdId = 'hh_v3_1';
    const createdAt = '2024-01-15T10:30:00.000Z';
    const updatedAt = '2024-01-16T09:00:00.000Z';
    const payload =
        '{"type":"create_household","local_id":"hh_local_1","name":"HQ"}';

    final oldHouseholdsData = <v3.HouseholdsData>[
      const v3.HouseholdsData(
        id: householdId,
        name: 'Game Night HQ',
        isDirty: 0,
        isLocalOnly: 0,
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    ];
    final expectedNewHouseholdsData = <v4.HouseholdsData>[
      const v4.HouseholdsData(
        id: householdId,
        name: 'Game Night HQ',
        isDirty: 0,
        isLocalOnly: 0,
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    ];

    final oldHouseholdMembersData = <v3.HouseholdMembersData>[
      const v3.HouseholdMembersData(
        id: 'hm_v3_1',
        userId: 'user_v3_1',
        householdId: householdId,
        showAllGames: 1,
        roleName: 'HouseholdOwner',
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    ];
    final expectedNewHouseholdMembersData = <v4.HouseholdMembersData>[
      const v4.HouseholdMembersData(
        id: 'hm_v3_1',
        userId: 'user_v3_1',
        householdId: householdId,
        showAllGames: 1,
        roleName: 'HouseholdOwner',
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    ];

    final oldSyncQueueData = <v3.SyncQueueData>[
      const v3.SyncQueueData(
        id: 'sq_v3_1',
        userId: 'user_v3_1',
        payload: payload,
        status: 'pending',
        retryCount: 0,
        createdAt: createdAt,
      ),
    ];
    final expectedNewSyncQueueData = <v4.SyncQueueData>[
      const v4.SyncQueueData(
        id: 'sq_v3_1',
        userId: 'user_v3_1',
        payload: payload,
        status: 'pending',
        retryCount: 0,
        createdAt: createdAt,
      ),
    ];

    await verifier.testWithDataIntegrity(
      oldVersion: 3,
      newVersion: 4,
      createOld: v3.DatabaseAtV3.new,
      createNew: v4.DatabaseAtV4.new,
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
        expect(
          expectedNewSyncQueueData,
          await newDb.select(newDb.syncQueue).get(),
        );
        expect(await newDb.select(newDb.householdMoves).get(), isEmpty);
      },
    );
  });

  // Data-integrity coverage for v4 → v5 (#142): the step only creates
  // `unsent_changes_users`. The queue is what the new table counts, so its
  // rows above all must be carried, not dropped; the new table starts empty,
  // because nothing before it recorded whose session was open.
  test('migration from v4 to v5 adds an empty unsent_changes_users and '
      'carries the queue (#142)', () async {
    const createdAt = '2024-01-15T10:30:00.000Z';
    const payload =
        '{"type":"create_household","local_id":"hh_local_1","name":"HQ"}';

    final oldSyncQueueData = <v4.SyncQueueData>[
      const v4.SyncQueueData(
        id: 'sq_v4_1',
        userId: 'user_v4_1',
        payload: payload,
        status: 'failed',
        retryCount: 3,
        lastError: 'rejected',
        createdAt: createdAt,
      ),
    ];
    final expectedNewSyncQueueData = <v5.SyncQueueData>[
      const v5.SyncQueueData(
        id: 'sq_v4_1',
        userId: 'user_v4_1',
        payload: payload,
        status: 'failed',
        retryCount: 3,
        lastError: 'rejected',
        createdAt: createdAt,
      ),
    ];

    final oldHouseholdMovesData = <v4.HouseholdMovesData>[
      const v4.HouseholdMovesData(localId: 'hh_local_1', serverId: 'hh_1'),
    ];
    final expectedNewHouseholdMovesData = <v5.HouseholdMovesData>[
      const v5.HouseholdMovesData(localId: 'hh_local_1', serverId: 'hh_1'),
    ];

    await verifier.testWithDataIntegrity(
      oldVersion: 4,
      newVersion: 5,
      createOld: v4.DatabaseAtV4.new,
      createNew: v5.DatabaseAtV5.new,
      openTestedDatabase: ServerDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.syncQueue, oldSyncQueueData);
        batch.insertAll(oldDb.householdMoves, oldHouseholdMovesData);
      },
      validateItems: (newDb) async {
        expect(
          expectedNewSyncQueueData,
          await newDb.select(newDb.syncQueue).get(),
        );
        expect(
          expectedNewHouseholdMovesData,
          await newDb.select(newDb.householdMoves).get(),
        );
        expect(await newDb.select(newDb.unsentChangesUsers).get(), isEmpty);
      },
    );
  });

  // Data-integrity coverage for v5 → v6 (#434, #406): the step adds the two
  // access tables and `full_record_cached_at` on `games` and
  // `platform_games`. Every row the cache already holds is carried, and
  // reads as summary-only: the hydrate is the only writer these tables have
  // had. The access tables are backfilled from `game_collections`, live and
  // removed rows alike, so each user keeps exactly the games their own
  // collection brought onto the device.
  test('migration from v5 to v6 records each collection row\'s user for its '
      'game and platform game, and leaves every cached row summary-only '
      '(#434, #406)', () async {
    const at = '2024-01-15T10:30:00.000Z';
    const deletedAt = '2024-01-17T12:00:00.000Z';

    v5.GamesData oldGame(String id) => v5.GamesData(
      id: id,
      title: 'Game $id',
      contentType: 'BaseGame',
      totalPlayCount: 0,
      ownedByCount: 0,
      categoriesJson: '[]',
      mechanicsJson: '[]',
      designersJson: '[]',
      publishersJson: '[]',
      tagsJson: '[]',
      visibility: 'Public',
      createdAt: at,
      updatedAt: at,
    );
    v6.GamesData newGame(String id) => v6.GamesData(
      id: id,
      title: 'Game $id',
      contentType: 'BaseGame',
      totalPlayCount: 0,
      ownedByCount: 0,
      categoriesJson: '[]',
      mechanicsJson: '[]',
      designersJson: '[]',
      publishersJson: '[]',
      tagsJson: '[]',
      visibility: 'Public',
      createdAt: at,
      updatedAt: at,
    );
    v5.PlatformGamesData oldPlatformGame(String id, String gameId) =>
        v5.PlatformGamesData(
          id: id,
          gameId: gameId,
          platformId: 'plat-$id',
          platformName: 'Tabletop',
          supportsSolo: 0,
          supportsLocal: 0,
          supportsOnline: 0,
          hasAsyncPlay: 0,
          hasRealtime: 0,
          hasTutorial: 0,
          createdAt: at,
          updatedAt: at,
        );
    v6.PlatformGamesData newPlatformGame(String id, String gameId) =>
        v6.PlatformGamesData(
          id: id,
          gameId: gameId,
          platformId: 'plat-$id',
          platformName: 'Tabletop',
          supportsSolo: 0,
          supportsLocal: 0,
          supportsOnline: 0,
          hasAsyncPlay: 0,
          hasRealtime: 0,
          hasTutorial: 0,
          createdAt: at,
          updatedAt: at,
        );
    v5.GameCollectionsData oldEntry(
      String id,
      String userId,
      String platformGameId, {
      String medium = 'Physical',
      String? deleted,
    }) => v5.GameCollectionsData(
      id: id,
      userId: userId,
      platformGameId: platformGameId,
      medium: medium,
      quantity: 1,
      isDirty: 0,
      isLocalOnly: 0,
      deletedAt: deleted,
      createdAt: at,
      updatedAt: at,
    );
    v6.GameCollectionsData newEntry(
      String id,
      String userId,
      String platformGameId, {
      String medium = 'Physical',
      String? deleted,
    }) => v6.GameCollectionsData(
      id: id,
      userId: userId,
      platformGameId: platformGameId,
      medium: medium,
      quantity: 1,
      isDirty: 0,
      isLocalOnly: 0,
      deletedAt: deleted,
      createdAt: at,
      updatedAt: at,
    );

    // A owns g-1 on pg-1 in two media, which must record one row each, and
    // removed g-2's pg-3. B owns g-1 on pg-2 only, so B gets g-1 but never
    // pg-1.
    final oldEntries = [
      oldEntry('gc-a1', 'user-a', 'pg-1'),
      oldEntry('gc-a2', 'user-a', 'pg-1', medium: 'Digital'),
      oldEntry('gc-a3', 'user-a', 'pg-3', deleted: deletedAt),
      oldEntry('gc-b1', 'user-b', 'pg-2'),
    ];
    final expectedEntries = [
      newEntry('gc-a1', 'user-a', 'pg-1'),
      newEntry('gc-a2', 'user-a', 'pg-1', medium: 'Digital'),
      newEntry('gc-a3', 'user-a', 'pg-3', deleted: deletedAt),
      newEntry('gc-b1', 'user-b', 'pg-2'),
    ];

    await verifier.testWithDataIntegrity(
      oldVersion: 5,
      newVersion: 6,
      createOld: v5.DatabaseAtV5.new,
      createNew: v6.DatabaseAtV6.new,
      openTestedDatabase: ServerDatabase.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.games, [oldGame('g-1'), oldGame('g-2')]);
        batch.insertAll(oldDb.platformGames, [
          oldPlatformGame('pg-1', 'g-1'),
          oldPlatformGame('pg-2', 'g-1'),
          oldPlatformGame('pg-3', 'g-2'),
        ]);
        batch.insertAll(oldDb.gameCollections, oldEntries);
      },
      validateItems: (newDb) async {
        expect(await newDb.select(newDb.games).get(), [
          newGame('g-1'),
          newGame('g-2'),
        ]);
        expect(await newDb.select(newDb.platformGames).get(), [
          newPlatformGame('pg-1', 'g-1'),
          newPlatformGame('pg-2', 'g-1'),
          newPlatformGame('pg-3', 'g-2'),
        ]);
        expect(
          await newDb.select(newDb.gameCollections).get(),
          expectedEntries,
        );
        expect(
          await newDb.select(newDb.gameAccess).get(),
          unorderedEquals(const [
            v6.GameAccessData(
              userId: 'user-a',
              gameId: 'g-1',
              source: 'collection',
            ),
            v6.GameAccessData(
              userId: 'user-a',
              gameId: 'g-2',
              source: 'collection',
            ),
            v6.GameAccessData(
              userId: 'user-b',
              gameId: 'g-1',
              source: 'collection',
            ),
          ]),
        );
        expect(
          await newDb.select(newDb.platformGameAccess).get(),
          unorderedEquals(const [
            v6.PlatformGameAccessData(
              userId: 'user-a',
              platformGameId: 'pg-1',
              source: 'collection',
            ),
            v6.PlatformGameAccessData(
              userId: 'user-a',
              platformGameId: 'pg-3',
              source: 'collection',
            ),
            v6.PlatformGameAccessData(
              userId: 'user-b',
              platformGameId: 'pg-2',
              source: 'collection',
            ),
          ]),
        );
      },
    );
  });

  // Data-integrity coverage for v6 → v7 (#496): the step only creates the six
  // event tables and their four indexes. A household and a game stand for the
  // rows the cache already holds, which must come through unchanged, and every
  // new table starts empty, because no earlier version cached an event.
  test('migration from v6 to v7 adds empty event tables and preserves '
      'households and games', () async {
    const at = '2024-01-15T10:30:00.000Z';

    await verifier.testWithDataIntegrity(
      oldVersion: 6,
      newVersion: 7,
      createOld: v6.DatabaseAtV6.new,
      createNew: v7.DatabaseAtV7.new,
      openTestedDatabase: ServerDatabase.new,
      createItems: (batch, oldDb) {
        batch.insert(
          oldDb.households,
          const v6.HouseholdsData(
            id: 'hh_v6_1',
            name: 'Game Night HQ',
            description: 'Where we play',
            isDirty: 0,
            isLocalOnly: 0,
            createdAt: at,
            updatedAt: at,
          ),
        );
        batch.insert(
          oldDb.games,
          const v6.GamesData(
            id: 'g-1',
            title: 'Game g-1',
            contentType: 'BaseGame',
            totalPlayCount: 0,
            ownedByCount: 0,
            categoriesJson: '[]',
            mechanicsJson: '[]',
            designersJson: '[]',
            publishersJson: '[]',
            tagsJson: '[]',
            visibility: 'Public',
            createdAt: at,
            updatedAt: at,
          ),
        );
      },
      validateItems: (newDb) async {
        expect(await newDb.select(newDb.households).get(), const [
          v7.HouseholdsData(
            id: 'hh_v6_1',
            name: 'Game Night HQ',
            description: 'Where we play',
            isDirty: 0,
            isLocalOnly: 0,
            createdAt: at,
            updatedAt: at,
          ),
        ]);
        expect(await newDb.select(newDb.games).get(), const [
          v7.GamesData(
            id: 'g-1',
            title: 'Game g-1',
            contentType: 'BaseGame',
            totalPlayCount: 0,
            ownedByCount: 0,
            categoriesJson: '[]',
            mechanicsJson: '[]',
            designersJson: '[]',
            publishersJson: '[]',
            tagsJson: '[]',
            visibility: 'Public',
            createdAt: at,
            updatedAt: at,
          ),
        ]);
        expect(await newDb.select(newDb.events).get(), isEmpty);
        expect(await newDb.select(newDb.eventOccurrences).get(), isEmpty);
        expect(await newDb.select(newDb.eventAttendees).get(), isEmpty);
        expect(await newDb.select(newDb.eventPolicies).get(), isEmpty);
        expect(await newDb.select(newDb.eventAccess).get(), isEmpty);
        expect(await newDb.select(newDb.eventGeneration).get(), isEmpty);
      },
    );
  });

  // Data-integrity coverage for v7 → v8 (#476): the step adds a nullable
  // `households.member_invite_policy`. A household cached before it holds
  // null, which reads as "settings not read yet", until the next hydrate
  // writes the policy the list carries.
  test('migration from v7 to v8 adds an empty member invite policy and '
      'keeps households', () async {
    const at = '2024-01-15T10:30:00.000Z';

    await verifier.testWithDataIntegrity(
      oldVersion: 7,
      newVersion: 8,
      createOld: v7.DatabaseAtV7.new,
      createNew: v8.DatabaseAtV8.new,
      openTestedDatabase: ServerDatabase.new,
      createItems: (batch, oldDb) {
        batch.insert(
          oldDb.households,
          const v7.HouseholdsData(
            id: 'hh_v7_1',
            name: 'Game Night HQ',
            description: 'Where we play',
            isDirty: 0,
            isLocalOnly: 0,
            createdAt: at,
            updatedAt: at,
          ),
        );
      },
      validateItems: (newDb) async {
        expect(await newDb.select(newDb.households).get(), const [
          v8.HouseholdsData(
            id: 'hh_v7_1',
            name: 'Game Night HQ',
            description: 'Where we play',
            isDirty: 0,
            isLocalOnly: 0,
            createdAt: at,
            updatedAt: at,
          ),
        ]);
      },
    );
  });

  test('migration from v8 to v9 adds empty member names and keeps '
      'members', () async {
    const at = '2024-01-15T10:30:00.000Z';

    await verifier.testWithDataIntegrity(
      oldVersion: 8,
      newVersion: 9,
      createOld: v8.DatabaseAtV8.new,
      createNew: v9.DatabaseAtV9.new,
      openTestedDatabase: ServerDatabase.new,
      createItems: (batch, oldDb) {
        batch.insert(
          oldDb.households,
          const v8.HouseholdsData(
            id: 'hh_v8_1',
            name: 'Game Night HQ',
            isDirty: 0,
            isLocalOnly: 0,
            memberInvitePolicy: 'AdminsOnly',
            createdAt: at,
            updatedAt: at,
          ),
        );
        batch.insert(
          oldDb.householdMembers,
          const v8.HouseholdMembersData(
            id: 'hm_v8_1',
            userId: 'user_1',
            householdId: 'hh_v8_1',
            showAllGames: 0,
            roleName: 'HouseholdOwner',
            createdAt: at,
            updatedAt: at,
          ),
        );
      },
      validateItems: (newDb) async {
        expect(await newDb.select(newDb.householdMembers).get(), const [
          v9.HouseholdMembersData(
            id: 'hm_v8_1',
            userId: 'user_1',
            householdId: 'hh_v8_1',
            showAllGames: 0,
            roleName: 'HouseholdOwner',
            createdAt: at,
            updatedAt: at,
          ),
        ]);
        expect(await newDb.select(newDb.households).get(), const [
          v9.HouseholdsData(
            id: 'hh_v8_1',
            name: 'Game Night HQ',
            isDirty: 0,
            isLocalOnly: 0,
            memberInvitePolicy: 'AdminsOnly',
            createdAt: at,
            updatedAt: at,
          ),
        ]);
      },
    );
  });
}
