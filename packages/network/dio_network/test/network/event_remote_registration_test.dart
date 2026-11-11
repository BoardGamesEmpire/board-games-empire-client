import 'package:bge_test_support/domain.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
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

/// #496: the per-server event remote is the network installer's to register,
/// beside the household, collection and DataGateway remotes and for the same
/// reason: it shares the per-server Dio, which carries the base URL and the
/// session `/api/events` requires.
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

  group('registerServerNetwork event remote (#496)', () {
    test('registers the interface, not the implementation type', () {
      expect(container.isRegistered<EventRemoteDataSource>(), isTrue);
      expect(
        container.get<EventRemoteDataSource>(),
        isA<EventRemoteDataSourceImpl>(),
      );
      expect(container.isRegistered<EventRemoteDataSourceImpl>(), isFalse);
    });

    test('resolves as one instance over the shared per-server Dio', () {
      // Requests are not sent here: this Dio's token interceptor reads secure
      // storage, which a unit test has none of. The web suite routes a
      // request through its registered Dio instead.
      expect(
        container.get<EventRemoteDataSource>(),
        same(container.get<EventRemoteDataSource>()),
      );
      expect(container.get<Dio>().options.baseUrl, 'https://bge.example.com');
    });

    test('registers beside the other remotes, not instead of them', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
      expect(container.isRegistered<GameCollectionRemoteDataSource>(), isTrue);
      expect(container.isRegistered<DataGatewayRemoteDataSource>(), isTrue);
    });
  });
}
