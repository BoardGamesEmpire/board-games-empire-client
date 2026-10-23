// Exercises the real encrypted build (see encrypted_executor_factory_test
// for the tag rationale).
@Tags(['sqlcipher'])
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:path/path.dart' as p;
import 'package:storage_interface/storage_interface.dart';

import '../support/fixed_clock.dart';

/// In-memory key service; `loseServerKey` simulates keychain loss.
class _FakeKeyService implements EncryptionKeyService {
  final Map<String, String> _keys = {};
  var _counter = 0;
  var deletedServerKeys = 0;

  /// When set, every server-key call fails as a key store that can't be
  /// reached.
  bool unavailable = false;

  /// When set, making a new server key fails as a key store that can't be
  /// written.
  bool cannotCreate = false;

  void loseServerKey(String serverId) => _keys.remove('server:$serverId');

  /// Overwrites the stored key with a different valid one.
  void replaceServerKey(String serverId) =>
      _keys['server:$serverId'] = _generate();

  String _generate() =>
      (_counter++).toRadixString(16).padLeft(64, '0').substring(0, 64);

  void _throwIfUnavailable() {
    if (unavailable) throw const EncryptionKeyUnavailableError();
  }

  @override
  Future<String> getOrCreateServerKey(String serverId) async {
    _throwIfUnavailable();
    return _keys.putIfAbsent('server:$serverId', () {
      if (cannotCreate) throw const EncryptionKeyUnavailableError();
      return _generate();
    });
  }

  @override
  Future<String> getOrCreateMetaKey() async =>
      _keys.putIfAbsent('meta', _generate);

  @override
  Future<String?> findServerKey(String serverId) async {
    _throwIfUnavailable();
    return _keys['server:$serverId'];
  }

  @override
  Future<String?> findMetaKey() async => _keys['meta'];

  @override
  Future<void> deleteServerKey(String serverId) async {
    _throwIfUnavailable();
    deletedServerKeys++;
    _keys.remove('server:$serverId');
  }

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
  }) => throw const DatabaseKeyError(
    databasePath: 'always-failing',
    failure: DatabaseKeyFailure.keyMismatch,
  );
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
    deviceAuthorizationEndpoint: '/api/auth/device',
    authBasePath: '/api/auth',
    sessionEndpoint: '/api/auth/get-session',
    signOutEndpoint: '/api/auth/sign-out',
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

    // #434: the game cache reads per user, so it is registered in the
    // user-session scope, never here. A server-scope instance would answer
    // for whichever user resolved it.
    test('does not register GameRepository', () async {
      await makeInstaller().install(container, config);

      expect(container.isRegistered<GameRepository>(), isFalse);
    });

    // #142: the sign-in screen's count has to answer after the user's scope
    // is gone and before anyone signs in, so it lives in this tier.
    test('registers UnsentChangesNoticeRepository over the same '
        'ServerDatabase the sync queue writes to', () async {
      await makeInstaller().install(container, config);

      expect(container.isRegistered<UnsentChangesNoticeRepository>(), isTrue);

      final db = container.get<ServerDatabase>();
      final clock = FixedClockService(DateTime.utc(2024, 1, 15));
      await SyncQueueRepositoryImpl(
        db,
        clock,
        userId: 'user-a',
        localNowUtc: clock.nowUtc,
      ).enqueue(
        const AddToCollectionOperation(
          localId: 'local-1',
          platformGameId: 'pg-1',
          medium: 'Physical',
          quantity: 1,
        ),
      );
      final notice = container.get<UnsentChangesNoticeRepository>();
      await notice.recordSessionStarted('user-a');

      expect(await notice.unsentChangesCount(), 1);
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
        expect(events.single.failure, DatabaseKeyFailure.keyMissing);

        // Fresh, usable, and empty — the stale table is gone.
        final recovered = container.get<ServerDatabase>();
        final tables = await recovered
            .customSelect("SELECT name FROM sqlite_master WHERE name = 'probe'")
            .get();
        expect(tables, isEmpty);
      },
    );

    test('reports a key that does not open the file as a mismatch', () async {
      await makeInstaller().install(container, config);
      await container.dispose();
      keys.replaceServerKey(config.bgeServerId);

      final events = <DatabaseRecoveryEvent>[];
      await makeInstaller(onRecovery: events.add).install(container, config);

      expect(events.single.failure, DatabaseKeyFailure.keyMismatch);
    });

    // #428: a key that can't be read may still be there. Recovery would
    // delete it and the file it opens.
    test('a key store that cannot be reached is never recovered', () async {
      await makeInstaller().install(container, config);
      await container.dispose();
      keys.unavailable = true;

      final events = <DatabaseRecoveryEvent>[];
      await expectLater(
        makeInstaller(onRecovery: events.add).install(container, config),
        throwsA(isA<EncryptionKeyUnavailableError>()),
      );
      expect(events, isEmpty);
      expect(keys.deletedServerKeys, 0);
      expect(dbFile().existsSync(), isTrue);
    });

    // #428: once the file is gone, a retry finds nothing to recover, so a
    // reopen that fails must not take the report down with it.
    test('reports the loss even when the reopen fails, and only once '
        'across a retry', () async {
      await makeInstaller().install(container, config);
      await container.dispose();
      keys.loseServerKey(config.bgeServerId);
      keys.cannotCreate = true;

      final events = <DatabaseRecoveryEvent>[];
      await expectLater(
        makeInstaller(onRecovery: events.add).install(container, config),
        throwsA(isA<EncryptionKeyUnavailableError>()),
      );
      expect(events.single.failure, DatabaseKeyFailure.keyMissing);
      expect(dbFile().existsSync(), isFalse);

      keys.cannotCreate = false;
      await makeInstaller(onRecovery: events.add).install(container, config);

      expect(events, hasLength(1));
      expect(container.isRegistered<ServerDatabase>(), isTrue);
    });

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
        makeInstaller(overrideFactory: alwaysFailing)
            .install(container, config),
        throwsA(isA<DatabaseKeyError>()),
      );
      expect(container.isRegistered<ServerDatabase>(), isFalse);
    });
  });
}
