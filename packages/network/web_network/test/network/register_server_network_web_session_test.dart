import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart' show SessionIdentityGuard;

import 'package:web_network/src/auth/session_channel.dart';
import 'package:web_network/src/auth/web_session_monitor.dart';
import 'package:web_network/src/network/register_server_network_web.dart';

import '../support/fake_session_channel.dart';
import '../support/server_identity_fixture.dart';

/// How the network registration composes the session monitor (#432).
void main() {
  late DependencyContainerImpl container;
  late List<FakeSessionChannel> opened;

  setUp(() {
    container = DependencyContainerImpl();
    opened = [];
  });

  tearDown(() async => container.dispose());

  void register({bool withBindings = true}) => registerServerNetworkWeb(
    container: container,
    identity: testServerIdentity(),
    originProvider: () => 'https://bge.example.com',
    sessionBindings: withBindings
        ? WebSessionBindings(
            openChannel: (name) {
              final channel = FakeSessionChannel(name);
              opened.add(channel);
              return channel;
            },
            attention: () => const Stream<void>.empty(),
          )
        : null,
  );

  test('registers the monitor as the session identity guard, over a channel '
      'named for the server', () {
    register();

    expect(container.get<SessionIdentityGuard>(), isA<WebSessionMonitor>());
    expect(opened.map((c) => c.name), ['bge.session.server-uuid-1']);
  });

  // A tab on the sign-in screen has no user scope, so nothing has resolved
  // the guard yet. It still has to hear another tab sign in, and its own
  // sign-in has to reach the others.
  test('listens from registration, before anything resolves the guard', () {
    register();

    expect(opened, hasLength(1));
  });

  test('registers no guard without the browser bindings, so callers read '
      'every session as confirmed', () {
    register(withBindings: false);

    expect(container.isRegistered<SessionIdentityGuard>(), isFalse);
  });

  test('closes the channel when the scope is disposed', () async {
    register();

    await container.dispose();

    expect(opened.single.closed, isTrue);
  });
}
