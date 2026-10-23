/// Why an encrypted database could not be opened with a key (#428).
enum DatabaseKeyFailure {
  /// The database file exists, and the key store holds no key for it.
  keyMissing,

  /// A key is stored, and the file does not decrypt with it.
  keyMismatch,
}

/// Thrown when an encrypted database file on disk cannot be opened with any
/// key this device holds: no key is stored for it
/// ([DatabaseKeyFailure.keyMissing]), or the stored key does not decrypt it
/// ([DatabaseKeyFailure.keyMismatch]).
///
/// The known causes: the keychain entry was lost (a keychain reset, a device
/// migration that could not carry hardware-bound keys, a backup restored
/// without its keychain entry), the key was overwritten (#185), or the file
/// is corrupt. In each one, no key that still exists can read the file. A
/// key that could not be *read* is a different condition, reported as
/// `EncryptionKeyUnavailableError`, and never as this error.
///
/// For a per-server database, the recovery is a last resort (#428): delete
/// the key and the file, open a fresh database, and rebuild it from the
/// server. Whatever the file held that the server never received is lost
/// with it, every user's unsent changes included, because nothing can
/// decrypt them. The app tells the user when that happens. For the meta
/// database, the shell offers a reset, which needs the user's confirmation.
///
/// This is a storage-layer *contract* type, deliberately defined in
/// `storage_interface` rather than in a concrete backend: the application
/// layer (the `ServerContext` open/close path) catches it while depending
/// only on the storage abstraction, runs the recovery flow, and surfaces a
/// localized message.
///
/// Localization is the app layer's responsibility. This type carries no
/// user-facing copy.
class DatabaseKeyError implements Exception {
  /// Creates an error for the database file at [databasePath], optionally
  /// preserving the underlying [cause] (typically a `SqliteException`).
  const DatabaseKeyError({
    required this.databasePath,
    required this.failure,
    this.cause,
  });

  /// Absolute path of the database file that failed to open.
  ///
  /// Identifies *which* database is affected (per-server vs meta) so the
  /// recovery flow can scope its cleanup; never shown to the user verbatim.
  final String databasePath;

  /// Whether the key was missing or did not open the file.
  final DatabaseKeyFailure failure;

  /// The underlying error reported by the database layer, if any.
  final Object? cause;

  @override
  String toString() {
    final problem = switch (failure) {
      DatabaseKeyFailure.keyMissing =>
        'no encryption key is stored for the database at $databasePath',
      DatabaseKeyFailure.keyMismatch =>
        'the database at $databasePath does not decrypt with the stored '
            'encryption key',
    };
    return 'DatabaseKeyError(${failure.name}): $problem.'
        '${cause == null ? '' : ' Cause: $cause'}';
  }
}
