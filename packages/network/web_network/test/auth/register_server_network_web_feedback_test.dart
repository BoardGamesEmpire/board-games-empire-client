import 'package:di/di.dart';
import 'package:dio_network/dio_network.dart' show FeedbackDioTransport;
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

import 'package:web_network/src/network/register_server_network_web.dart';

import '../support/server_identity_fixture.dart';

/// #97, web leg: the single-origin container carries the same
/// `FeedbackTransport` registration as native — the browser attaches the
/// httpOnly session cookie, so nothing web-specific is needed.
void main() {
  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
    registerServerNetworkWeb(
      container: container,
      identity: testServerIdentity(),
      originProvider: () => 'https://bge.example.com',
    );
  });

  tearDown(() async {
    await container.dispose();
  });

  group('registerServerNetworkWeb feedback transport (#97)', () {
    test('registers a FeedbackDioTransport as the FeedbackTransport', () {
      expect(container.isRegistered<FeedbackTransport>(), isTrue);
      expect(container.get<FeedbackTransport>(), isA<FeedbackDioTransport>());
    });

    test('resolves as a singleton', () {
      expect(
        container.get<FeedbackTransport>(),
        same(container.get<FeedbackTransport>()),
      );
    });
  });
}
