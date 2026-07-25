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
/// `schemaVersion` is **2**.
///
/// - **v1 → v2 (#39):** adds `households.is_dirty` and
///   `households.is_local_only`, the optimistic-write flags the household
///   create path needs. Both are additive `BOOLEAN NOT NULL DEFAULT 0`
///   columns, so the step is a pair of `addColumn` calls that back-fill
///   existing rows with `false` — no data transform, no table rebuild.
///
/// The [migration] strategy is built by `bgeMigrationStrategy()` (see
/// `migration_policy.dart`), which refuses schema *downgrades* by throwing a
/// `SchemaDowngradeError`, runs the `steps` dispatcher on upgrade, and applies
/// the standard PRAGMAs (FK enforcement + WAL) after any migration.
///
/// The v1 → v2 step is a hand-written [OnUpgrade] using the live table
/// definitions — sufficient and safe for a purely additive change. If/when
/// the generated step-by-step harness is activated (#54), swap the closure
/// below for the generated `stepByStep(...)` dispatcher. Either way, the
/// committed schema snapshot must be refreshed: `melos run schema:dump`
/// writes `drift_schemas/server/drift_schema_v2.json`, which the CI schema
/// freshness job byte-compares against a fresh dump.
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
  MigrationStrategy get migration => bgeMigrationStrategy(
    steps: (Migrator m, int from, int to) async {
      if (from < 2) {
        // v1 → v2 (#39): additive optimistic-write flags on households.
        // withDefault(false) back-fills existing rows.
        await m.addColumn(householdsTable, householdsTable.isDirty);
        await m.addColumn(householdsTable, householdsTable.isLocalOnly);
      }
    },
  );
}
