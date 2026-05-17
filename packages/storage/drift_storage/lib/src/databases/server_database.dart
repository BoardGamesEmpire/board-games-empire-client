import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../tables/game_table.dart';
import '../tables/platform_game_table.dart';
import '../tables/game_collection_table.dart';
import '../tables/household_table.dart';
import '../tables/household_members_table.dart';
import '../tables/sync_queue_table.dart';

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
/// `PRAGMA foreign_keys = ON` is set on every open so `REFERENCES`
/// constraints are actually enforced (SQLite defaults to OFF). WAL
/// improves concurrent read/write performance.
///
/// Pre-production: this codebase has no released clients yet, so
/// schema changes are applied destructively in place rather than via
/// versioned migrations. `schemaVersion` stays at 1; bump it (and add
/// an `onUpgrade` handler in [migration]) once a versioned client
/// ships.
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
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
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
