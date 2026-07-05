/// Emitted when a per-server database was automatically recovered after a
/// `DatabaseKeyError` — the encrypted file could not be opened with the
/// stored key, so the file was deleted, the key regenerated, and a fresh
/// (empty) database created. Local data for that server will be rebuilt by
/// sync; pending unsynced changes were lost.
///
/// This is the app layer's hook (#55) to surface a localized,
/// screen-reader-announceable notice. Suggested ARB key:
/// `storageDatabaseKeyMessage`. The event carries identifiers only — never
/// user-facing copy.
class DatabaseRecoveryEvent {
  /// Creates an event for the recovered database.
  const DatabaseRecoveryEvent({
    required this.bgeServerId,
    required this.databasePath,
  });

  /// Stable server identity (`ServerConfig.bgeServerId`) whose local
  /// database was rebuilt. Named explicitly to avoid confusion with the
  /// local `ServerConfig.id`.
  final String bgeServerId;

  /// Absolute path of the database file that was deleted and recreated.
  ///
  /// Intentionally excluded from [toString] so routine event logging does
  /// not leak on-device filesystem paths; read the field directly when a
  /// path is genuinely needed.
  final String databasePath;

  @override
  String toString() => 'DatabaseRecoveryEvent(bgeServerId: $bgeServerId)';
}
