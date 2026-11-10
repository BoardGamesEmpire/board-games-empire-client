import 'package:drift/drift.dart';
import 'package:drift_storage/src/databases/migration_policy.dart';
import 'package:drift_storage/src/tables/device_preferences_table.dart';
import 'package:drift_storage/src/tables/notification_summary_table.dart';
import 'package:drift_storage/src/tables/server_config_table.dart';
import 'package:flutter/foundation.dart';

part 'meta_database.g.dart';

/// Device-global Drift database.
///
/// A single instance per device (not per server), stored at
/// `<AppSupport>/meta/servers.db`. Holds cross-server metadata: the
/// registry of known servers ([ServerConfigs]), device-wide preferences,
/// and notification summaries.
///
/// ## Construction
///
/// The executor is injected, mirroring [ServerDatabase]. Production wiring
/// obtains it from [EncryptedExecutorFactory.metaExecutor], which owns path
/// resolution and encryption-at-rest (SQLite3MultipleCiphers, keyed with the
/// device-global `encryption_key:meta` key). Constructing a `NativeDatabase`
/// directly bypasses encryption and must not happen outside tests.
///
/// ## Migrations
///
/// Shares the migration convention with [ServerDatabase] but keeps a
/// completely separate schema history and snapshot directory
/// (`drift_schemas/meta/`). `schemaVersion` is **2**. The [migration] strategy
/// is built by `bgeMigrationStrategy()` (see `migration_policy.dart`), which
/// refuses schema *downgrades* by throwing a `SchemaDowngradeError`, runs the
/// `steps` closure on upgrade, and applies the standard PRAGMAs (FK
/// enforcement + WAL). See `MIGRATIONS.md`.
///
/// - **v1 → v2 (#356):** adds a nullable `server_configs.session_revoked_at`,
///   the durable record that a server's stored session must not be restored.
///   One `addColumn`, so existing rows read null and #54 stays deferred.
@DriftDatabase(
  tables: [ServerConfigs, DevicePreferencesTable, NotificationSummaries],
)
class MetaDatabase extends _$MetaDatabase {
  MetaDatabase(super.executor);

  @visibleForTesting
  MetaDatabase.test(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => bgeMigrationStrategy(
    steps: (Migrator m, int from, int to) async {
      // Every block is bounded on BOTH ends: `from < N` and `to >= N`. The
      // schema verifier in test/drift/ runs intermediate migrations, and an
      // unbounded block would over-migrate past the requested target (the
      // same convention as [ServerDatabase]).
      if (from < 2 && to >= 2) {
        // v1 → v2 (#356): the durable session marker. Nullable, so existing
        // rows read null (not revoked) without a back-fill.
        await m.addColumn(serverConfigs, serverConfigs.sessionRevokedAt);
      }
    },
  );
}
