import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../tables/game_table.dart';
import '../tables/platform_game_table.dart';
import '../tables/game_collection_table.dart';
import '../tables/household_table.dart';
import '../tables/sync_queue_table.dart';

part 'server_database.g.dart';

/// Per-server Drift database.
///
/// One instance per connected BGE server. The DB file lives at
/// `<AppSupport>/app_secure_storage/<serverId>/game_empire.db`
/// (relative path produced by [ServerConfig.databasePath]).
///
/// Opened lazily when the [ServerContext] activates; closed when it
/// transitions to [ServerContextState.monitoring].
///
/// ## Schema versions
///
/// - **v1**: initial. games, platform_games, game_collections,
///   households, household_members, sync_queue.
/// - **v2**: + `deleted_at` and `release_id` on `game_collections`;
///   the single-column `game_collections_platform_game_idx` is
///   replaced with a partial unique index on
///   `(user_id, platform_game_id, medium) WHERE deleted_at IS NULL`,
///   enforcing one live ownership row per triplet while permitting
///   tombstones; `household_members_household_idx` renamed to
///   `household_members_household_user_unique_idx` (same columns,
///   clearer name); legacy `sync_queue.status` value `'in_progress'`
///   rewritten to `'inProgress'` to match `SyncStatus.name`; PRAGMA
///   `foreign_keys = ON` enabled so `REFERENCES` constraints are
///   actually enforced (SQLite ignores them by default).
@DriftDatabase(
  tables: [
    GamesTable,
    PlatformGamesTable,
    GameCollectionsTable,
    HouseholdsTable,
    HouseholdMembersTable,
    SyncQueueTable,
  ],
)
class ServerDatabase extends _$ServerDatabase {
  ServerDatabase(super.executor);

  /// In-memory database for tests.
  ServerDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 2) {
        // 1. Add the new columns to game_collections. Both are nullable,
        //    so SQLite ALTER TABLE ADD COLUMN backfills NULL safely.
        await m.addColumn(
          gameCollectionsTable,
          gameCollectionsTable.deletedAt,
        );
        await m.addColumn(
          gameCollectionsTable,
          gameCollectionsTable.releaseId,
        );

        // 2. Replace the single-column platform-game index with the
        //    partial unique index. Note: this CREATE fails loudly if
        //    pre-existing data contains duplicates on the triplet,
        //    which is the intended signal in pre-production.
        await customStatement(
          'DROP INDEX IF EXISTS game_collections_platform_game_idx',
        );
        await customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS '
          'game_collections_user_pgame_medium_unique_idx '
          'ON game_collections (user_id, platform_game_id, medium) '
          'WHERE deleted_at IS NULL',
        );

        // 3. Rename the household_members uniqueness index.
        await customStatement(
          'DROP INDEX IF EXISTS household_members_household_idx',
        );
        await customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS '
          'household_members_household_user_unique_idx '
          'ON household_members (household_id, user_id)',
        );

        // 4. Rewrite sync_queue.status legacy value 'in_progress' to
        //    'inProgress' to match SyncStatus.name. The repository
        //    parses both forms during the transition; Pass 3 may drop
        //    the legacy parse arm once we are confident no v1-state
        //    DBs survive.
        await customStatement(
          "UPDATE sync_queue SET status = 'inProgress' "
          "WHERE status = 'in_progress'",
        );
      }
    },
    beforeOpen: (details) async {
      // FK enforcement: SQLite silently ignores REFERENCES constraints
      // unless this is set. Matches MetaDatabase's behaviour.
      await customStatement('PRAGMA foreign_keys = ON');
      // WAL improves concurrent read/write performance.
      await customStatement('PRAGMA journal_mode = WAL');
    },
  );
}
