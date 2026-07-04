/// Thrown when an encrypted database file cannot be opened with the stored
/// encryption key — the on-disk ciphertext does not decrypt.
///
/// This means one of: the key was lost or regenerated while the old file
/// remained (keychain reset, device migration that could not carry
/// hardware-bound keys), the file was restored from a backup made on another
/// device, or the file is corrupt. From the client's perspective these are
/// indistinguishable and share one recovery: **delete the database file,
/// delete and regenerate the key, and re-sync from the server** — the client
/// database is a cache, the server is the source of truth. Pending unsynced
/// sync-queue entries are lost; that loss is an accepted tradeoff of
/// encryption-at-rest.
///
/// This is a storage-layer *contract* type, deliberately defined in
/// `storage_interface` rather than in a concrete backend: the application
/// layer (the `ServerContext` open/close path) catches it while depending
/// only on the storage abstraction, runs the recovery flow, and surfaces a
/// localized message.
///
/// Localization is the app layer's responsibility. This type carries no
/// user-facing copy. Suggested ARB key: `storageDatabaseKeyMessage`
/// ("this server's local data couldn't be opened; sync will rebuild it").
class DatabaseKeyError implements Exception {
  /// Creates an error for the database file at [databasePath], optionally
  /// preserving the underlying [cause] (typically a `SqliteException`).
  const DatabaseKeyError({required this.databasePath, this.cause});

  /// Absolute path of the database file that failed to open.
  ///
  /// Identifies *which* database is affected (per-server vs meta) so the
  /// recovery flow can scope its cleanup; never shown to the user verbatim.
  final String databasePath;

  /// The underlying error reported by the database layer, if any.
  final Object? cause;

  @override
  String toString() =>
      'DatabaseKeyError: database at $databasePath could not be opened with '
      'the stored encryption key; the file must be deleted, the key '
      'regenerated, and the data re-synced from the server.'
      '${cause == null ? '' : ' Cause: $cause'}';
}
