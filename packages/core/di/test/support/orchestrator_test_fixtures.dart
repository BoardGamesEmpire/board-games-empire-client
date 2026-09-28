import 'package:di/di.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

/// Shared fixtures for the orchestrator suites: the repository and context
/// mocks, the config and context builders, and [stubbedOrchestrator] for the
/// two suites that drive a real orchestrator end to end (#37, #102).

class MockServerRepository extends Mock implements ServerRepository {}

class MockDevicePreferencesRepository extends Mock
    implements DevicePreferencesRepository {}

class MockServerContext extends Mock implements ServerContext {}

ServerConfig testServerConfig({
  required String id,
  ConnectionState state = ConnectionState.disconnected,
}) => ServerConfig(
  id: id,
  displayName: 'Server $id',
  serverUrl: 'https://$id.example.com',
  connectionState: state,
  bgeServerId: 'bge-$id',
  cachedIdentity: testServerIdentity(id),
  lastIdentityFetchedAt: DateTime.now().toUtc(),
);

ServerIdentity testServerIdentity(String id) => ServerIdentity(
  serverId: 'bge-$id',
  issuer: 'https://$id.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '/api/auth/device',
  authBasePath: '/api/auth',
  sessionEndpoint: '/api/auth/get-session',
  signOutEndpoint: '/api/auth/sign-out',
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
);

/// A lifecycle-faithful [ServerContext] mock: state transitions mirror
/// the real contract so orchestrator paths (activate → background →
/// suspend) behave. [container] is stubbed when provided so
/// `ActiveServer.container` mapping can be asserted.
MockServerContext mockServerContext(
  String serverId, {
  DependencyContainer? container,
}) {
  final ctx = MockServerContext();
  when(() => ctx.serverId).thenReturn(serverId);
  when(() => ctx.config).thenReturn(testServerConfig(id: serverId));
  when(() => ctx.state).thenReturn(ServerContextState.initializing);
  if (container != null) {
    when(() => ctx.container).thenReturn(container);
  }
  when(() => ctx.activate()).thenAnswer((_) async {
    when(() => ctx.state).thenReturn(ServerContextState.active);
  });
  when(() => ctx.background()).thenAnswer((_) async {
    when(() => ctx.state).thenReturn(ServerContextState.backgrounding);
  });
  when(() => ctx.suspend()).thenAnswer((_) async {
    when(() => ctx.state).thenReturn(ServerContextState.monitoring);
  });
  when(() => ctx.dispose()).thenAnswer((_) async {
    when(() => ctx.state).thenReturn(ServerContextState.disposed);
  });
  when(() => ctx.watchState())
      .thenAnswer((_) => Stream.value(ServerContextState.active));
  return ctx;
}

/// A real [ServerOrchestratorImpl] over mocked repositories, stubbed for the
/// happy path: no connected servers, connection-state writes answer with a
/// [testServerConfig], and last-active writes succeed. Every context is a
/// [mockServerContext]; [withContainers] gives each a fresh real container,
/// for suites that assert on `ActiveServer.container`.
///
/// Callers register the `ConnectionState` fallback value (for the
/// `newState` matcher) in their own `setUpAll`, and dispose the orchestrator.
({
  MockServerRepository repo,
  MockDevicePreferencesRepository prefsRepo,
  ServerOrchestratorImpl orchestrator,
})
stubbedOrchestrator({bool withContainers = false}) {
  final repo = MockServerRepository();
  final prefsRepo = MockDevicePreferencesRepository();
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

  final orchestrator = ServerOrchestratorImpl(
    serverRepository: repo,
    preferencesRepository: prefsRepo,
    contextFactory: (config) => mockServerContext(
      config.id,
      container: withContainers ? DependencyContainerImpl() : null,
    ),
    isDesktopOverride: true,
  );
  return (repo: repo, prefsRepo: prefsRepo, orchestrator: orchestrator);
}
