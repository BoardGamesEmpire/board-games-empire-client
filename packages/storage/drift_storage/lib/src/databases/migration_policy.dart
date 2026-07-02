import 'package:drift/drift.dart';
import 'package:storage_interface/storage_interface.dart';

/// Refuses a schema *downgrade*.
///
/// Drift invokes `onUpgrade` for both upgrades and downgrades. When the
/// on-disk version ([from]) is newer than the version this client supports
/// ([to]) there is no safe path forward — running migrations backwards is
/// impossible and would risk data loss. This throws [SchemaDowngradeError] so
/// the app layer can refuse to open the database and surface a localized
/// message. See `MIGRATIONS.md`.
///
/// A no-op for upgrades (`from < to`) and no-change opens (`from == to`).
void guardAgainstDowngrade(int from, int to) {
  if (from > to) {
    throw SchemaDowngradeError(onDisk: from, supported: to);
  }
}

/// Shared migration defaults for every BGE database.
extension BgeMigrationDefaults on GeneratedDatabase {
  /// Enables foreign-key enforcement — SQLite defaults to OFF and otherwise
  /// silently ignores `REFERENCES` constraints — and switches to WAL
  /// journalling for better concurrent read/write throughput.
  ///
  /// Called from `beforeOpen`, which drift runs *after* any migration. That
  /// ordering is deliberate: migrations must run with foreign keys disabled
  /// (see `MIGRATIONS.md`), and re-enabling them here is the single, shared
  /// place that invariant is honoured.
  Future<void> applyStandardPragmas() async {
    await customStatement('PRAGMA foreign_keys = ON');
    await customStatement('PRAGMA journal_mode = WAL');
  }

  /// Builds the standard BGE [MigrationStrategy]: create all tables on first
  /// open, refuse schema downgrades, then apply the standard PRAGMAs after any
  /// migration.
  ///
  /// Databases should build their [MigrationStrategy] with this rather than
  /// assembling one by hand, so the downgrade guard and PRAGMA setup can't be
  /// forgotten or wired inconsistently.
  ///
  /// [steps] runs *after* [guardAgainstDowngrade] on upgrade — pass the
  /// generated `stepByStep(...)` dispatcher once a schema version exists (see
  /// `MIGRATIONS.md`). Leave it null while `schemaVersion` is 1.
  ///
  /// The `PRAGMA foreign_keys = OFF` + `transaction(...)` wrapper that real
  /// destructive migrations need is deliberately NOT applied here yet: whether
  /// this factory should own it depends on how drift's generated `stepByStep`
  /// manages transactions/foreign keys, which is resolved against real
  /// behaviour when the first migration lands rather than guessed now. See #54.
  MigrationStrategy bgeMigrationStrategy({OnUpgrade? steps}) {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        guardAgainstDowngrade(from, to);
        if (steps != null) {
          await steps(m, from, to);
        }
      },
      beforeOpen: (details) => applyStandardPragmas(),
    );
  }
}
