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
/// One instance per connected BGE server, stored at
/// `<AppSupport>/servers/<serverId>/server.db`.
///
/// Opened lazily when the [ServerContext] activates; closed when it
/// transitions to [ServerContextState.monitoring].
///
/// Schema version 1 — no migrations needed during pre-production.
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
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}
