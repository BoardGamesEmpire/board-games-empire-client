import 'package:bge_test_support/domain.dart';
import 'package:di/di.dart';
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

/// #684: the staff households remote is the network installer's to register,
/// beside the DataGateway remote and for the same reason: it shares the
/// per-server Dio, which carries the base URL and the session
/// `/api/admin/households` requires.
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

  group('registerServerNetwork admin household remote (#684)', () {
    test(
      "registers an AdminHouseholdRemoteDataSource on the server's Dio",
      () {
        expect(
          container.isRegistered<AdminHouseholdRemoteDataSource>(),
          isTrue,
        );
        expect(
          container.get<AdminHouseholdRemoteDataSource>(),
          isA<AdminHouseholdRemoteDataSourceImpl>(),
        );
        expect(
          container.isRegistered<AdminHouseholdRemoteDataSourceImpl>(),
          isFalse,
        );
        expect(
          container.get<AdminHouseholdRemoteDataSource>(),
          same(container.get<AdminHouseholdRemoteDataSource>()),
        );
      },
    );

    test('registers beside the other remotes, not instead of them', () {
      expect(container.isRegistered<DataGatewayRemoteDataSource>(), isTrue);
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
    });
  });
}
