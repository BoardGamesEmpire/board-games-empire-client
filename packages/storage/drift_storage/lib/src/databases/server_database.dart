import 'package:drift/drift.dart';

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
/// `schemaVersion` is **3**.
///
/// - **v1 → v2 (#39):** adds `households.is_dirty` and
///   `households.is_local_only`, the optimistic-write flags the household
///   create path needs. Both are additive `BOOLEAN NOT NULL DEFAULT 0`
///   columns, so the step is a pair of `addColumn` calls that back-fill
///   existing rows with `false` — no data transform, no table rebuild.
/// - **v2 → v3 (#147):** adds `sync_queue.user_id` (`TEXT NOT NULL`, no
///   default) so queue rows are attributed to the user who enqueued them,
///   and replaces the `(status, created_at)` index with
///   `(user_id, status, created_at)` — every hot query now leads with the
///   user filter. SQLite cannot `ALTER TABLE ... ADD COLUMN` a NOT NULL
///   column without a default, and the locked decision is to **drop**
///   legacy rows rather than backfill them (attributing them to whichever
///   session happens to run the migration would be wrong — the rows may
///   not be theirs), so the step drops and recreates the table: identical
///   outcome, honest mechanics. `sync_queue` has no foreign-key edges in
///   either direction, so the #54 FK-off + transaction wrapper question
///   stays dormant.
///
/// The [migration] strategy is built by `bgeMigrationStrategy()` (see
/// `migration_policy.dart`), which refuses schema *downgrades* by throwing a
/// `SchemaDowngradeError`, runs the `steps` dispatcher on upgrade, and applies
/// the standard PRAGMAs (FK enforcement + WAL) after any migration.
///
/// Both steps are hand-written [OnUpgrade] closures using the live table
/// definitions — sufficient and safe for a purely-additive column change
/// and for a rebuild of an FK-free table whose rows are deliberately
/// discarded. If/when the generated step-by-step harness is activated
/// (#54), swap the closure below for the generated `stepByStep(...)`
/// dispatcher. Either way, the committed schema snapshot must be
/// refreshed: `melos run schema:dump` writes
/// `drift_schemas/server/drift_schema_v3.json`, and
/// `melos run schema:migrations` regenerates `server_database.steps.dart`
/// plus the `test/drift/` scaffold; the CI schema freshness job
/// byte-compares the snapshot against a fresh dump.
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

  // No `.memory()` constructor here (#287): `NativeDatabase.memory()` is
  // `dart:ffi`-backed, and naming it in this file would pull the whole
  // package's neutral surface out of a web build. VM tests get the
  // equivalent from `inMemoryServerDatabase()` in
  // `drift_storage_native.dart`; web gets its own executor from
  // `web_storage` (#288).

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => bgeMigrationStrategy(
    steps: (Migrator m, int from, int to) async {
      // Every block is bounded on BOTH ends: `from < N` (the classic
      // guard) AND `to >= N`. In production `to` is always
      // [schemaVersion], making the upper bound a no-op — but the schema
      // verifier in test/drift/ also runs *intermediate* migrations
      // (e.g. 1 → 2 while the live schema is at 3), and an unbounded
      // block would over-migrate past the requested target. This is the
      // bounding `stepByStep(...)` would provide for free (#54).
      if (from < 2 && to >= 2) {
        // v1 → v2 (#39): additive optimistic-write flags on households.
        // withDefault(false) back-fills existing rows.
        await m.addColumn(householdsTable, householdsTable.isDirty);
        await m.addColumn(householdsTable, householdsTable.isLocalOnly);
      }
      if (from < 3 && to >= 3) {
        // v2 → v3 (#147): user-scope the sync queue. `user_id` is
        // NOT NULL with no default, which SQLite refuses to ADD COLUMN,
        // and the locked decision is that legacy (pre-column) rows are
        // DROPPED, never backfilled — the migrating session's user may
        // not own them. Dropping and recreating the table implements
        // both in one honest move; the old `(status, created_at)` index
        // goes down with the table and the new
        // `(user_id, status, created_at)` index is created explicitly
        // (createTable does not create a table's indexes). `sync_queue`
        // has no FK edges, so no FK-off wrapper is needed (#54 stays
        // deferred).
        await m.deleteTable('sync_queue');
        await m.createTable(syncQueueTable);
        await m.createIndex(syncQueueUserStatusIdx);
      }
    },
  );
}
