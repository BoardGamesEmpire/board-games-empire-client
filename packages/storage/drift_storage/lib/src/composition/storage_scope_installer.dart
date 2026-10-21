import 'dart:io';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:storage_interface/storage_interface.dart';

import '../databases/encrypted_executor_factory.dart';
import '../databases/server_database.dart';
import '../repositories/unsent_changes_notice_repository_impl.dart';

/// [ServerScopeInstaller] for per-server storage: opens the
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
/// ## Key-loss recovery (#38, #428)
///
/// A [DatabaseKeyError] on open means no key this device holds can open the
/// file: none is stored for it, or the stored one does not decrypt it
/// (keychain loss, an overwritten key, a restored file, corruption).
/// Recovery is the last resort for that case, and runs **once** per
/// install:
///
/// 1. delete the server's key ([EncryptionKeyService.deleteServerKey]) so a
///    fresh one is generated,
/// 2. delete the database file (and its `-wal`/`-shm`/`-journal` companions),
/// 3. reopen — a new empty database, rebuilt by sync. What the file held
///    that the server never received, every user's unsent changes
///    included, is lost: nothing can decrypt it,
/// 4. report via [onRecovery]. The native bootstrap logs the event, and the
///    shell tells the user (#428).
///
/// A key that could not be *read* ([EncryptionKeyUnavailableError]) never
/// reaches recovery. It propagates, so the key and the file are still there
/// for the next attempt.
///
/// If the reopen *also* fails, the error propagates: activation fails, the
/// context rolls back, that server stays unavailable, the app keeps
/// running. [EncryptionUnavailableError] is never caught — a build without
/// cipher support must fail loudly.
///
/// ## Registrations
///
/// The [ServerDatabase], and [UnsentChangesNoticeRepository] (#142), which
/// holds nothing but it.
///
/// [UnsentChangesNoticeRepository] is here because it counts one user's
/// sync-queue rows on the sign-in screen, after that user's scope has been
/// torn down, and at a cold start before any user scope exists. Only this
/// tier is alive at both moments. It reads the queue and never writes it, so
/// the user-session tier's rule that queue writes belong to the session that
/// owns them (#147) still holds.
///
/// It carries no **`dispose:` hook**: it holds nothing but the database,
/// whose own hook closes it on scope teardown, and it vends no streams.
///
/// `GameRepository` is not registered here. It reads per user, so it lives
/// in the user-session scope (`UserSessionScopeInstaller`, #434).
///
/// Web registers no [UnsentChangesNoticeRepository]: it never runs a
/// `ServerScopeInstaller`, and has nothing to count until it restores
/// sessions offline (#144) and drains its queue (#447).
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
  /// recovery (the factory obtains keys itself). [_onRecovery] is the app
  /// layer's notification hook (#428); when null, recovery reports nothing.
  StorageScopeInstaller({
    required EncryptedExecutorFactory executorFactory,
    required EncryptionKeyService keyService,
    this._onRecovery,
  }) : _factory = executorFactory,
       _keys = keyService;

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
    } on DatabaseKeyError catch (error) {
      db = await _recover(config, error.failure);
    }

    container.registerSingleton<ServerDatabase>(
      db,
      dispose: (database) => database.close(),
    );

    container.registerSingleton<UnsentChangesNoticeRepository>(
      UnsentChangesNoticeRepositoryImpl(db),
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
  Future<ServerDatabase> _recover(
    ServerConfig config,
    DatabaseKeyFailure failure,
  ) async {
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
        failure: failure,
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
