import 'dart:io';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:storage_interface/storage_interface.dart';

import '../databases/encrypted_executor_factory.dart';
import '../databases/server_database.dart';

/// [ServerScopeInstaller] for the per-server storage slice: opens the
/// encrypted [ServerDatabase] and registers it in the server's scope.
///
/// ## Eager open
///
/// The database is opened *inside* [install] (not on first query): drift's
/// `LazyDatabase` would otherwise defer the open — and any
/// [DatabaseKeyError] — to an arbitrary first repository call. Opening here
/// keeps failure and recovery inside `ServerContext.activate()`, which is
/// where the lifecycle owns them.
///
/// ## Key-loss recovery (issue #38, Part B of #16)
///
/// A [DatabaseKeyError] on open means the on-disk ciphertext doesn't match
/// the stored key (keychain loss, restored file, corruption). Recovery is
/// automatic and runs **once** per install:
///
/// 1. delete the server's key ([EncryptionKeyService.deleteServerKey]) so a
///    fresh one is generated,
/// 2. delete the database file (and its `-wal`/`-shm`/`-journal` companions),
/// 3. reopen — a new empty database, rebuilt by sync (server is the source
///    of truth; pending unsynced changes are lost),
/// 4. report via [onRecovery] so the app layer (#55) can surface a
///    localized notice.
///
/// If the reopen *also* fails, the error propagates: activation fails, the
/// context rolls back, that server stays unavailable, the app keeps
/// running. [EncryptionUnavailableError] is never caught — a build without
/// cipher support must fail loudly.
///
/// ## Keying
///
/// The encryption key is keyed by the stable [ServerConfig.bgeServerId]
/// (matching token storage: survives user-facing URL changes), while the
/// file location comes from [ServerConfig.databasePath], which is derived
/// from the local id. The two identifiers are deliberately different.
class StorageScopeInstaller implements ServerScopeInstaller {
  /// Creates the installer.
  ///
  /// [executorFactory] builds the encrypted executor and resolves file
  /// paths; [keyService] is consulted only for key deletion during
  /// recovery (the factory obtains keys itself). [onRecovery] is the app
  /// layer's notification hook and may be null until #55 wires it.
  StorageScopeInstaller({
    required EncryptedExecutorFactory executorFactory,
    required EncryptionKeyService keyService,
    void Function(DatabaseRecoveryEvent event)? onRecovery,
  }) : _factory = executorFactory,
       _keys = keyService,
       _onRecovery = onRecovery;

  final EncryptedExecutorFactory _factory;
  final EncryptionKeyService _keys;
  final void Function(DatabaseRecoveryEvent event)? _onRecovery;

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    ServerDatabase db;
    try {
      db = await _open(config);
    } on DatabaseKeyError {
      db = await _recover(config);
    }

    container.registerSingleton<ServerDatabase>(
      db,
      dispose: (database) => database.close(),
    );
  }

  /// Constructs the database over the encrypted executor and forces the
  /// open so key problems surface here as typed errors.
  Future<ServerDatabase> _open(ServerConfig config) async {
    final db = ServerDatabase(
      _factory.serverExecutor(
        config.bgeServerId,
        relativeDatabasePath: config.databasePath,
      ),
    );
    try {
      await db.customSelect('SELECT 1').get();
      return db;
    } catch (_) {
      await _safeClose(db);
      rethrow;
    }
  }

  /// One-shot recovery: rotate key, delete file, reopen fresh, notify. A
  /// second failure propagates to the caller.
  ///
  /// The key is deleted **before** the file: if key deletion throws, the
  /// still-undecryptable file triggers the same recovery on the next
  /// attempt. The reverse order would let a retry silently "succeed"
  /// against a fresh file under the stale key, skipping rotation and the
  /// [onRecovery] notification.
  Future<ServerDatabase> _recover(ServerConfig config) async {
    await _keys.deleteServerKey(config.bgeServerId);
    // Resolve the canonical file the executor uses, and delete + report on
    // that path — not error.databasePath, which is whatever the failing
    // open reported and may be non-canonical.
    final file = await _factory.resolveDatabaseFile(config.databasePath);
    await _deleteDatabaseFiles(file);

    final db = await _open(config);

    _onRecovery?.call(
      DatabaseRecoveryEvent(
        bgeServerId: config.bgeServerId,
        databasePath: file.path,
      ),
    );
    return db;
  }

  /// Deletes the database file and its SQLite companions. Best-effort and
  /// fully async — missing files or transient FS errors are ignored rather
  /// than pre-checked (which would require a blocking sync stat).
  Future<void> _deleteDatabaseFiles(File file) async {
    for (final path in [
      file.path,
      '${file.path}-wal',
      '${file.path}-shm',
      '${file.path}-journal',
    ]) {
      try {
        await File(path).delete();
      } on FileSystemException {
        // File absent or momentarily locked; cleanup is best-effort.
      }
    }
  }

  /// Closes a database whose open may have failed; drift can throw again
  /// from close() in that situation, which is irrelevant here.
  Future<void> _safeClose(ServerDatabase db) async {
    try {
      await db.close();
    } catch (_) {
      // Best-effort: the executor never opened successfully.
    }
  }
}
