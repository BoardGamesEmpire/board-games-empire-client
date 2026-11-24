/// Another tab has the server database open, on storage where only one tab at
/// a time may (#686).
///
/// Thrown by `WebStorageInstaller.install` when the database landed on
/// `unsafeIndexedDb` and another tab held it for the whole wait. This tab
/// closed its connection without reading or writing anything. Once the other
/// tab closes, opening again reads what it wrote.
///
/// Typed so the app layer can show the in-use screen, and not count it as a
/// database that won't open.
final class WebDatabaseInUse implements Exception {
  /// Names the database another tab holds.
  const WebDatabaseInUse(this.databaseName);

  /// The storage name of the database, from
  /// `WebWasmExecutorFactory.databaseName`.
  final String databaseName;

  @override
  String toString() => 'WebDatabaseInUse: $databaseName is open in another tab';
}
