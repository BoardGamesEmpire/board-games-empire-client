import 'dart:io';

import 'package:app_shell/app_shell.dart';
import 'package:di/di.dart';
import 'package:dio_network/dio_network.dart';
import 'package:drift/drift.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:key_storage/key_storage.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';
import 'package:path_provider/path_provider.dart';
import 'package:storage_interface/storage_interface.dart';

import 'native_root_module.dart';

/// Builds the orchestrator; injectable so tests can substitute a fake.
typedef NativeOrchestratorFactory =
    ServerOrchestrator Function({
      required ServerRepository serverRepository,
      required DevicePreferencesRepository preferencesRepository,
      required ServerContextFactory contextFactory,
    });

/// Composes the real per-server [ServerContextFactory]: every context gets
/// the drift storage installer (encrypted DB open with one-shot
/// key-recovery) followed by the dio network installer. This is the
/// composition deferred from #14/#38 to the platform bootstrap (#31).
ServerContextFactory buildNativeServerContextFactory({
  required EncryptedExecutorFactory executorFactory,
  required EncryptionKeyService keyService,
  void Function(DatabaseRecoveryEvent event)? onRecovery,
}) {
  final installers = <ServerScopeInstaller>[
    StorageScopeInstaller(
      executorFactory: executorFactory,
      keyService: keyService,
      onRecovery: onRecovery,
    ),
    const NetworkScopeInstaller(),
  ];
  return (ServerConfig config) =>
      ServerContextImpl(config: config, installers: installers);
}

