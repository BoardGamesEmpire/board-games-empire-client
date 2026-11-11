import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/in_memory_session_tombstone_store.dart';

ServerIdentity _identity() =>
    testServerIdentity().copyWith(serverId: 'bge-uuid-1');

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
/// one pins its type, its identity and the Dio it sends on.
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

  group('registerServerNetwork household remote (#262)', () {
    test('registers the interface, not the implementation type', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
      expect(
        container.get<HouseholdRemoteDataSource>(),
        isA<HouseholdRemoteDataSourceImpl>(),
      );
      expect(container.isRegistered<HouseholdRemoteDataSourceImpl>(), isFalse);
    });

    test('resolves as one instance', () {
      expect(
        container.get<HouseholdRemoteDataSource>(),
        same(container.get<HouseholdRemoteDataSource>()),
      );
    });

    test('sends on the shared per-server Dio', () async {
      // The remote keeps its Dio private, so this checks it by what it
      // does: a request reaches the transport of the Dio the container
      // holds. A remote on a Dio of its own would miss it, and with it the
      // session the household routes require.
      final server = ScriptedServer()
        ..json('GET', '/api/households', {
          'households': <Object?>[],
          'pagination': {
            'page': 1,
            'limit': 100,
            'total': 0,
            'totalPages': 0,
            'hasMore': false,
          },
        });
      container.get<Dio>().httpClientAdapter = server;

      await container.get<HouseholdRemoteDataSource>().fetchHouseholds();

      expect(server.requestsTo('GET', '/api/households'), hasLength(1));
    });

    test('registers beside the other remotes, not instead of them', () {
      expect(container.isRegistered<HouseholdInviteRemoteDataSource>(), isTrue);
      expect(container.isRegistered<HouseholdMemberRemoteDataSource>(), isTrue);
      expect(container.isRegistered<GameCollectionRemoteDataSource>(), isTrue);
    });
  });
}
