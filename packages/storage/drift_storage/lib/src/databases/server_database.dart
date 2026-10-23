import 'package:drift/drift.dart';

import '../tables/event_access_table.dart';
import '../tables/event_attendees_table.dart';
import '../tables/event_occurrences_table.dart';
import '../tables/event_policies_table.dart';
import '../tables/event_table.dart';
import '../tables/game_access_table.dart';
import '../tables/game_table.dart';
import '../tables/platform_game_access_table.dart';
import '../tables/platform_game_table.dart';
import '../tables/game_collection_table.dart';
import '../tables/household_table.dart';
import '../tables/household_moves_table.dart';
import '../tables/household_members_table.dart';
import '../tables/sync_queue_table.dart';
import '../tables/unsent_changes_users_table.dart';
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
/// household_members, household_moves, sync_queue, unsent_changes_users,
/// game_access, platform_game_access, events, event_occurrences,
/// event_attendees, event_policies, event_access.
///
/// `game_collections` enforces uniqueness on
/// `(user_id, platform_game_id, medium) WHERE deleted_at IS NULL` via
/// a partial unique index — one live ownership row per triplet, with
/// tombstones (`deleted_at IS NOT NULL`) exempt from the constraint so
/// a user can resurrect a previously deleted entry.
///
/// ## Migrations
///
/// `schemaVersion` is **7**.
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
/// - **v3 → v4 (#442):** adds `household_moves` (`local_id` primary key,
///   `server_id`), where the household reconcile records where an
///   optimistic household went, so every tab and a reload can follow it.
///   A new table with no foreign keys, created by one `createTable`.
/// - **v4 → v5 (#142):** adds `unsent_changes_users`, the users whose
///   unsent `sync_queue` rows the sign-in screen may mention. A new table
///   with no foreign keys, created by one `createTable`. Starts empty:
///   nothing before it recorded whose session was open.
/// - **v5 → v6 (#434, #406):** adds `game_access` and
///   `platform_game_access`, which users each cached game and platform game
///   was sent to, and a nullable `full_record_cached_at` on `games` and
///   `platform_games`, which marks a row holding a full record rather than
///   a collection summary. Additive: two `createTable` calls, an index on
///   each new table's game or platform game id, and two `addColumn` calls.
///   The columns start empty, so every existing row reads as summary-only,
///   and the access rows are backfilled from
///   `game_collections`, live and removed rows alike. Both are right
///   because the collection hydrate was the only writer of those tables
///   before this version. The access tables' foreign keys point at existing
///   tables and no table is rebuilt, so #54 stays deferred.
/// - **v6 → v7 (#496):** adds the event cache: `events`, `event_occurrences`,
///   `event_attendees`, `event_policies` and `event_access`, which records
///   which users each cached event was sent to. Additive: five `createTable`
///   calls, `events` first because the other four reference it, and four
///   `createIndex` calls for the indexes `createTable` leaves out. Nothing is
///   backfilled, because no earlier version cached an event, so all five start
///   empty. The foreign keys point at `events`, which is new, and no existing
///   table is rebuilt, so #54 stays deferred.
///
/// The [migration] strategy is built by `bgeMigrationStrategy()` (see
/// `migration_policy.dart`), which refuses schema *downgrades* by throwing a
/// `SchemaDowngradeError`, runs the `steps` dispatcher on upgrade, and applies
/// the standard PRAGMAs after any migration — FK enforcement always, WAL
/// journalling only where the platform supports it (`enableWriteAheadLog`,
/// #288).
///
/// Every step is a hand-written [OnUpgrade] closure using the live table
/// definitions — sufficient and safe for purely-additive changes and for
/// a rebuild of an FK-free table whose rows are deliberately discarded.
/// If/when the generated step-by-step harness is activated (#54), swap the
/// closure below for the generated `stepByStep(...)` dispatcher. Either
/// way, the committed schema snapshot must be refreshed:
/// `melos run schema:dump` writes
/// `drift_schemas/server/drift_schema_v7.json`, and
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
    HouseholdMovesTable,
    SyncQueueTable,
    UnsentChangesUsersTable,
    GameAccessTable,
    PlatformGameAccessTable,
    EventsTable,
    EventOccurrencesTable,
    EventAttendeesTable,
    EventPoliciesTable,
    EventAccessTable,
  ],
)
class ServerDatabase extends _$ServerDatabase {
  /// Creates the database over a caller-supplied [executor].
  ///
  /// [enableWriteAheadLog] must be `false` for a drift/wasm executor
  /// (#288): sqlite3-wasm does not support WAL journalling. It defaults
  /// to `true` for the native SQLCipher executor, which does. See
  /// `BgeMigrationDefaults.applyStandardPragmas` for why this is the
  /// caller's decision and not a runtime probe.
  ServerDatabase(super.executor, {this.enableWriteAheadLog = true});

