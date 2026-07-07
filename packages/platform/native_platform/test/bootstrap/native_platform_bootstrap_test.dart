import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';

class _MockServerRepository extends Mock implements ServerRepository {}

class _MockDevicePreferencesRepository extends Mock
    implements DevicePreferencesRepository {}

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

class _MockServerConfig extends Mock implements ServerConfig {}

/// In-memory key service that records whether the meta database file still
/// existed at the moment the meta key was deleted — proving the
/// key-before-file recovery ordering.
class _FakeEncryptionKeyService implements EncryptionKeyService {
  _FakeEncryptionKeyService({this.metaFileProbe});

  final File Function()? metaFileProbe;

  int deleteMetaKeyCalls = 0;
  bool? metaFileExistedWhenKeyDeleted;

  @override
  Future<String> getOrCreateServerKey(String serverId) async => 'a' * 64;

  @override
  Future<String> getOrCreateMetaKey() async => 'b' * 64;

  @override
  Future<void> deleteServerKey(String serverId) async {}

  @override
  Future<void> deleteMetaKey() async {
    deleteMetaKeyCalls++;
    metaFileExistedWhenKeyDeleted = metaFileProbe?.call().existsSync();
  }
}

/// Executor factory that bypasses encryption and the real filesystem:
/// the meta database runs in memory and the meta file resolves into a
/// test-owned temp directory.
class _TestExecutorFactory extends EncryptedExecutorFactory {
  _TestExecutorFactory({required super.keyService, required this.metaFile})
    : super(encryptionEnabled: false);

  final File metaFile;

  @override
  QueryExecutor metaExecutor() => NativeDatabase.memory();

  @override
  Future<File> resolveDatabaseFile(String relativePath) async => metaFile;
}

void main() {
  late Directory tempDir;
  late File metaFile;
  late _FakeEncryptionKeyService keyService;
  late _TestExecutorFactory executorFactory;
  late _MockServerRepository serverRepository;
  late _MockDevicePreferencesRepository preferencesRepository;
  late _MockServerOrchestrator orchestrator;

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
        }) => orchestrator,
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
        when(
          () => serverRepository.getAllServers(),
        ).thenAnswer((_) async => const []);
        final bootstrap = buildBootstrap();

        final result = await bootstrap.initialize();

        expect(result.hasServer, isFalse);
        expect(result.orchestrator, same(orchestrator));
        verify(() => orchestrator.initialize()).called(1);

        await bootstrap.dispose();
      });

      test('reports a server when the registry is non-empty', () async {
        when(
          () => serverRepository.getAllServers(),
        ).thenAnswer((_) async => [_MockServerConfig()]);
        final bootstrap = buildBootstrap();

        final result = await bootstrap.initialize();

        expect(result.hasServer, isTrue);
        await bootstrap.dispose();
      });

      test('a failed attempt rethrows and a subsequent attempt can '
          'succeed (retry path)', () async {
        when(
          () => serverRepository.getAllServers(),
        ).thenAnswer((_) async => const []);
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
          orchestratorFactory:
              ({
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
