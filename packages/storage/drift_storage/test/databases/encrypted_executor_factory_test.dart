// Exercises the real SQLite3MultipleCiphers build supplied by the sqlite3
// build hook (`hooks: user_defines: sqlite3: source: sqlite3mc` in the
// workspace-root pubspec.yaml). Tagged so cipher-dependent suites can be
// selected or excluded explicitly (`flutter test --tags sqlcipher` /
// `--exclude-tags sqlcipher`); no host SQLCipher install is required — the
// hook bundles the encrypted build into test runs.
@Tags(['sqlcipher'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:interfaces/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show SqliteException, sqlite3;
import 'package:storage_interface/storage_interface.dart';

/// In-memory [EncryptionKeyService] with contract-compliant keys.
class _FakeKeyService implements EncryptionKeyService {
  _FakeKeyService();

  final Map<String, String> _keys = {};
  var _counter = 0;

  /// Forces regeneration on next get-or-create, simulating key loss while
  /// the database file survives.
  void loseServerKey(String serverId) => _keys.remove('server:$serverId');

  String _generate() =>
      (_counter++).toRadixString(16).padLeft(64, '0').substring(0, 64);

  @override
  Future<String> getOrCreateServerKey(String serverId) async =>
      _keys.putIfAbsent('server:$serverId', _generate);

  @override
  Future<String> getOrCreateMetaKey() async =>
      _keys.putIfAbsent('meta', _generate);

  @override
  Future<void> deleteServerKey(String serverId) async =>
      _keys.remove('server:$serverId');

  @override
  Future<void> deleteMetaKey() async => _keys.remove('meta');
}

void main() {
  late Directory tempDir;
  late _FakeKeyService keys;
  late EncryptedExecutorFactory factory;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bge_encrypted_exec_');
    keys = _FakeKeyService();
    factory = EncryptedExecutorFactory(
      keyService: keys,
      baseDirectoryProvider: () async => tempDir,
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  File serverDbFile(String serverId) => File(
    p.join(tempDir.path, 'app_secure_storage', serverId, 'game_empire.db'),
  );

  group('serverExecutor', () {
    test('creates the database at the documented per-server path', () async {
      final db = ServerDatabase(factory.serverExecutor('srv_1'));
      addTearDown(db.close);

      // Force the lazy open.
      await db.customSelect('SELECT 1').get();

      expect(serverDbFile('srv_1').existsSync(), isTrue);
    });

    test('rejects an empty server id', () {
      expect(() => factory.serverExecutor(''), throwsA(isA<ArgumentError>()));
    });

    test('written file is not plaintext SQLite', () async {
      final db = ServerDatabase(factory.serverExecutor('srv_1'));
      // Scratch table keeps this test decoupled from the drift schema.
      await db.customStatement('CREATE TABLE probe (x TEXT)');
      await db.customStatement("INSERT INTO probe VALUES ('Catan')");
      await db.close();

      final header = serverDbFile('srv_1').openSync().readSync(16);
      // Plaintext SQLite files begin with the magic string
      // "SQLite format 3\u0000"; an encrypted file must not.
      expect(
        String.fromCharCodes(header),
        isNot(startsWith('SQLite format 3')),
      );
    });

    test('data persists across close and re-open with the same key', () async {
      final first = ServerDatabase(factory.serverExecutor('srv_1'));
      await first.customStatement('CREATE TABLE probe (x TEXT)');
      await first.customStatement("INSERT INTO probe VALUES ('Catan')");
      await first.close();

      final second = ServerDatabase(factory.serverExecutor('srv_1'));
      addTearDown(second.close);
      final rows = await second.customSelect('SELECT x FROM probe').get();

      expect(rows.single.read<String>('x'), 'Catan');
    });

    test('lost key surfaces as a typed DatabaseKeyError', () async {
      final first = ServerDatabase(factory.serverExecutor('srv_1'));
      await first.customSelect('SELECT 1').get();
      await first.close();

      keys.loseServerKey('srv_1');

      final second = ServerDatabase(factory.serverExecutor('srv_1'));
      addTearDown(() async {
        // close() on a never-opened lazy db is a no-op safeguard.
        try {
          await second.close();
        } catch (_) {}
      });

      await expectLater(
        second.customSelect('SELECT 1').get(),
        throwsA(
          isA<DatabaseKeyError>().having(
            (e) => e.databasePath,
            'databasePath',
            serverDbFile('srv_1').path,
          ),
        ),
      );
    });

    test(
      'transient lock errors pass through untranslated (no DatabaseKeyError)',
      () async {
        // Create the database, then hold an exclusive lock on the file from
        // a separate raw connection so the probe's sqlite_master read hits
        // SQLITE_BUSY — a transient condition that must NOT authorize the
        // destructive key-recovery path.
        final db = ServerDatabase(factory.serverExecutor('srv_1'));
        await db.customSelect('SELECT 1').get();
        await db.close();

        final key = await keys.getOrCreateServerKey('srv_1');
        final locker = sqlite3.open(serverDbFile('srv_1').path);
        addTearDown(locker.close);
        locker.execute("PRAGMA key = '$key';");
        locker.execute('PRAGMA locking_mode = EXCLUSIVE;');
        locker.execute('BEGIN EXCLUSIVE;');

        final blocked = ServerDatabase(factory.serverExecutor('srv_1'));
        addTearDown(() async {
          try {
            await blocked.close();
          } catch (_) {}
        });

        await expectLater(
          blocked.customSelect('SELECT 1').get(),
          throwsA(
            allOf(isA<SqliteException>(), isNot(isA<DatabaseKeyError>())),
          ),
        );
      },
    );

    test('databases of different servers use independent keys', () async {
      final a = ServerDatabase(factory.serverExecutor('srv_a'));
      final b = ServerDatabase(factory.serverExecutor('srv_b'));
      addTearDown(a.close);
      addTearDown(b.close);
      await a.customSelect('SELECT 1').get();
      await b.customSelect('SELECT 1').get();

      // Losing one server's key must not affect the other.
      keys.loseServerKey('srv_a');

      final aReopen = ServerDatabase(factory.serverExecutor('srv_a'));
      final bReopen = ServerDatabase(factory.serverExecutor('srv_b'));
      addTearDown(bReopen.close);
      addTearDown(() async {
        try {
          await aReopen.close();
        } catch (_) {}
      });

      await expectLater(
        aReopen.customSelect('SELECT 1').get(),
        throwsA(isA<DatabaseKeyError>()),
      );
      await expectLater(bReopen.customSelect('SELECT 1').get(), completes);
    });
  });

  group('metaExecutor', () {
    test('creates the database at the documented meta path', () async {
      final db = MetaDatabase(factory.metaExecutor());
      addTearDown(db.close);

      await db.customSelect('SELECT 1').get();

      expect(
        File(p.join(tempDir.path, 'meta', 'servers.db')).existsSync(),
        isTrue,
      );
    });

    test('meta file is not plaintext SQLite', () async {
      final db = MetaDatabase(factory.metaExecutor());
      await db.customSelect('SELECT 1').get();
      await db.close();

      final header = File(
        p.join(tempDir.path, 'meta', 'servers.db'),
      ).openSync().readSync(16);
      expect(
        String.fromCharCodes(header),
        isNot(startsWith('SQLite format 3')),
      );
    });
  });

  group('encryption disabled (dev escape hatch)', () {
    test('opens plaintext and never consults the key service', () async {
      final plaintextKeys = _FakeKeyService();
      final plainFactory = EncryptedExecutorFactory(
        keyService: plaintextKeys,
        baseDirectoryProvider: () async => tempDir,
        encryptionEnabled: false,
      );

      final db = ServerDatabase(plainFactory.serverExecutor('srv_1'));
      await db.customSelect('SELECT 1').get();
      await db.close();

      final header = serverDbFile('srv_1').openSync().readSync(16);
      expect(String.fromCharCodes(header), startsWith('SQLite format 3'));
    });
  });

  group('resolveDatabaseFile validation', () {
    test('rejects absolute paths', () {
      expect(
        () => factory.resolveDatabaseFile('/etc/passwd'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects upward traversal', () {
      expect(
        () => factory.resolveDatabaseFile('../../secrets.db'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('accepts a normal relative path', () async {
      final file = await factory.resolveDatabaseFile('a/b/c.db');
      expect(p.isWithin(tempDir.path, file.path), isTrue);
    });
  });

  group('encryptionEnabled default', () {
    test('is on unless the dev define was set at compile time', () {
      // In an ordinary test binary BGE_DISABLE_ENCRYPTION is not defined,
      // so the default must be enabled.
      expect(factory.encryptionEnabled, isTrue);
    });
  });
}
