import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

/// Shared fixtures for the #37 orchestration tests
/// (`orchestrator_active_server_scope_test.dart`,
/// `server_orchestrator_active_config_test.dart`).
///
/// Mirrors the inline helpers of `server_orchestrator_impl_test.dart`
/// (deliberately left untouched); a later consolidation can fold that
/// file onto these.

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
  when(
    () => ctx.watchState(),
  ).thenAnswer((_) => Stream.value(ServerContextState.active));
  return ctx;
}
