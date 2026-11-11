import 'package:bge_test_support/domain.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

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

/// #97: the per-server `FeedbackTransport` is the network installer's to
/// register — it shares the per-server Dio (base URL + BetterAuth
/// session attachment), so the active server's container can vend it to
/// the feedback target resolver.
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

  group('registerServerNetwork feedback transport (#97)', () {
    test('registers a FeedbackDioTransport as the FeedbackTransport', () {
      expect(container.isRegistered<FeedbackTransport>(), isTrue);
      expect(container.get<FeedbackTransport>(), isA<FeedbackDioTransport>());
    });

    test('resolves as a singleton — the drain and every submit share one '
        'instance over the shared per-server Dio', () {
      expect(
        container.get<FeedbackTransport>(),
        same(container.get<FeedbackTransport>()),
      );
    });

    test('the shared Dio it posts through carries the server base '
        'URL', () {
      // The transport wraps the same per-server Dio singleton the
      // installer registered — verified indirectly via that Dio's
      // configuration, since the transport exposes no internals.
      expect(container.get<Dio>().options.baseUrl, 'https://bge.example.com');
    });
  });
}
