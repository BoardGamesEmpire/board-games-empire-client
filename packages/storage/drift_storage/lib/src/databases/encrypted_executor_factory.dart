import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:interfaces/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:storage_interface/storage_interface.dart';

/// Builds encrypted [QueryExecutor]s for every BGE database.
///
/// Follows the same "structurally impossible to forget" principle as
/// `bgeMigrationStrategy()`: databases obtain their executors from this
/// factory rather than constructing `NativeDatabase`s by hand, so the
/// encryption key, cipher-availability check, and key verification cannot be
/// wired inconsistently or skipped.
///
/// ## Cipher provider
///
/// Encryption is provided by **SQLite3MultipleCiphers**, selected at build
/// time through the sqlite3 build hook in the workspace-root `pubspec.yaml`:
///
/// ```yaml
/// hooks:
///   user_defines:
///     sqlite3:
///       source: sqlite3mc
/// ```
///
/// There is no Dart-side library loading: the hook bundles the encrypted
/// build with every app *and* with `flutter test` runs. `PRAGMA cipher` is
/// probed at open time; a build without cipher support throws
/// [EncryptionUnavailableError] (a broken build, never a fallback to
/// plaintext).
///
/// ## Key application and verification
///
/// `PRAGMA key` must be the first statement on a connection, so it runs in
/// the raw-database `setup` callback — *before* drift, and therefore before
/// `bgeMigrationStrategy()`'s `beforeOpen` PRAGMAs, which are unaffected.
///
/// Keys are supplied by an [EncryptionKeyService] and are, by that service's
/// contract, 64-char lowercase hex — asserted here before interpolation into
/// the PRAGMA so the statement is injection-proof by construction.
///
/// Because errors thrown inside a background-isolate `setup` callback lose
/// their type crossing the isolate boundary, each open first **probes** the
/// database file on the calling isolate (open → cipher check → key →
/// `sqlite_master` read → close). A wrong or lost key surfaces there as a
/// typed [DatabaseKeyError] that the `ServerContext` open/close path can
/// catch to run the delete + re-key + resync recovery flow. Only after the
/// probe succeeds is the real background connection created.
///
/// ## Dev escape hatch
///
/// `--dart-define=BGE_DISABLE_ENCRYPTION=true` opens all databases
/// unencrypted. **DEV ONLY.** The define is a compile-time constant — a
/// shipped binary has no runtime switch — and it is additionally ignored in
/// release builds ([kReleaseMode]), so even a release accidentally compiled
/// with the flag still encrypts.
class EncryptedExecutorFactory {
  /// Creates the factory.
  ///
  /// [keyService] supplies per-database encryption keys.
  ///
  /// [baseDirectoryProvider] resolves the directory all database paths are
  /// relative to; it defaults to [getApplicationSupportDirectory] and is
  /// injectable only for tests, which pass a temp directory.
  ///
  /// [encryptionEnabled] is visible for testing the plaintext path (and the
  /// dev escape hatch) without recompiling; production wiring must not pass
  /// it.
  EncryptedExecutorFactory({
    required EncryptionKeyService keyService,
    Future<Directory> Function()? baseDirectoryProvider,
    @visibleForTesting bool? encryptionEnabled,
  }) : _keyService = keyService,
       _baseDirectoryProvider =
           baseDirectoryProvider ?? getApplicationSupportDirectory,
       _encryptionEnabled = encryptionEnabled ?? _encryptionEnabledDefault;

  /// DEV ONLY compile-time flag; see class docs.
  static const _disableRequested = bool.fromEnvironment(
    'BGE_DISABLE_ENCRYPTION',
  );

  /// Encryption is always on in release builds; the flag only takes effect
  /// in debug/profile builds.
  static const _encryptionEnabledDefault = kReleaseMode || !_disableRequested;

  static const _serverDatabaseFileName = 'game_empire.db';
  static const _serverDatabaseDirectory = 'app_secure_storage';
  static const _metaDatabaseRelativePath = 'meta/servers.db';