  /// Whether `beforeOpen` asks for WAL journalling; see the constructor.
  final bool enableWriteAheadLog;

  // No `.memory()` constructor here (#287): `NativeDatabase.memory()` is
  // `dart:ffi`-backed, and naming it in this file would pull the whole
  // package's neutral surface out of a web build. VM tests get the
  // equivalent from `inMemoryServerDatabase()` in
  // `drift_storage_native.dart`; web gets its own executor from
  // `web_storage` (#288).

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => bgeMigrationStrategy(
    enableWriteAheadLog: enableWriteAheadLog,
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
      if (from < 4 && to >= 4) {
        // v3 → v4 (#442): where reconciled households went. A new table
        // with no FK edges and no rows to carry, so no FK-off wrapper is
        // needed (#54 stays deferred).
        await m.createTable(householdMovesTable);
      }
      if (from < 5 && to >= 5) {
        // v4 → v5 (#142): whose unsent changes the sign-in screen may
        // mention. A new table with no FK edges, created empty, so no
        // FK-off wrapper is needed (#54 stays deferred).
        await m.createTable(unsentChangesUsersTable);
      }
      if (from < 6 && to >= 6) {
        // v5 → v6 (#434, #406): which users each cached row was sent to,
        // and which rows hold a full record. Additive: two new tables and
        // two nullable columns, no table rebuilt, so no FK-off wrapper is
        // needed (#54 stays deferred).
        //
        // The columns are added empty, marking every row summary-only,
        // and the access rows are backfilled from `game_collections`, live
        // and removed alike: until now the collection hydrate was the only
        // writer of `games` and `platform_games`, and every collection row
        // names its user. The backfill is literal SQL, so its columns stay
        // this version's. The `createTable` calls use the live tables, as
        // every step here does until #54.
        await m.addColumn(gamesTable, gamesTable.fullRecordCachedAt);
        await m.addColumn(
          platformGamesTable,
          platformGamesTable.fullRecordCachedAt,
        );
        await m.createTable(gameAccessTable);
        await m.createTable(platformGameAccessTable);
        // createTable does not create a table's indexes.
        await m.createIndex(gameAccessGameIdIdx);
        await m.createIndex(platformGameAccessPlatformGameIdIdx);
        await customStatement(
          'INSERT INTO game_access (user_id, game_id, source) '
          "SELECT DISTINCT c.user_id, p.game_id, 'collection' "
          'FROM game_collections c '
          'JOIN platform_games p ON p.id = c.platform_game_id',
        );
        await customStatement(
          'INSERT INTO platform_game_access '
          '(user_id, platform_game_id, source) '
          "SELECT DISTINCT user_id, platform_game_id, 'collection' "
          'FROM game_collections',
        );
      }
      if (from < 7 && to >= 7) {
        // v6 → v7 (#496): the event cache. Five new tables, created empty:
        // nothing before this version cached an event, so there is nothing
        // to backfill. Additive, with no table rebuilt: the foreign keys
        // point at `events`, which is new, so no FK-off wrapper is needed
        // (#54 stays deferred).
        //
        // `events` goes first because the other four reference it.
        await m.createTable(eventsTable);
        await m.createTable(eventOccurrencesTable);
        await m.createTable(eventAttendeesTable);
        await m.createTable(eventPoliciesTable);
        await m.createTable(eventAccessTable);
        // createTable does not create a table's indexes.
        await m.createIndex(eventOccurrencesEventIdIdx);
        await m.createIndex(eventAttendeesEventIdIdx);
        await m.createIndex(eventAttendeesUserIdIdx);
        await m.createIndex(eventAccessEventIdIdx);
      }
    },
  );
}
