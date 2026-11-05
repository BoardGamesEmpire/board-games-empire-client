import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';
import 'watch_disposal.dart';

/// [ListLayoutRepository] over the per-server database, for one user (#710).
///
/// Every read and write is keyed to [_userId], so a scope built for one user
/// cannot see or change another's choice. It vends no streams, but takes
/// [WatchDisposal] so the user-session scope closes it with the rest: after
/// `onDispose()` its methods throw [StateError].
class ListLayoutRepositoryImpl
    with WatchDisposal
    implements ListLayoutRepository {
  ListLayoutRepositoryImpl(this._db, {required this._userId});

  final ServerDatabase _db;
  final String _userId;

  @override
  String get disposedRepositoryName => 'ListLayoutRepository';

  @override
  Future<ListLayout?> read(ListLayoutScreen screen) async {
    checkNotDisposed();
    final table = _db.listLayoutsTable;
    final row =
        await (_db.select(table)..where(
              (t) => t.userId.equals(_userId) & t.screen.equals(screen.name),
            ))
            .getSingleOrNull();
    // Null for a name this build doesn't know, as for no row.
    return row == null ? null : ListLayout.values.asNameMap()[row.layout];
  }

  @override
  Future<void> write(ListLayoutScreen screen, ListLayout layout) async {
    checkNotDisposed();
    await _db
        .into(_db.listLayoutsTable)
        .insertOnConflictUpdate(
          ListLayoutsTableCompanion.insert(
            userId: _userId,
            screen: screen.name,
            layout: layout.name,
          ),
        );
  }
}
