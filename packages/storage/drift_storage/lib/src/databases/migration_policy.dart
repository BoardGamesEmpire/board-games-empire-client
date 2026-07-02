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

/// Standard SQLite PRAGMAs applied to every BGE database on open.
extension BgeDatabasePragmas on GeneratedDatabase {
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
}
