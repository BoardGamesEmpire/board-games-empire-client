import 'package:di/di.dart';
import 'package:dio_network/src/games/game_search_channel_impl.dart';
import 'package:dio_network/src/realtime/realtime_connection_impl.dart';
import 'package:dio_network/src/realtime/realtime_endpoint.dart';
import 'package:dio_network/src/realtime/realtime_installer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_socket_manager.dart';

const _server = ScopedServer(serverId: 'bge-uuid-1', displayName: 'Server');

/// Counts the rejected sessions reported to it (#484).
class _FakeSessionRejectionSignal implements SessionRejectionSignal {
  int reports = 0;

  @override
  Future<void> report() async {
    reports += 1;
  }
}

/// #473: the session's socket connection is the user scope's, built from the
/// server scope's endpoint. Run through the real user-scope view, whose
/// lookups fall through to the server scope, as sign-in runs it.
void main() {
  late DependencyContainerImpl serverScope;
  late UserScopeHost session;
  late FakeSocketManagerFactory factory;

  setUp(() {
    serverScope = DependencyContainerImpl();
    session = UserScopeHost(parent: () => serverScope);
    factory = FakeSocketManagerFactory();
  });

  tearDown(() async {
    await session.close();
    await serverScope.dispose();
  });

  Future<void> signIn() => session.open(
    (view) => RealtimeInstaller(
      managerFactory: factory.call,
    ).install(view, _server, 'user-1'),
  );

  test('registers a connection when the server has an endpoint', () async {
    final endpoint = RealtimeEndpoint(server: Uri.parse('https://h.test'));
    serverScope.registerSingleton<RealtimeEndpoint>(endpoint);

    await signIn();

    final connection = session.maybeGet<RealtimeConnection>();
    expect(connection, isA<RealtimeConnectionImpl>());
    expect(
      serverScope.isRegistered<RealtimeConnection>(),
      isFalse,
      reason: 'the session owns it, not the server',
    );
    expect(factory.managers, isEmpty, reason: 'the first lease connects');

    connection!.lease('games/search');

    expect(factory.managers.single.endpoint, same(endpoint));
  });

  test('registers a games search source beside the connection', () async {
    serverScope.registerSingleton<RealtimeEndpoint>(
      RealtimeEndpoint(server: Uri.parse('https://h.test')),
    );

    await signIn();

    final source = session.maybeGet<GameSearchStreamSource>();
    expect(source, isA<GameSearchStreamSourceImpl>());
    expect(
      serverScope.isRegistered<GameSearchStreamSource>(),
      isFalse,
      reason: "the session's, as its connection is",
    );
    expect(factory.managers, isEmpty, reason: 'opening a channel connects');

    final channel = source!.open();
    // A lease on the session's connection shares the channel's socket.
    session.maybeGet<RealtimeConnection>()!.lease('games/search');

    final socket = factory.managers.single.sockets.single;
    expect(socket.namespace, '/games/search');

    await channel.close();

    expect(socket.disposed, isFalse, reason: 'the other lease still holds it');
  });

  test(
    'passes the registered SessionRejectionSignal to the search source',
    () async {
      // The server scope holds the signal; the source is the session's, and
      // finds it through the user-scope view (#484).
      final signal = _FakeSessionRejectionSignal();
      serverScope
        ..registerSingleton<RealtimeEndpoint>(
          RealtimeEndpoint(server: Uri.parse('https://h.test')),
        )
        ..registerSingleton<SessionRejectionSignal>(signal);
      await signIn();
      final channel = session.maybeGet<GameSearchStreamSource>()!.open();
      addTearDown(channel.close);
      final errors = <Object>[];
      channel.search('catan').listen(null, onError: errors.add);
      final socket = factory.managers.single.sockets.single..accept();
      await pumpEventQueue();

      socket.hear('auth:error', {
        'statusCode': 401,
        'error': 'Unauthorized',
        'message': 'Your session is invalid',
        'pattern': 'search:start',
      });
      await pumpEventQueue();

      expect(signal.reports, 1);
      expect(errors.single, isA<GamesRemoteTransientException>());
    },
  );

  test('the session ending closes its connection', () async {
    serverScope.registerSingleton<RealtimeEndpoint>(
      RealtimeEndpoint(server: Uri.parse('https://h.test')),
    );
    await signIn();
    final connection = session.maybeGet<RealtimeConnection>()!
      ..lease('games/search');

    await session.close();

    expect(factory.managers.single.closed, isTrue);
    expect(() => connection.lease('games/search'), throwsStateError);
  });

  test('registers nothing without one', () async {
    await signIn();

    expect(session.scopeHasRegistration<RealtimeConnection>(), isFalse);
    expect(session.scopeHasRegistration<GameSearchStreamSource>(), isFalse);
    expect(factory.managers, isEmpty);
  });
}
