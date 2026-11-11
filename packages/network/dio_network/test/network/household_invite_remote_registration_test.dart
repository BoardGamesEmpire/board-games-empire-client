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

/// #455: the per-server household invite remote is the network installer's
/// to register, beside the household remote and for the same reason: it
/// shares the per-server Dio, which carries the base URL and the session the
/// invite routes require.
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
