import '../errors/database_key_error.dart';

/// Emitted when a per-server database is rebuilt because no key this device
/// holds could open it (a `DatabaseKeyError`): the key and the file have
/// been deleted, and a fresh, empty database opens next. Sync rebuilds what
/// the server holds. What the file held that the server never received,
/// every user's unsent changes on that server included, is gone with it
/// (#428).
///
/// It is emitted before the fresh database opens, so a loss is reported even
/// when that open fails.
///
/// The native bootstrap logs each event and hands the ones from start-up to
/// the shell, which tells the user (#428). The event carries identifiers
/// only — never user-facing copy.
class DatabaseRecoveryEvent {
  /// Creates an event for the recovered database.
  const DatabaseRecoveryEvent({
    required this.bgeServerId,
    required this.databasePath,
    required this.failure,
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

  /// Whether the file's key was missing or did not open it.
  final DatabaseKeyFailure failure;

  @override
  String toString() =>
      'DatabaseRecoveryEvent(bgeServerId: $bgeServerId, '
      'failure: ${failure.name})';
}
