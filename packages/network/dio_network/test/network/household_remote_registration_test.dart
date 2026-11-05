import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/in_memory_session_tombstone_store.dart';

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

/// #39, #262: the per-server household remote is the network installer's to
/// register, not a feature's: it shares the per-server Dio, which carries the
/// base URL and the BetterAuth session the `/api/households` routes require,
/// and adds no auth of its own. Other suites only touch it in passing; this
/// one pins its type and identity.
void main() {
  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
    registerServerNetwork(
      container: container,
      config: _config(),
      sessionTombstones: InMemorySessionTombstoneStore(),
    );
  });

  tearDown(() async {
    await container.dispose();
  });

  group('registerServerNetwork household remote (#262)', () {
    test('registers the interface, not the implementation type', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
      expect(
        container.get<HouseholdRemoteDataSource>(),
        isA<HouseholdRemoteDataSourceImpl>(),
      );
      expect(container.isRegistered<HouseholdRemoteDataSourceImpl>(), isFalse);
    });

    test('resolves as one instance over the shared per-server Dio', () {
      expect(
        container.get<HouseholdRemoteDataSource>(),
        same(container.get<HouseholdRemoteDataSource>()),
      );
      // The remote exposes no internals, so identity with the Dio cannot be
      // asserted; the base URL is the observable sign that it is the
      // per-server one.
      expect(container.get<Dio>().options.baseUrl, 'https://bge.example.com');
    });

    test('registers beside the other remotes, not instead of them', () {
      expect(container.isRegistered<HouseholdInviteRemoteDataSource>(), isTrue);
      expect(container.isRegistered<HouseholdMemberRemoteDataSource>(), isTrue);
      expect(container.isRegistered<GameCollectionRemoteDataSource>(), isTrue);
    });
  });
}
