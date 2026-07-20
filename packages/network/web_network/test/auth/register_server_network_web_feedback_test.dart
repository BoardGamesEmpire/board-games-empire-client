import 'package:di/di.dart';
import 'package:dio_network/dio_network.dart' show FeedbackDioTransport;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

import 'package:web_network/src/network/register_server_network_web.dart';

const _kAuthBase = '/api/auth';

// Same fixture rationale as register_server_network_web_test.dart: web
// has no persisted ServerConfig; the identity comes from the serving
// origin's well-known document.
ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
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

/// #97, web leg: the single-origin container carries the same
/// `FeedbackTransport` registration as native — the browser attaches the
/// httpOnly session cookie, so nothing web-specific is needed.
void main() {
  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
    registerServerNetworkWeb(
      container: container,
      identity: _identity(),
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
