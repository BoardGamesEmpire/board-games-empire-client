import 'package:di/di.dart';
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

/// #42: the per-server games remote is the network installer's to register,
/// beside the other remotes and for the same reason: it shares the per-server
/// Dio, which carries the base URL and the session `/api/games` requires.
void main() {
  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
    registerServerNetwork(container: container, config: _config());
  });

  tearDown(() async {
    await container.dispose();
  });

  group('registerServerNetwork games remote (#42)', () {
    test('registers the interface, not the implementation type', () {
      expect(
        container.get<GamesRemoteDataSource>(),
        isA<GamesRemoteDataSourceImpl>(),
      );
      expect(container.isRegistered<GamesRemoteDataSourceImpl>(), isFalse);
    });

    test('resolves as one instance', () {
      // Requests are not sent here: this Dio's token interceptor reads secure
      // storage, which a unit test has none of. The web suite routes a
      // request through its registered Dio instead.
      expect(
        container.get<GamesRemoteDataSource>(),
        same(container.get<GamesRemoteDataSource>()),
      );
    });

    test('registers beside the other remotes, not instead of them', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
      expect(container.isRegistered<GameCollectionRemoteDataSource>(), isTrue);
      expect(container.isRegistered<DataGatewayRemoteDataSource>(), isTrue);
    });
  });
}
