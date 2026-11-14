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

/// #547: the per-server profile remote is the network installer's to
/// register, beside the user remote and for the same reason: it shares the
/// per-server Dio, which carries the base URL and the session
/// `/api/users/me/profile` requires.
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

  group('registerServerNetwork profile remote (#547)', () {
    test('registers the interface, not the implementation type', () {
      expect(container.isRegistered<UserProfileRemoteDataSource>(), isTrue);
      expect(
        container.get<UserProfileRemoteDataSource>(),
        isA<UserProfileRemoteDataSourceImpl>(),
      );
      expect(
        container.isRegistered<UserProfileRemoteDataSourceImpl>(),
        isFalse,
      );
    });

    test('resolves as one instance over the shared per-server Dio', () {
      expect(
        container.get<UserProfileRemoteDataSource>(),
        same(container.get<UserProfileRemoteDataSource>()),
      );
      expect(container.get<Dio>().options.baseUrl, 'https://bge.example.com');
    });
  });
}
