import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

ServerConfig _makeConfig() => ServerConfig(
  id: 'server-local-1',
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
  late DependencyContainerImpl container;

  setUp(() => container = DependencyContainerImpl());

  tearDown(() => container.dispose());

  group('NetworkScopeInstaller', () {
    test('registers the full network stack for the scope', () async {
      await const NetworkScopeInstaller().install(container, _makeConfig());

      expect(container.isRegistered<TokenStorageService>(), isTrue);
      expect(container.isRegistered<DioFactory>(), isTrue);
      expect(container.isRegistered<Dio>(), isTrue);
      expect(container.isRegistered<AuthRepository>(), isTrue);
    });

    test('shared Dio uses the config server URL as base', () async {
      await const NetworkScopeInstaller().install(container, _makeConfig());

      expect(container.get<Dio>().options.baseUrl, 'https://api.example.com');
    });

    test('is registration-equivalent to registerServerNetwork', () async {
      // Guard against the adapter drifting from the function it wraps.
      final direct = DependencyContainerImpl();
      addTearDown(direct.dispose);
      registerServerNetwork(container: direct, config: _makeConfig());

      await const NetworkScopeInstaller().install(container, _makeConfig());

      expect(
        container.isRegistered<TokenStorageService>(),
        direct.isRegistered<TokenStorageService>(),
      );
      expect(
        container.isRegistered<DioFactory>(),
        direct.isRegistered<DioFactory>(),
      );
      expect(container.isRegistered<Dio>(), direct.isRegistered<Dio>());
      expect(
        container.isRegistered<AuthRepository>(),
        direct.isRegistered<AuthRepository>(),
      );
    });
  });
}
