import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../tables/game_table.dart';
import '../tables/platform_game_table.dart';
import '../tables/game_collection_table.dart';
import '../tables/household_table.dart';
import '../tables/household_members_table.dart';
import '../tables/sync_queue_table.dart';
import 'migration_policy.dart';

part 'server_database.g.dart';

/// Per-server Drift database.
///
/// One instance per connected BGE server. The DB file lives at
/// `<AppSupport>/app_secure_storage/<serverId>/game_empire.db`
/// (relative path produced by [ServerConfig.databasePath]).
///
/// ## Intended lifecycle (Phase 2)
///
/// Opened lazily when the [ServerContext] activates, closed when it
/// transitions to [ServerContextState.monitoring]. The activate /
/// suspend hooks in [ServerContextImpl] currently carry
/// `TODO(phase2)` markers for the actual open/close wiring; today
/// the DB is constructed directly by whoever holds the reference
/// and stays open for the lifetime of that reference. Phase 2 will
/// move the construction and disposal under [ServerContext] so the
/// DB file is opened/closed in lockstep with the context's state
/// machine.
///
/// ## Schema
///
/// Tables: games, platform_games, game_collections, households,
/// household_members, sync_queue.
///
/// `game_collections` enforces uniqueness on
/// `(user_id, platform_game_id, medium) WHERE deleted_at IS NULL` via
/// a partial unique index — one live ownership row per triplet, with
/// tombstones (`deleted_at IS NOT NULL`) exempt from the constraint so
/// a user can resurrect a previously deleted entry.
///
/// ## Migrations
///
/// `schemaVersion` is 1 and there are no forward migrations yet, so there is
/// no generated `server_database.steps.dart`. The [migration] strategy already
/// refuses schema *downgrades* (opening a newer on-disk DB with an older
/// client) by throwing a `SchemaDowngradeError`, and `beforeOpen` applies the
/// standard PRAGMAs (FK enforcement + WAL) after any migration runs. Adding a
/// versioned migration is a documented workflow — see `MIGRATIONS.md`.
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
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        guardAgainstDowngrade(from, to);
        // No forward migrations yet (schemaVersion == 1). When the schema
        // first changes: bump schemaVersion, run `melos run schema:migrations`
        // to generate `server_database.steps.dart`, then dispatch the
        // generated steps via `stepByStep(...)` here (keeping the downgrade
        // guard first). See MIGRATIONS.md.
      },
      beforeOpen: (details) => applyStandardPragmas(),
    );
  }
}