  static final _hexKeyPattern = RegExp(r'^[0-9a-f]{64}$');

  final EncryptionKeyService _keyService;
  final Future<Directory> Function() _baseDirectoryProvider;
  final bool _encryptionEnabled;

  /// Whether databases produced by this factory are encrypted.
  ///
  /// False only when the DEV ONLY `BGE_DISABLE_ENCRYPTION` dart-define is
  /// active in a non-release build (or a test overrode it).
  bool get encryptionEnabled => _encryptionEnabled;

  /// Executor for the per-server database of [serverId], keyed with that
  /// server's encryption key.
  ///
  /// [relativeDatabasePath] defaults to the documented convention
  /// (`app_secure_storage/<serverId>/game_empire.db`). `ServerConfig.databasePath`
  /// produces the same value and remains the source of truth — the
  /// `ServerContext` wiring should pass it explicitly so the two can never
  /// silently diverge.
  QueryExecutor serverExecutor(
    String serverId, {
    String? relativeDatabasePath,
  }) {
    if (serverId.isEmpty) {
      throw ArgumentError.value(serverId, 'serverId', 'must not be empty');
    }
    return _executor(
      relativePath:
          relativeDatabasePath ??
          p.join(_serverDatabaseDirectory, serverId, _serverDatabaseFileName),
      obtainKey: () => _keyService.getOrCreateServerKey(serverId),
    );
  }

  /// Executor for the device-global meta database at
  /// `<AppSupport>/meta/servers.db`, keyed with the global meta key.
  QueryExecutor metaExecutor() {
    return _executor(
      relativePath: _metaDatabaseRelativePath,
      obtainKey: _keyService.getOrCreateMetaKey,
    );
  }

  QueryExecutor _executor({
    required String relativePath,
    required Future<String> Function() obtainKey,
  }) {
    return LazyDatabase(() async {
      final baseDir = await _baseDirectoryProvider();
      final file = File(p.join(baseDir.path, relativePath));
      await file.parent.create(recursive: true);

      if (!_encryptionEnabled) {
        assert(() {
          debugPrint(
            'BGE_DISABLE_ENCRYPTION is active: opening ${file.path} '
            'UNENCRYPTED. This must never happen outside development.',
          );
          return true;
        }());
        return NativeDatabase.createInBackground(file);
      }

      final key = await obtainKey();
      if (!_hexKeyPattern.hasMatch(key)) {
        throw StateError(
          'EncryptionKeyService returned a key that violates the '
          '64-char lowercase hex contract; refusing to use it.',
        );
      }

      // Typed-error probe on this isolate — see class docs.
      _probe(file.path, key);

      return NativeDatabase.createInBackground(
        file,
        setup: (raw) => _applyKey(raw, key),
      );
    });
  }

  /// Opens [path] directly, applies [key], and reads `sqlite_master` so a
  /// wrong or lost key fails *here*, deterministically and typed, instead of
  /// as an untyped error from a background isolate at first query.
  void _probe(String path, String key) {
    final db = sqlite.sqlite3.open(path);
    try {
      _applyKey(db, key);
      try {
        db.select('SELECT COUNT(*) FROM sqlite_master;');
      } on sqlite.SqliteException catch (e) {
        throw DatabaseKeyError(databasePath: path, cause: e);
      }
    } finally {
      db.close();
    }
  }

  /// Verifies cipher support and applies `PRAGMA key` as the first
  /// statements on [db]. Shared between the probe and the real connection's
  /// `setup` so the two can never diverge.
  ///
  /// Static on purpose: the `setup` closure is sent to a background isolate,
  /// and a static target keeps the closure from capturing `this` (and with
  /// it non-sendable state like the key service).
  static void _applyKey(sqlite.Database db, String key) {
    if (db.select('PRAGMA cipher;').isEmpty) {
      throw EncryptionUnavailableError();
    }
    db.execute("PRAGMA key = '$key';");
  }
}
