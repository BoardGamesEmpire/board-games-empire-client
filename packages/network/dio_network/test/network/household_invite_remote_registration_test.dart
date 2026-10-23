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

/// #455: the per-server household invite remote is the network installer's
/// to register, beside the household remote and for the same reason: it
/// shares the per-server Dio, which carries the base URL and the session the
/// invite routes require.
void main() {
  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
    registerServerNetwork(container: container, config: _config());
  });

  tearDown(() async {
    await container.dispose();
  });

  group('registerServerNetwork household invite remote (#455)', () {
    test('registers the interface, not the implementation type', () {
      expect(container.isRegistered<HouseholdInviteRemoteDataSource>(), isTrue);
      expect(
        container.get<HouseholdInviteRemoteDataSource>(),
        isA<HouseholdInviteRemoteDataSourceImpl>(),
      );
      expect(
        container.isRegistered<HouseholdInviteRemoteDataSourceImpl>(),
        isFalse,
      );
    });

    test('resolves as one instance over the shared per-server Dio', () {
      expect(
        container.get<HouseholdInviteRemoteDataSource>(),
        same(container.get<HouseholdInviteRemoteDataSource>()),
      );
      expect(container.get<Dio>().options.baseUrl, 'https://bge.example.com');
    });

    test('registers beside the household remote, not instead of it', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
    });
  });
}
