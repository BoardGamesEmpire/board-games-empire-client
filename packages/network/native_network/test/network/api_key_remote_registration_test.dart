import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:native_network/native_network.dart';
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

/// #1028: the per-server API key remote is the network installer's to
/// register, beside the household remotes and for the same reason: it shares
/// the per-server Dio, which carries the base URL and the session the
/// `/api/api-keys` routes require.
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

  group('registerServerNetwork API key remote (#1028)', () {
    test('registers the interface, not the implementation type', () {
      expect(container.isRegistered<ApiKeyRemoteDataSource>(), isTrue);
      expect(
        container.get<ApiKeyRemoteDataSource>(),
        isA<ApiKeyRemoteDataSourceImpl>(),
      );
      expect(container.isRegistered<ApiKeyRemoteDataSourceImpl>(), isFalse);
    });

    test('resolves as one instance over the shared per-server Dio', () {
      expect(
        container.get<ApiKeyRemoteDataSource>(),
        same(container.get<ApiKeyRemoteDataSource>()),
      );
      expect(container.get<Dio>().options.baseUrl, 'https://bge.example.com');
    });

    test('registers beside the household remote, not instead of it', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
    });

    test('sends on the shared per-server Dio', () async {
      // The remote keeps its Dio private, so this checks it by what it does:
      // a request reaches the transport of the Dio the container holds. A
      // remote on a Dio of its own would miss it, and with it the session the
      // API key routes require.
      final server = ScriptedServer()
        ..json('GET', '/api/api-keys/grantable', {
          'permissions': [
            {
              'slug': 'read:game',
              'description': 'See games',
              'riskLevel': 'Low',
              'pinnable': true,
            },
          ],
        });
      container.get<Dio>().httpClientAdapter = server;

      final permissions = await container
          .get<ApiKeyRemoteDataSource>()
          .fetchGrantable();

      expect(server.requestsTo('GET', '/api/api-keys/grantable'), hasLength(1));
      expect(permissions.single.riskLevel, RiskLevel.low);
    });
  });
}
