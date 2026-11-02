import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';

import '../databases/meta_database.dart';

/// [SessionTombstoneStore] over `server_configs.session_revoked_at` (#356).
///
/// ## Why the meta database
///
/// The marker is for the case where the keychain's delete just failed, so a
/// second keychain entry is only as reliable as the store that failed. The
/// meta database is a separate store that boot already depends on, and a
/// marker on a server's own row goes when the server does.
///
/// ## What it writes
///
/// Only `session_revoked_at`. It leaves `updated_at` alone, since a marker
/// isn't an edit to the server's configuration. `updateServer` never writes
/// the column, so renaming a server doesn't clear the marker.
class SessionTombstoneStoreImpl implements SessionTombstoneStore {
  SessionTombstoneStoreImpl(this._database);

  final MetaDatabase _database;

  @override
  Future<bool> isRevoked(String bgeServerId) async {
    final table = _database.serverConfigs;
    final revokedAt = table.sessionRevokedAt;
    final row =
        await (_database.selectOnly(table)
              ..addColumns([revokedAt])
              ..where(table.bgeServerId.equals(bgeServerId)))
            .getSingleOrNull();
    return row?.read(revokedAt) != null;
  }

  @override
  Future<void> markRevoked(String bgeServerId) async {
    final matched =
        await (_database.update(
          _database.serverConfigs,
        )..where((t) => t.bgeServerId.equals(bgeServerId))).write(
          ServerConfigsCompanion(
            sessionRevokedAt: Value(DateTime.now().toUtc()),
          ),
        );
    if (matched == 0) throw ServerNotFoundException(bgeServerId);
  }

  @override
  Future<void> clearRevoked(String bgeServerId) async {
    // Every store comes through here, and nearly always finds nothing to
    // clear. Matching no row writes nothing and notifies no table watcher.
    await (_database.update(_database.serverConfigs)..where(
          (t) =>
              t.bgeServerId.equals(bgeServerId) &
              t.sessionRevokedAt.isNotNull(),
        ))
        .write(const ServerConfigsCompanion(sessionRevokedAt: Value(null)));
  }
}
