import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

const _kAuthBase = '/api/auth';

ServerIdentity _identity() => ServerIdentity(
  serverId: 'bge-uuid-1',
  issuer: 'https://bge.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: const [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: '$_kAuthBase/sign-up/email',
    ),
  ],
);

ServerConfig _config() => ServerConfig(
  id: 'local-1',
  displayName: 'Test BGE Server',
  serverUrl: 'https://bge.example.com',
  connectionState: ConnectionState.active,
  bgeServerId: 'bge-uuid-1',
  cachedIdentity: _identity(),
  lastIdentityFetchedAt: DateTime.utc(2026),
);

/// #253: the per-server collection remote is the network installer's to
/// register, beside the household remote and for the same reason — it shares
/// the per-server Dio (base URL + the BetterAuth session
/// `/api/game-collections` requires) and adds no auth of its own.
void main() {
  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
    registerServerNetwork(container: container, config: _config());
  });

  tearDown(() async {
    await container.dispose();
  });

  group('registerServerNetwork collection remote (#253)', () {
    test('registers the interface, not the implementation type', () {
      expect(container.isRegistered<GameCollectionRemoteDataSource>(), isTrue);
      expect(
        container.get<GameCollectionRemoteDataSource>(),
        isA<GameCollectionRemoteDataSourceImpl>(),
      );
    });

    test('resolves as a singleton — the hydrate and the drain share one '
        'instance over the shared per-server Dio', () {
      expect(
        container.get<GameCollectionRemoteDataSource>(),
        same(container.get<GameCollectionRemoteDataSource>()),
      );
    });

    test('the shared Dio it requests through carries the server base URL', () {
      // The remote wraps the same per-server Dio singleton the installer
      // registered — verified through that Dio's configuration, since the
      // remote exposes no internals.
      expect(container.get<Dio>().options.baseUrl, 'https://bge.example.com');
    });

    test('the household remote is still registered alongside it', () {
      // The collection registration is additive: it must not displace the
      // remote that was already there.
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
    });
  });
}
