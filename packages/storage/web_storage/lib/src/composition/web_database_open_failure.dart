/// The forced open of a server database failed (#793).
///
/// Thrown by `WebStorageInstaller.install` only when the database file itself
/// won't open: the `SELECT 1` that runs `onCreate` and the migrations fails
/// with a `SqliteException`, or with an error a migration raised in the page.
/// Other failures keep their own untyped error, because deleting stored data
/// can't fix them: a browser that can't provide storage, and an engine that
/// fails to load. drift's worker loads `sqlite3.wasm` and opens the storage
/// at that `SELECT 1`, so those can fail there too.
///
/// The type is what lets the app layer count only this failure toward its
/// offer to delete the local database, and not, say, an offline identity
/// fetch.
final class WebDatabaseOpenFailure implements Exception {
  /// Wraps the error [cause] that drift raised while opening.
  const WebDatabaseOpenFailure(this.cause);

  /// What drift raised. The database runs in drift's worker, so this is
  /// usually drift's `DriftRemoteException`, whose `remoteCause` is the
  /// `SqliteException`'s text (#793).
  final Object cause;

  @override
  String toString() => 'WebDatabaseOpenFailure: $cause';
}
