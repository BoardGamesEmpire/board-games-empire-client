import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import 'support/orchestrator_test_fixtures.dart';

/// Pins `ServerOrchestrator.activeConfig` (#37): a connect-time
/// [ServerConfig] snapshot that commits in lockstep with `activeServerId`
/// and is removed in lockstep with the context on every teardown path.
void main() {
  setUpAll(() {
    registerFallbackValue(ConnectionState.disconnected);
  });

  late MockServerRepository repo;
  late MockDevicePreferencesRepository prefsRepo;
  late ServerOrchestratorImpl orchestrator;

  setUp(() {
    repo = MockServerRepository();
    prefsRepo = MockDevicePreferencesRepository();
    when(() => prefsRepo.get()).thenAnswer((_) async => DevicePreferences());
    when(() => repo.getConnectedServers()).thenAnswer((_) async => []);
    when(
      () => repo.updateConnectionState(
        serverId: any(named: 'serverId'),
        newState: any(named: 'newState'),
      ),
    ).thenAnswer(
      (inv) async =>
          testServerConfig(id: inv.namedArguments[#serverId] as String),
    );
    when(() => repo.updateLastActive(any(), any())).thenAnswer((_) async {});

    orchestrator = ServerOrchestratorImpl(
      serverRepository: repo,
      preferencesRepository: prefsRepo,
      contextFactory: (config) => mockServerContext(config.id),
      isDesktopOverride: true,
    );
  });

  tearDown(() async => orchestrator.dispose());

  void stubGetServer(String id) {
    when(
      () => repo.getServer(id),
    ).thenAnswer((_) async => testServerConfig(id: id));
  }

  group('activeConfig', () {
    test('null after initialize with no connected servers', () async {
      await orchestrator.initialize();
      expect(orchestrator.activeConfig, isNull);
    });

    test('reflects the connected active server', () async {
      await orchestrator.initialize();
      stubGetServer('server-a');

      await orchestrator.connectServer('server-a');

      final config = orchestrator.activeConfig;
      expect(config, isNotNull);
      expect(config!.id, 'server-a');
      expect(config.displayName, 'Server server-a');
      expect(config.id, orchestrator.activeServerId);
    });

    test('restored on initialize for a previously active server', () async {
      when(() => repo.getConnectedServers()).thenAnswer(
        (_) async => [
          testServerConfig(id: 'server-a', state: ConnectionState.active),
          testServerConfig(id: 'server-b', state: ConnectionState.monitoring),
        ],
      );

      await orchestrator.initialize();

      expect(orchestrator.activeConfig?.id, 'server-a');
    });

    test('follows switchActiveServer', () async {
      await orchestrator.initialize();
      stubGetServer('server-a');
      stubGetServer('server-b');
      await orchestrator.connectServer('server-a');
      await orchestrator.connectServer('server-b');
      expect(orchestrator.activeConfig?.id, 'server-a');

      await orchestrator.switchActiveServer('server-b');

      expect(orchestrator.activeConfig?.id, 'server-b');
    });

    test('null after disconnecting the sole active server', () async {
      await orchestrator.initialize();
      stubGetServer('server-a');
      await orchestrator.connectServer('server-a');

      await orchestrator.disconnectServer('server-a');

      expect(orchestrator.activeConfig, isNull);
    });

    test('follows the promoted server when the active one is '
        'disconnected', () async {
      await orchestrator.initialize();
      stubGetServer('server-a');
      stubGetServer('server-b');
      await orchestrator.connectServer('server-a');
      await orchestrator.connectServer('server-b');

      await orchestrator.disconnectServer('server-a');

      expect(orchestrator.activeConfig?.id, 'server-b');
    });

    test('no stale config after a failed onboarding activation '
        '(rollback path)', () async {
      final failingOrchestrator = ServerOrchestratorImpl(
        serverRepository: repo,
        preferencesRepository: prefsRepo,
        contextFactory: (config) {
          final ctx = mockServerContext(config.id);
          when(() => ctx.activate()).thenThrow(StateError('boom'));
          return ctx;
        },
        isDesktopOverride: true,
      );
      addTearDown(failingOrchestrator.dispose);
      await failingOrchestrator.initialize();

      final identity = testServerIdentity('new');
      registerFallbackValue(identity);
      when(
        () => repo.addServer(
          displayName: any(named: 'displayName'),
          serverUrl: any(named: 'serverUrl'),
          bgeServerId: any(named: 'bgeServerId'),
          identity: any(named: 'identity'),
        ),
      ).thenAnswer((_) async => testServerConfig(id: 'new'));
      when(() => repo.removeServer(any())).thenAnswer((_) async {});
      stubGetServer('new');

      await expectLater(
        failingOrchestrator.addAndActivateServer(
          displayName: 'My Server',
          serverUrl: 'https://bge.example.com',
          bgeServerId: 'bge-new',
          identity: identity,
        ),
        throwsA(isA<StateError>()),
      );

      expect(failingOrchestrator.activeConfig, isNull);
      expect(failingOrchestrator.activeServerId, isNull);
      expect(failingOrchestrator.currentConnectedCount, 0);
    });

    test('cleared on dispose', () async {
      await orchestrator.initialize();
      stubGetServer('server-a');
      await orchestrator.connectServer('server-a');
      expect(orchestrator.activeConfig, isNotNull);

      await orchestrator.dispose();

      expect(orchestrator.activeConfig, isNull);
    });
  });
}
