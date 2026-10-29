import 'dart:async';
import 'dart:io';

import 'package:app_shell/app_shell.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:drift_storage/drift_storage_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';
import 'package:observability/observability.dart';
import 'package:storage_interface/storage_interface.dart';

class _MockServerRepository extends Mock implements ServerRepository {}

ServerConfig _serverConfig() => ServerConfig(
  id: 'server-local-1',
  displayName: 'Game Night Server',
  serverUrl: 'https://api.example.com',
  connectionState: ConnectionState.active,
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
  lastIdentityFetchedAt: DateTime.utc(2026, 10, 20),
);

class _MockDevicePreferencesRepository extends Mock
    implements DevicePreferencesRepository {}

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

/// In-memory key service that records whether the meta database file still
/// existed at the moment the meta key was deleted — proving the
/// key-before-file recovery ordering.
class _FakeEncryptionKeyService implements EncryptionKeyService {
  _FakeEncryptionKeyService({this.metaFileProbe});

  final File Function()? metaFileProbe;

  int deleteMetaKeyCalls = 0;
  bool? metaFileExistedWhenKeyDeleted;

  /// When set, [deleteMetaKey] waits on it after recording the call.
  Future<void>? deletingMetaKey;

  @override
  Future<String> getOrCreateServerKey(String serverId) async => 'a' * 64;

  @override
  Future<String> getOrCreateMetaKey() async => 'b' * 64;

  @override
  Future<String?> findServerKey(String serverId) async => 'a' * 64;

  @override
  Future<String?> findMetaKey() async => 'b' * 64;

  @override
  Future<void> deleteServerKey(String serverId) async {}

  @override
  Future<void> deleteMetaKey() async {
    deleteMetaKeyCalls++;
    metaFileExistedWhenKeyDeleted = metaFileProbe?.call().existsSync();
    await deletingMetaKey;
  }
}

/// Executor factory that bypasses encryption and the real filesystem:
/// the meta database runs in memory and the meta file resolves into a
/// test-owned temp directory.
class _TestExecutorFactory extends EncryptedExecutorFactory {
  _TestExecutorFactory({required super.keyService, required this.metaFile})
    : super(encryptionEnabled: false);

  final File metaFile;

  /// Every meta executor handed out, so tests can see which were closed.
  final List<_SpyExecutor> metaExecutors = [];

  /// When set, the next meta database open waits on it.
  Future<void>? metaOpening;

  /// How many upcoming server database opens fail as a missing key, which
  /// sends the storage installer through recovery.
  int serverOpensFailingAsKeyMissing = 0;

  @override
  QueryExecutor metaExecutor() {
    final executor = _SpyExecutor(opening: metaOpening);
    metaExecutors.add(executor);
    return executor;
  }

  @override
  QueryExecutor serverExecutor(
    String serverId, {
    String? relativeDatabasePath,
  }) {
    if (serverOpensFailingAsKeyMissing > 0) {
      serverOpensFailingAsKeyMissing--;
      throw DatabaseKeyError(
        databasePath: '/device/path/$serverId/game_empire.db',
        failure: DatabaseKeyFailure.keyMissing,
      );
    }
    return _SpyExecutor();
  }

  @override
  Future<File> resolveDatabaseFile(String relativePath) async => metaFile;
}

/// An in-memory executor that records whether it was closed, and whose
/// open can be held on [opening].
class _SpyExecutor extends LazyDatabase {
  _SpyExecutor({Future<void>? opening})
    : super(() async {
        await opening;
        return NativeDatabase.memory();
      });

  bool closed = false;

  @override
  Future<void> close() {
    closed = true;
    return super.close();
  }
}

