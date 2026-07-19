import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';
import 'package:web_network/src/orchestration/web_active_server_scope.dart';

const _kAuthBase = '/api/auth';

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

void main() {
  late DependencyContainerImpl container;
  late ActiveServer server;
  late WebActiveServerScope scope;

  setUp(() {
    container = DependencyContainerImpl();
    server = ActiveServer(
      serverId: 'server-uuid-1',
      displayName: 'Test BGE Server',
      identity: _identity(),
      container: container,
    );
    scope = WebActiveServerScope(server);
  });

  tearDown(() async {
    await container.dispose();
  });

  group('WebActiveServerScope', () {
    test('active exposes the fixed server (never null)', () {
      expect(scope.active, same(server));
    });

    test('watchActive replays the current value on subscribe', () async {
      await expectLater(scope.watchActive().first, completion(same(server)));
    });

    test('watchActive replays independently to each subscriber', () async {
      expect(await scope.watchActive().first, same(server));
      // A second, independent subscription also receives the replay.
      expect(await scope.watchActive().first, same(server));
    });

    test('watchActive emits once and stays open — never null, never '
        'completes', () async {
      final events = <ActiveServer?>[];
      var done = false;
      final sub = scope.watchActive().listen(
        events.add,
        onDone: () => done = true,
      );

      // Give the event queue time to deliver any (unexpected) further event
      // or a stream close.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, hasLength(1));
      expect(events.single, same(server));
      expect(done, isFalse);

      await sub.cancel();
    });
  });
}