/// Shared native (mobile + desktop) [PlatformBootstrap]: opens the
/// encrypted MetaDB, builds the meta repositories, composes the real
/// context factory, and constructs + initializes the [ServerOrchestrator].
///
/// Every collaborator is injectable with a production default, keeping the
/// composition unit-testable without real keychains or filesystems.
class NativePlatformBootstrap implements PlatformBootstrap {
  NativePlatformBootstrap({
    EncryptionKeyService? keyService,
    EncryptedExecutorFactory? executorFactory,
    MetaDatabase Function(QueryExecutor executor)? metaDatabaseFactory,
    ServerRepository Function(MetaDatabase database)? serverRepositoryFactory,
    DevicePreferencesRepository Function(MetaDatabase database)?
    devicePreferencesRepositoryFactory,
    NativeOrchestratorFactory? orchestratorFactory,
    Future<HydratedStorageDirectory> Function()? hydratedDirectoryProvider,
    void Function(DatabaseRecoveryEvent event)? onServerDatabaseRecovery,
    Future<void> Function(DependencyContainer container)? rootModule,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.platform.native_bootstrap'),
       assert(
         executorFactory == null || keyService != null,
         'When injecting executorFactory you must also inject the same '
         'keyService it was built with: the MetaDB executor and the '
         'per-server storage installers must share one EncryptionKeyService, '
         'otherwise they key off different services and silently diverge.',
       ),
       _keyService =
           keyService ??
           SecureStorageEncryptionKeyService(
             storage: const FlutterSecureStorage(),
           ),
       _metaDatabaseFactory = metaDatabaseFactory ?? MetaDatabase.new,
       _serverRepositoryFactory =
           serverRepositoryFactory ?? ServerRepositoryImpl.new,
       _devicePreferencesRepositoryFactory =
           devicePreferencesRepositoryFactory ??
           DevicePreferencesRepositoryImpl.new,
       _orchestratorFactory = orchestratorFactory ?? _defaultOrchestrator,
       _hydratedDirectoryProvider =
           hydratedDirectoryProvider ?? _defaultHydratedDirectory,
       _onServerDatabaseRecovery = onServerDatabaseRecovery,
       _rootModule = rootModule ?? registerNativeRootModule {
    _executorFactory =
        executorFactory ?? EncryptedExecutorFactory(keyService: _keyService);
  }

  final BgeLogger _logger;
  final EncryptionKeyService _keyService;
  late final EncryptedExecutorFactory _executorFactory;
  final MetaDatabase Function(QueryExecutor executor) _metaDatabaseFactory;
  final ServerRepository Function(MetaDatabase database)
  _serverRepositoryFactory;
  final DevicePreferencesRepository Function(MetaDatabase database)
  _devicePreferencesRepositoryFactory;
  final NativeOrchestratorFactory _orchestratorFactory;
  final Future<HydratedStorageDirectory> Function() _hydratedDirectoryProvider;
  final void Function(DatabaseRecoveryEvent event)? _onServerDatabaseRecovery;
  final Future<void> Function(DependencyContainer container) _rootModule;

  MetaDatabase? _metaDatabase;
  ServerOrchestrator? _orchestrator;

  @override
  bool get supportsReset => true;

  /// Builds the native root container (#72): a fresh, isolated
  /// [DependencyContainerImpl] populated by the injected root module
  /// (production default: [registerNativeRootModule] — [BuildInfo] via a
  /// defensive, time-bounded plugin read, plus the durable
  /// [FeedbackSink]; #35, #69).
  ///
  /// Fresh per call, no shared global GetIt state — see the contract on
  /// [PlatformBootstrap.createRootContainer], including the no-throw
  /// requirement the default module honors per-registration.
  ///
  /// **Dispose-partial guard** (deferred from #74's review, landed with
  /// #69): a module that throws mid-population — a contract violation —
  /// would otherwise leak whatever it registered before the throw, since
  /// `runBgeApp` discards the container for its empty fallback. The
  /// partial container is disposed here first, then the violation
  /// propagates unchanged.
  @override
  Future<DependencyContainer> createRootContainer() async {
    final container = DependencyContainerImpl();
    try {
      await _rootModule(container);
    } on Object {
      try {
        await container.dispose();
      } on Object catch (error, stackTrace) {
        // Never mask the module's own failure — the original error is
        // the one runBgeApp must breadcrumb.
        _logger.warn(
          'Partial root container disposal failed after a module throw; '
          'original module error rethrown',
          error: error,
          stackTrace: stackTrace,
        );
      }
      rethrow;
    }
    return container;
  }

  @override
  Future<BootstrapResult> initialize() async {
    // Retry hygiene: release anything a previous failed attempt left open.
    await dispose();

    MetaDatabase? meta;
    ServerOrchestrator? orchestrator;
    try {
      meta = _metaDatabaseFactory(_executorFactory.metaExecutor());
      // Drift opens lazily; force the open now so key/cipher errors
      // (e.g. DatabaseKeyError) surface here, on the retryable error
      // path, instead of at an arbitrary later query.
      await meta.customSelect('SELECT 1').get();

      final serverRepository = _serverRepositoryFactory(meta);
      final preferencesRepository = _devicePreferencesRepositoryFactory(meta);

      orchestrator = _orchestratorFactory(
        serverRepository: serverRepository,
        preferencesRepository: preferencesRepository,
        contextFactory: buildNativeServerContextFactory(
          executorFactory: _executorFactory,
          keyService: _keyService,
          onRecovery: _onServerDatabaseRecovery,
        ),
      );
      await orchestrator.initialize();

      final servers = await serverRepository.getAllServers();

      // Commit state only on success (established orchestrator invariant).
      _metaDatabase = meta;
      _orchestrator = orchestrator;
      return BootstrapResult(
        hasServer: servers.isNotEmpty,
        orchestrator: orchestrator,
      );
    } catch (_) {
      // Roll back without masking the original error: secondary disposal
      // failures are logged as breadcrumbs for feedback reports, never
      // thrown — the bootstrap failure being rethrown is the one the
      // user (and the error screen) must see.
      if (orchestrator != null) {
        try {
          await orchestrator.dispose();
        } on Object catch (error, stackTrace) {
          _logger.warn(
            'Orchestrator disposal failed during bootstrap rollback; '
            'original bootstrap error rethrown',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      if (meta != null) {
        try {
          await meta.close();
        } on Object catch (error, stackTrace) {
          _logger.warn(
            'Meta database close failed during bootstrap rollback; '
            'original bootstrap error rethrown',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      rethrow;
    }
  }

  @override
  Future<void> reset() async {
    _logger.warn('Resetting device-local meta state (user confirmed)');
    await dispose();
    // Key first, then file — the recovery ordering established in
    // StorageScopeInstaller: a crash in between must not leave an
    // encrypted database whose key still exists and looks healthy.
    await _keyService.deleteMetaKey();
    final databaseFile = await _executorFactory.resolveDatabaseFile(
      EncryptedExecutorFactory.metaDatabaseRelativePath,
    );
    final companions = [
      databaseFile,
      File('${databaseFile.path}-wal'),
      File('${databaseFile.path}-shm'),
      File('${databaseFile.path}-journal'),
    ];
    for (final file in companions) {
      // Best-effort: the exists/delete window is a TOCTOU race (the
      // file may vanish or lock between the two calls), and a companion
      // that is already gone is success, not failure. Attempt the delete
      // and swallow FileSystemException — a genuinely undeletable file is
      // breadcrumbed rather than aborting the reset the user asked for.
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } on FileSystemException catch (error, stackTrace) {
        _logger.warn(
          'Best-effort delete of a meta database file failed during reset',
          error: error,
          stackTrace: stackTrace,
          context: {'path': file.path},
        );
      }
    }
    _logger.info('Device-local meta state reset complete');
  }

  @override
  Future<HydratedStorageDirectory> hydratedStorageDirectory() =>
      _hydratedDirectoryProvider();

  /// Releases the resources held by the current bootstrap, if any.
  /// Safe to call repeatedly; [initialize] calls it before each attempt.
  Future<void> dispose() async {
    final orchestrator = _orchestrator;
    _orchestrator = null;
    final meta = _metaDatabase;
    _metaDatabase = null;
    if (orchestrator != null) {
      try {
        await orchestrator.dispose();
      } on Object catch (error, stackTrace) {
        _logger.warn(
          'Orchestrator disposal failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (meta != null) {
      try {
        await meta.close();
      } on Object catch (error, stackTrace) {
        _logger.warn(
          'Meta database close failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  static ServerOrchestrator _defaultOrchestrator({
    required ServerRepository serverRepository,
    required DevicePreferencesRepository preferencesRepository,
    required ServerContextFactory contextFactory,
  }) => ServerOrchestratorImpl(
    serverRepository: serverRepository,
    preferencesRepository: preferencesRepository,
    contextFactory: contextFactory,
  );

  static Future<HydratedStorageDirectory> _defaultHydratedDirectory() async =>
      HydratedStorageDirectory((await getApplicationSupportDirectory()).path);
}
