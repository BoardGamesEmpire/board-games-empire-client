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

/// #807: the server settings and notification remotes are the network
/// installer's to register, beside the staff households remote and for the same
/// reason: they share the per-server Dio, which carries the base URL and the
/// session their routes require.
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

  group('registerServerNetwork server settings remotes (#807)', () {
    test('registers a SystemSettingsRemoteDataSource, as the interface', () {
      expect(
        container.get<SystemSettingsRemoteDataSource>(),
        isA<SystemSettingsRemoteDataSourceImpl>(),
      );
      expect(
        container.isRegistered<SystemSettingsRemoteDataSourceImpl>(),
        isFalse,
      );
    });

    test('registers a NotificationRemoteDataSource, as the interface', () {
      expect(
        container.get<NotificationRemoteDataSource>(),
        isA<NotificationRemoteDataSourceImpl>(),
      );
      expect(
        container.isRegistered<NotificationRemoteDataSourceImpl>(),
        isFalse,
      );
    });

    test('registers beside the other remotes, not instead of them', () {
      expect(container.isRegistered<AdminHouseholdRemoteDataSource>(), isTrue);
      expect(container.isRegistered<DataGatewayRemoteDataSource>(), isTrue);
    });
  });
}
