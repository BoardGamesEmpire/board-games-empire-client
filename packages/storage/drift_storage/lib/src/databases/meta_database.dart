import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../tables/server_config_table.dart';
import '../tables/device_preferences_table.dart';
import '../tables/notification_summary_table.dart';
import 'migration_policy.dart';

part 'meta_database.g.dart';

/// Device-global Drift database.
///
/// A single instance per device (not per server), stored at
/// `<AppSupport>/meta/servers.db`. Holds cross-server metadata: the
/// registry of known servers ([ServerConfigs]), device-wide preferences,
/// and notification summaries.
///
/// ## Migrations
///
/// Shares the migration convention with [ServerDatabase] but keeps a
/// completely separate schema history and snapshot directory
/// (`drift_schemas/meta/`). `schemaVersion` is 1 with no forward migrations, so
/// there is no generated `meta_database.steps.dart`. The [migration] strategy
/// is built by `bgeMigrationStrategy()` (see `migration_policy.dart`), which
/// refuses schema *downgrades* by throwing a `SchemaDowngradeError` and applies
/// the standard PRAGMAs (FK enforcement + WAL). See `MIGRATIONS.md`.
@DriftDatabase(
  tables: [ServerConfigs, DevicePreferencesTable, NotificationSummaries],
)
class MetaDatabase extends _$MetaDatabase {
  MetaDatabase() : super(_openConnection());

  @visibleForTesting
  MetaDatabase.test(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => bgeMigrationStrategy();

  static LazyDatabase _openConnection() {
    return LazyDatabase(() async {
      final appDir = await getApplicationSupportDirectory();
      final metaDir = Directory(p.join(appDir.path, 'meta'));

      if (!await metaDir.exists()) {
        await metaDir.create(recursive: true);
      }

      final dbFile = File(p.join(metaDir.path, 'servers.db'));
      return NativeDatabase(dbFile);
    });
  }
}
