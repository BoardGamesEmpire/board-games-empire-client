// Exercises the real encrypted build (see encrypted_executor_factory_test
// for the tag rationale).
@Tags(['sqlcipher'])
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:path/path.dart' as p;
import 'package:storage_interface/storage_interface.dart';

/// In-memory key service; `loseServerKey` simulates keychain loss.
class _FakeKeyService implements EncryptionKeyService {
  final Map<String, String> _keys = {};
  var _counter = 0;

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

/// Minimal in-memory [DependencyContainer] double.
class _FakeContainer implements DependencyContainer {
  final _singletons = <Type, Object>{};
  final _disposers = <Future<void> Function()>[];

  @override
  T get<T extends Object>() => _singletons[T]! as T;

  @override
  bool isRegistered<T extends Object>() => _singletons.containsKey(T);

  @override
  void registerSingleton<T extends Object>(
    T instance, {
    FutureOr<void> Function(T instance)? dispose,
  }) {
    _singletons[T] = instance;
    if (dispose != null) {
      _disposers.add(() async => dispose(instance));
    }
  }

  @override
  void registerLazySingleton<T extends Object>(
    T Function() factory, {
    FutureOr<void> Function(T instance)? dispose,
  }) => throw UnimplementedError();

  @override
  void registerFactory<T extends Object>(T Function() factory) =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {
    for (final d in _disposers) {
      await d();
    }
    _singletons.clear();
    _disposers.clear();
  }
}

/// Factory stub whose server executors always fail with [DatabaseKeyError],
/// for the recovery-also-fails path.
class _AlwaysFailingFactory extends EncryptedExecutorFactory {
  _AlwaysFailingFactory({
    required super.keyService,
    required super.baseDirectoryProvider,
  });

  @override
  QueryExecutor serverExecutor(
    String serverId, {
    String? relativeDatabasePath,
  }) => throw DatabaseKeyError(databasePath: 'always-failing');
}

ServerConfig _makeConfig({String id = 'server-local-1'}) => ServerConfig(
  id: id,
  displayName: 'Test Server',
  serverUrl: 'https://api.example.com',
  connectionState: ConnectionState.disconnected,
  bgeServerId: '550e8400-e29b-41d4-a716-446655440000',
  cachedIdentity: ServerIdentity(
    serverId: '550e8400-e29b-41d4-a716-446655440000',
    issuer: 'https://api.example.com',
    wellKnownSchemaVersion: 1,
    name: 'Test BGE Server',
    deviceAuthorizationEndpoint: 'https://api.example.com/api/auth/device',
    authBasePath: 'https://api.example.com/api/auth',
    sessionEndpoint: 'https://api.example.com/api/auth/get-session',
    signOutEndpoint: 'https://api.example.com/api/auth/sign-out',
    passkeySupported: true,
    twoFactorSupported: true,
    anonymousAuthSupported: true,
  ),
  lastIdentityFetchedAt: DateTime.now().toUtc(),
);

void main() {
  late Directory tempDir;
  late _FakeKeyService keys;
  late EncryptedExecutorFactory factory;
  late _FakeContainer container;
  final config = _makeConfig();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bge_storage_installer_');
    keys = _FakeKeyService();
    factory = EncryptedExecutorFactory(
      keyService: keys,
      baseDirectoryProvider: () async => tempDir,
    );
    container = _FakeContainer();
  });

  tearDown(() async {
    await container.dispose();
    await tempDir.delete(recursive: true);
  });

  File dbFile() => File(p.join(tempDir.path, config.databasePath));

  StorageScopeInstaller makeInstaller({
    EncryptedExecutorFactory? overrideFactory,
    void Function(DatabaseRecoveryEvent)? onRecovery,
  }) => StorageScopeInstaller(
    executorFactory: overrideFactory ?? factory,
    keyService: keys,
    onRecovery: onRecovery,
  );

  group('install', () {
    test(
      'registers an opened ServerDatabase at ServerConfig.databasePath',
      () async {
        await makeInstaller().install(container, config);

        expect(container.isRegistered<ServerDatabase>(), isTrue);
        expect(dbFile().existsSync(), isTrue);
        // Already open and immediately usable — no lazy first-query open.
        final db = container.get<ServerDatabase>();
        await expectLater(db.customSelect('SELECT 1').get(), completes);
      },
    );

    test('keys encryption by bgeServerId, not the local id', () async {
      await makeInstaller().install(container, config);

      // Losing the *bgeServerId* key must break the next open.
      await container.dispose();
      keys.loseServerKey(config.bgeServerId);

      final failing = ServerDatabase(
        factory.serverExecutor(
          config.bgeServerId,
          relativeDatabasePath: config.databasePath,
        ),
      );
      addTearDown(() async {
        try {
          await failing.close();
        } catch (_) {}
      });
      await expectLater(
        failing.customSelect('SELECT 1').get(),
        throwsA(isA<DatabaseKeyError>()),
      );
    });

    test('container dispose closes the database', () async {
      await makeInstaller().install(container, config);
      final db = container.get<ServerDatabase>();

      await container.dispose();

      // A closed drift database rejects further queries.
      await expectLater(db.customSelect('SELECT 1').get(), throwsA(anything));
    });
  });

  group('key-loss recovery', () {
    test(
      'recovers: deletes file, regenerates key, reopens, notifies',
      () async {
        // First install writes data under the original key.
        await makeInstaller().install(container, config);
        final db = container.get<ServerDatabase>();
        await db.customStatement('CREATE TABLE probe (x TEXT)');
        await db.customStatement("INSERT INTO probe VALUES ('stale')");
        await container.dispose();

        // Simulate keychain loss: the file survives, the key does not.
        keys.loseServerKey(config.bgeServerId);

        final events = <DatabaseRecoveryEvent>[];
        await makeInstaller(onRecovery: events.add).install(container, config);

        expect(events, hasLength(1));
        expect(events.single.bgeServerId, config.bgeServerId);
        expect(events.single.databasePath, dbFile().path);

        // Fresh, usable, and empty — the stale table is gone.
        final recovered = container.get<ServerDatabase>();
        final tables = await recovered
            .customSelect("SELECT name FROM sqlite_master WHERE name = 'probe'")
            .get();
        expect(tables, isEmpty);
      },
    );

    test('does not fire onRecovery on a clean open', () async {
      final events = <DatabaseRecoveryEvent>[];
      await makeInstaller(onRecovery: events.add).install(container, config);

      expect(events, isEmpty);
    });

    test('recovery failure propagates (single retry only)', () async {
      final alwaysFailing = _AlwaysFailingFactory(
        keyService: keys,
        baseDirectoryProvider: () async => tempDir,
      );

      await expectLater(
        makeInstaller(
          overrideFactory: alwaysFailing,
        ).install(container, config),
        throwsA(isA<DatabaseKeyError>()),
      );
      expect(container.isRegistered<ServerDatabase>(), isFalse);
    });
  });
}
