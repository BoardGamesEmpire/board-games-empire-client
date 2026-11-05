import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

/// #480: the per-server household member remote is the network installer's
/// to register, beside the household and invite remotes and for the same
/// reason: it shares the per-server Dio, which carries the base URL and the
/// session the member routes require. This suite pins its type, its identity
/// and the Dio it sends on.
void main() {
  late DependencyContainerImpl container;

  setUp(() {
    // The token interceptor reads the keychain before each request; the
    // plugin's own in-memory store stands in for it, empty, so requests go
    // out with no session.
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
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

  group('registerServerNetwork household member remote (#480)', () {
    test('registers the interface, not the implementation type', () {
      expect(container.isRegistered<HouseholdMemberRemoteDataSource>(), isTrue);
      expect(
        container.get<HouseholdMemberRemoteDataSource>(),
        isA<HouseholdMemberRemoteDataSourceImpl>(),
      );
      expect(
        container.isRegistered<HouseholdMemberRemoteDataSourceImpl>(),
        isFalse,
      );
    });

    test('resolves as one instance', () {
      expect(
        container.get<HouseholdMemberRemoteDataSource>(),
        same(container.get<HouseholdMemberRemoteDataSource>()),
      );
    });

    test('sends on the shared per-server Dio', () async {
      // The remote keeps its Dio private, so this checks it by what it
      // does: a request reaches the transport of the Dio the container
      // holds. A remote on a Dio of its own would miss it, and with it the
      // session the member routes require. The answer is the success case
      // of `household/household_member_remote_data_source_impl_test.dart`.
      final server = ScriptedServer()
        ..json('DELETE', '/api/households/h1/members/m1', {
          'message': 'translated',
          'member': {
            'id': 'm1',
            'userId': 'u1',
            'householdId': 'h1',
            'showAllGames': false,
            'createdAt': '2026-10-19T10:00:00.000Z',
            'updatedAt': '2026-10-26T10:00:00.000Z',
            'user': null,
            'role': {
              'id': 'hmr1',
              'role': {'id': 'r1', 'name': 'HouseholdMember'},
            },
          },
        });
      container.get<Dio>().httpClientAdapter = server;

      await container.get<HouseholdMemberRemoteDataSource>().remove('h1', 'm1');

      expect(
        server.requestsTo('DELETE', '/api/households/h1/members/m1'),
        hasLength(1),
      );
    });

    test('registers beside the household and invite remotes, not instead '
        'of them', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
      expect(container.isRegistered<HouseholdInviteRemoteDataSource>(), isTrue);
    });
  });
}