void main() {
  late Directory tempDir;
  late File metaFile;
  late _FakeEncryptionKeyService keyService;
  late _TestExecutorFactory executorFactory;
  late _MockServerRepository serverRepository;
  late _MockDevicePreferencesRepository preferencesRepository;
  late _MockServerOrchestrator orchestrator;

  /// How many orchestrators the default factory has built.
  late int orchestratorsBuilt;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('native_bootstrap_test');
    metaFile = File('${tempDir.path}/servers.db');
    keyService = _FakeEncryptionKeyService(metaFileProbe: () => metaFile);
    executorFactory = _TestExecutorFactory(
      keyService: keyService,
      metaFile: metaFile,
    );
    serverRepository = _MockServerRepository();
    preferencesRepository = _MockDevicePreferencesRepository();
    orchestrator = _MockServerOrchestrator();
    orchestratorsBuilt = 0;
    when(() => orchestrator.initialize()).thenAnswer((_) async {});
    when(() => orchestrator.dispose()).thenAnswer((_) async {});
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  NativePlatformBootstrap buildBootstrap({
    NativeOrchestratorFactory? orchestratorFactory,
  }) => NativePlatformBootstrap(
    keyService: keyService,
    executorFactory: executorFactory,
    serverRepositoryFactory: (_) => serverRepository,
    devicePreferencesRepositoryFactory: (_) => preferencesRepository,
    orchestratorFactory:
        orchestratorFactory ??
        ({
          required ServerRepository serverRepository,
          required DevicePreferencesRepository preferencesRepository,
          required contextFactory,
        }) {
          orchestratorsBuilt++;
          return orchestrator;
        },
  );

  group('NativePlatformBootstrap', () {
    test('supportsReset is true on native platforms', () {
      expect(buildBootstrap().supportsReset, isTrue);
    });

    test('rejects an injected executorFactory without a matching keyService, '
        'guarding against divergent encryption-key services', () {
      expect(
        () => NativePlatformBootstrap(executorFactory: executorFactory),
        throwsA(isA<AssertionError>()),
      );
    });

    group('initialize()', () {
      test('reports no server for an empty registry and returns the '
          'initialized orchestrator', () async {
        when(() => serverRepository.getAllServers())
            .thenAnswer((_) async => const []);
        final bootstrap = buildBootstrap();

        final result = await bootstrap.initialize();

        expect(result.hasServer, isFalse);
        expect(result.orchestrator, same(orchestrator));
        expect(result.recoveredServers, isEmpty);
        verify(() => orchestrator.initialize()).called(1);

        await bootstrap.dispose();
      });

      test('reports a server when the registry is non-empty', () async {
        when(() => serverRepository.getAllServers())
            .thenAnswer((_) async => [_serverConfig()]);
        when(() => orchestrator.activeServerId).thenReturn('srv');
        final bootstrap = buildBootstrap();

        final result = await bootstrap.initialize();

        expect(result.hasServer, isTrue);
        await bootstrap.dispose();
      });

      test('fails with NoServerRestoredError when servers are saved but none '
          'is active (#217)', () async {
        when(() => serverRepository.getAllServers())
            .thenAnswer((_) async => [_serverConfig()]);
        when(() => orchestrator.activeServerId).thenReturn(null);
        final bootstrap = buildBootstrap();
        addTearDown(bootstrap.dispose);

        await expectLater(
          bootstrap.initialize(),
          throwsA(
            isA<NoServerRestoredError>().having(
              (e) => e.registeredCount,
              'registeredCount',
              1,
            ),
          ),
        );
        verify(() => orchestrator.dispose()).called(1);
      });

      test('the shell shows NoServerRestoredError as a failed boot, '
          'not the auth screen', () async {
        when(() => serverRepository.getAllServers())
            .thenAnswer((_) async => [_serverConfig()]);
        when(() => orchestrator.activeServerId).thenReturn(null);
        final bootstrap = buildBootstrap();
        addTearDown(bootstrap.dispose);
        final cubit = AppBootstrapCubit(
          platformBootstrap: bootstrap,
          hydratedStorageInitializer: (_) async {},
        );
        addTearDown(cubit.close);

        await cubit.initialize();

        expect(
          cubit.state,
          isA<AppBootstrapFailed>().having(
            (s) => s.error,
            'error',
            isA<NoServerRestoredError>(),
          ),
        );
      });

      test('a retry after NoServerRestoredError can succeed', () async {
        when(() => serverRepository.getAllServers())
            .thenAnswer((_) async => [_serverConfig()]);
        when(() => orchestrator.activeServerId).thenReturn(null);
        final bootstrap = buildBootstrap();
        addTearDown(bootstrap.dispose);

        await expectLater(
          bootstrap.initialize(),
          throwsA(isA<NoServerRestoredError>()),
        );
        when(() => orchestrator.activeServerId).thenReturn('srv');
        final result = await bootstrap.initialize();

        expect(result.hasServer, isTrue);
      });

      test('a failed attempt rethrows and a subsequent attempt can '
          'succeed (retry path)', () async {
        when(() => serverRepository.getAllServers())
            .thenAnswer((_) async => const []);
        var attempts = 0;
        final bootstrap = buildBootstrap(
          orchestratorFactory:
              ({
                required ServerRepository serverRepository,
                required DevicePreferencesRepository preferencesRepository,
                required contextFactory,
              }) {
                attempts++;
                if (attempts == 1) throw StateError('composition failed');
                return orchestrator;
              },
        );

        await expectLater(bootstrap.initialize(), throwsStateError);

        final result = await bootstrap.initialize();
        expect(result.hasServer, isFalse);
        verify(() => orchestrator.initialize()).called(1);

        await bootstrap.dispose();
      });
    });

    // #428: the shell tells the user about a database rebuilt during boot,
    // and the log keeps a breadcrumb without the on-device path. A rebuild
    // after boot is only logged.
    group('a rebuilt server database', () {
      final server = _serverConfig();

      /// An orchestrator whose initialize() activates [server] through the
      /// context factory the bootstrap composed, as the real one does, and
      /// then throws [failWith] if set.
      NativePlatformBootstrap buildActivating({Object? Function()? failWith}) {
        final contexts = <ServerContext>[];
        return buildBootstrap(
          orchestratorFactory:
              ({
                required ServerRepository serverRepository,
                required DevicePreferencesRepository preferencesRepository,
                required contextFactory,
              }) {
                final activating = _MockServerOrchestrator();
                when(() => activating.activeServerId).thenReturn(server.id);
                when(activating.initialize).thenAnswer((_) async {
                  final context = contextFactory(server);
                  contexts.add(context);
                  await context.activate();
                  final failure = failWith?.call();
                  if (failure != null) throw failure;
                });
                when(activating.dispose).thenAnswer((_) async {
                  for (final context in contexts) {
                    await context.dispose();
                  }
                  contexts.clear();
                });
                return activating;
              },
        );
      }

      setUp(() {
        when(() => serverRepository.getAllServers())
            .thenAnswer((_) async => [server]);
        when(() => orchestrator.activeServerId).thenReturn(server.id);
      });

      test('is returned to the shell', () async {
        executorFactory.serverOpensFailingAsKeyMissing = 1;
        final bootstrap = buildActivating();
        addTearDown(bootstrap.dispose);

        final result = await bootstrap.initialize();

        expect(result.recoveredServers, [server]);
      });

      test('is logged as a warning naming the server and the failure, '
          'never the path', () async {
        final records = <LogRecord>[];
        final previousLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        final subscription = Logger.root.onRecord.listen(records.add);
        addTearDown(() async {
          await subscription.cancel();
          Logger.root.level = previousLevel;
        });
        executorFactory.serverOpensFailingAsKeyMissing = 1;
        final bootstrap = buildActivating();
        addTearDown(bootstrap.dispose);

        await bootstrap.initialize();

        final warning = records.singleWhere(
          (r) =>
              r.loggerName == 'bge.platform.native_bootstrap' &&
              r.level == Level.WARNING,
        );
        expect((warning.object! as ContextLogMessage).context, {
          'bgeServerId': server.bgeServerId,
          'failure': 'keyMissing',
        });
        expect(warning.message, isNot(contains('/device/path')));
      });

      test('in an attempt that then failed is returned by the next attempt '
          'that succeeds', () async {
        executorFactory.serverOpensFailingAsKeyMissing = 1;
        var attempts = 0;
        final bootstrap = buildActivating(
          failWith: () => ++attempts == 1 ? StateError('later step') : null,
        );
        addTearDown(bootstrap.dispose);

        await expectLater(bootstrap.initialize(), throwsStateError);
        final result = await bootstrap.initialize();

        expect(result.recoveredServers, [server]);
      });

      test('is returned once, not again by a later attempt', () async {
        executorFactory.serverOpensFailingAsKeyMissing = 1;
        final bootstrap = buildActivating();
        addTearDown(bootstrap.dispose);

        await bootstrap.initialize();
        final again = await bootstrap.initialize();

        expect(again.recoveredServers, isEmpty);
      });

      test(
        'once a boot has succeeded is logged, and no later attempt returns it',
        () async {
          final records = <LogRecord>[];
          final previousLevel = Logger.root.level;
          Logger.root.level = Level.ALL;
          final subscription = Logger.root.onRecord.listen(records.add);
          addTearDown(() async {
            await subscription.cancel();
            Logger.root.level = previousLevel;
          });
          late ServerContext Function(ServerConfig config) bootContextFactory;
          final bootstrap = buildBootstrap(
            orchestratorFactory:
                ({
                  required ServerRepository serverRepository,
                  required DevicePreferencesRepository preferencesRepository,
                  required contextFactory,
                }) {
                  bootContextFactory = contextFactory;
                  return orchestrator;
                },
          );
          addTearDown(bootstrap.dispose);
          await bootstrap.initialize();

          // A server database opened after boot, through the factory the
          // boot composed, as reactivating a known server would (#134).
          executorFactory.serverOpensFailingAsKeyMissing = 1;
          final onboarded = bootContextFactory(server);
          await onboarded.activate();
          await onboarded.dispose();
          final again = await bootstrap.initialize();

          expect(
            records.where(
              (r) =>
                  r.loggerName == 'bge.platform.native_bootstrap' &&
                  r.level == Level.WARNING,
            ),
            hasLength(1),
          );
          expect(again.recoveredServers, isEmpty);
        },
      );
    });

    group('reset()', () {
      test('deletes the meta key before the meta database file and removes '
          'sqlite companion files', () async {
        metaFile.writeAsStringSync('db');
        final wal = File('${metaFile.path}-wal')..writeAsStringSync('wal');
        final shm = File('${metaFile.path}-shm')..writeAsStringSync('shm');

        await buildBootstrap().reset();

        expect(keyService.deleteMetaKeyCalls, 1);
        // Ordering proof: the file was still on disk when the key died.
        expect(keyService.metaFileExistedWhenKeyDeleted, isTrue);
        expect(metaFile.existsSync(), isFalse);
        expect(wal.existsSync(), isFalse);
        expect(shm.existsSync(), isFalse);
      });

      test('is safe when no meta database file exists yet', () async {
        await buildBootstrap().reset();

        expect(keyService.deleteMetaKeyCalls, 1);
        expect(metaFile.existsSync(), isFalse);
      });

      test('releases without ending the bootstrap: initialize() still '
          'works afterwards', () async {
        when(() => serverRepository.getAllServers())
            .thenAnswer((_) async => const []);
        final bootstrap = buildBootstrap();
        await bootstrap.initialize();

        await bootstrap.reset();

        final result = await bootstrap.initialize();
        expect(result.orchestrator, same(orchestrator));
        await bootstrap.dispose();
      });
    });

    // #384: dispose() is the shell's teardown seam. #226's exit hook grants
    // the exit when it returns, so "returned" has to mean "released".
    group('dispose()', () {
      setUp(() {
        when(() => serverRepository.getAllServers())
            .thenAnswer((_) async => const []);
      });

      test('closes the orchestrator and the meta database that '
          'initialize() opened', () async {
        final bootstrap = buildBootstrap();
        await bootstrap.initialize();

        await bootstrap.dispose();

        verify(() => orchestrator.dispose()).called(1);
        expect(executorFactory.metaExecutors.single.closed, isTrue);
      });

      test('a second caller waits for the teardown the first caller '
          'started', () async {
        final orchestratorClosing = Completer<void>();
        when(() => orchestrator.dispose())
            .thenAnswer((_) => orchestratorClosing.future);
        final bootstrap = buildBootstrap();
        await bootstrap.initialize();

        unawaited(bootstrap.dispose());
        var secondReturned = false;
        final second = bootstrap.dispose().then((_) => secondReturned = true);
        await pumpEventQueue();

        expect(
          secondReturned,
          isFalse,
          reason:
              'returning while the first caller is still closing would '
              'grant the exit mid-close — the #226 crash itself',
        );

        orchestratorClosing.complete();
        await second;
        verify(() => orchestrator.dispose()).called(1);
      });

      test('during reset(), waits for the reset to finish — the key and '
          'the files are both gone when it returns', () async {
        final deleting = Completer<void>();
        keyService.deletingMetaKey = deleting.future;
        metaFile.writeAsStringSync('db');
        final bootstrap = buildBootstrap();
        await bootstrap.initialize();

        final resetting = bootstrap.reset();
        await pumpEventQueue();
        var disposed = false;
        final disposal = bootstrap.dispose().then((_) => disposed = true);
        await pumpEventQueue();

        expect(
          disposed,
          isFalse,
          reason:
              'returning now would let the exit land between the key '
              'delete and the file delete',
        );

        deleting.complete();
        await resetting;
        await disposal;
        expect(metaFile.existsSync(), isFalse);
      });

      test('is terminal: initialize() afterwards throws and builds '
          'nothing', () async {
        final bootstrap = buildBootstrap();

        await bootstrap.dispose();

        await expectLater(bootstrap.initialize(), throwsStateError);
        expect(orchestratorsBuilt, 0);
      });

      test('is terminal: reset() afterwards throws and deletes '
          'nothing', () async {
        metaFile.writeAsStringSync('db');
        final bootstrap = buildBootstrap();

        await bootstrap.dispose();

        await expectLater(bootstrap.reset(), throwsStateError);
        expect(keyService.deleteMetaKeyCalls, 0);
        expect(metaFile.existsSync(), isTrue);
      });

      test('during initialize(), waits for the attempt — which releases '
          'what it built instead of committing it', () async {
        final orchestratorStarting = Completer<void>();
        when(() => orchestrator.initialize())
            .thenAnswer((_) => orchestratorStarting.future);
        final bootstrap = buildBootstrap();

        final attempt = bootstrap.initialize();
        await pumpEventQueue();
        var disposed = false;
        final disposal = bootstrap.dispose().then((_) => disposed = true);
        await pumpEventQueue();

        expect(
          disposed,
          isFalse,
          reason:
              'the attempt still holds an open meta database; returning '
              'now would let a quit from the splash screen exit with it '
              'open',
        );

        orchestratorStarting.complete();
        await expectLater(attempt, throwsStateError);
        await disposal;
        verify(() => orchestrator.dispose()).called(1);
        expect(executorFactory.metaExecutors.single.closed, isTrue);
      });

      test('during an attempt that restored no saved server, still makes '
          'the attempt throw StateError (#217)', () async {
        when(() => serverRepository.getAllServers())
            .thenAnswer((_) async => [_serverConfig()]);
        when(() => orchestrator.activeServerId).thenReturn(null);
        final orchestratorStarting = Completer<void>();
        when(() => orchestrator.initialize())
            .thenAnswer((_) => orchestratorStarting.future);
        final bootstrap = buildBootstrap();

        final attempt = bootstrap.initialize();
        await pumpEventQueue();
        final disposal = bootstrap.dispose();
        await pumpEventQueue();

        orchestratorStarting.complete();
        await expectLater(attempt, throwsStateError);
        await disposal;
      });

      test('during the meta database open, the attempt stops before it '
          'builds the orchestrator', () async {
        final metaOpening = Completer<void>();
        executorFactory.metaOpening = metaOpening.future;
        final bootstrap = buildBootstrap();

        final attempt = bootstrap.initialize();
        await pumpEventQueue();
        final disposal = bootstrap.dispose();
        metaOpening.complete();

        await expectLater(attempt, throwsStateError);
        await disposal;
        expect(
          orchestratorsBuilt,
          0,
          reason:
              'restoring every connected server only to close it again '
              'spends the exit deadline (#226)',
        );
        expect(executorFactory.metaExecutors.single.closed, isTrue);
      });
    });

    group('logging', () {
      test('a disposal failure during rollback is breadcrumbed as a '
          'warning while the original bootstrap error is rethrown '
          'unmasked', () async {
        final records = <LogRecord>[];
        final previousLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        final subscription = Logger.root.onRecord.listen(records.add);
        addTearDown(() async {
          await subscription.cancel();
          Logger.root.level = previousLevel;
        });

        final primaryError = StateError('orchestrator init failed');
        final secondaryError = StateError('dispose also failed');
        final failingOrchestrator = _MockServerOrchestrator();
        when(() => failingOrchestrator.initialize()).thenThrow(primaryError);
        when(() => failingOrchestrator.dispose()).thenThrow(secondaryError);
        final bootstrap = buildBootstrap(
          orchestratorFactory: ({
            required ServerRepository serverRepository,
            required DevicePreferencesRepository preferencesRepository,
            required contextFactory,
          }) => failingOrchestrator,
        );

        await expectLater(bootstrap.initialize(), throwsA(same(primaryError)));

        expect(
          records.where(
            (r) =>
                r.loggerName == 'bge.platform.native_bootstrap' &&
                r.level == Level.WARNING &&
                r.error == secondaryError,
          ),
          hasLength(1),
        );
      });
    });
  });
}
