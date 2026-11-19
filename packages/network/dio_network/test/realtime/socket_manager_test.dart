import 'package:dio_network/src/realtime/realtime_connection_impl.dart';
import 'package:dio_network/src/realtime/realtime_endpoint.dart';
import 'package:dio_network/src/realtime/socket_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_socket_io_server.dart';

/// How long a wire test waits on a connect before failing, rather than
/// hanging.
const _wire = Duration(seconds: 10);

/// #473: the socket.io adapter, through its options and then on the wire,
/// against a small in-process socket.io server and the real client.
void main() {
  group('socketIoOptions', () {
    Map<String, dynamic> optionsFor(String server) =>
        socketIoOptions(RealtimeEndpoint(server: Uri.parse(server)));

    test("socket path follows the server URL's path", () {
      expect(optionsFor('https://h.test/bge/')['path'], '/bge/socket.io');
      expect(optionsFor('https://h.test/bge')['path'], '/bge/socket.io');
      expect(optionsFor('https://h.test')['path'], '/socket.io');
      expect(optionsFor('https://h.test/')['path'], '/socket.io');
    });

    test(
      'WebSocket alone, connecting on the first lease, and reconnecting',
      () {
        final options = optionsFor('https://h.test');

        expect(options['transports'], ['websocket']);
        expect(options['autoConnect'], isFalse);
        // socket.io reconnects unless told `reconnection: false`.
        expect(options['reconnection'], isNot(false));
      },
    );
  });

  group('on the wire', () {
    late FakeSocketIoServer server;
    final connections = <RealtimeConnection>[];

    setUp(() async {
      server = await FakeSocketIoServer.start(path: '/bge/socket.io/');
    });

    tearDown(() async {
      for (final connection in connections) {
        await connection.close();
      }
      connections.clear();
      await server.close();
    });

    /// A connection over the real socket.io adapter, to the server under
    /// `/bge`.
    RealtimeConnection connectionTo({Future<String?> Function()? token}) {
      final connection = RealtimeConnectionImpl(
        endpoint: RealtimeEndpoint(server: server.url('/bge'), token: token),
      );
      connections.add(connection);
      return connection;
    }

    test(
      'a server under a path prefix is reached at its socket.io path, on the '
      'namespace',
      () async {
        final lease = connectionTo(
          token: () async => 't1',
        ).lease('games/search');

        await lease.ready(timeout: _wire);

        expect(server.missed, isEmpty);
        final connect = server.connects.single;
        expect(connect.namespace, '/games/search');
        expect(connect.auth, {'token': 't1'});
      },
    );

    // The app keeps every record but socket.io's packet records, which it
    // drops by their loggers' names (`ShellObservability.keeps`). This holds
    // those names to what socket.io logs the token from.
    test(
      'the token is logged only below INFO by socket.io, from its own '
      'loggers',
      () async {
        const token = 'sentinel-session-token';
        final previous = Logger.root.level;
        Logger.root.level = Level.ALL;
        addTearDown(() => Logger.root.level = previous);
        final records = <LogRecord>[];
        final listening = Logger.root.onRecord.listen(records.add);
        addTearDown(listening.cancel);

        await connectionTo(
          token: () async => token,
        ).lease('games/search').ready(timeout: _wire);

        expect(server.connects.single.auth, {'token': token});
        final withToken = [
          for (final record in records)
            if (record.message.contains(token)) record,
        ];
        expect(
          withToken,
          isNotEmpty,
          reason:
              'socket.io logs its packets; if it no longer does, the '
              "app's filter can go",
        );
        for (final record in withToken) {
          expect(record.loggerName, startsWith('socket_io'));
          expect(record.level < Level.INFO, isTrue, reason: record.message);
        }
      },
    );

    test('a reconnect sends the token as it is then', () async {
      var token = 't1';
      final lease = connectionTo(token: () async => token)
          .lease('games/search');
      await lease.ready(timeout: _wire);
      final dropped = lease.frames.firstWhere(
        (frame) => frame.event == RealtimeLease.disconnectEvent,
      );

      token = 't2';
      await server.connections.single.close();
      await dropped.timeout(_wire);
      await server.until(() => server.connects.length == 2);

      expect(server.connects.map((c) => c.auth), [
        {'token': 't1'},
        {'token': 't2'},
      ]);
      expect(server.connections, hasLength(2));
      await lease.ready(timeout: _wire);
    });

    test("a refused handshake's status reaches ready", () async {
      server.refusal = (_) => {
        'message': 'Your session is invalid',
        'data': {
          'statusCode': 401,
          'error': 'Unauthorized',
          'message': 'Your session is invalid',
        },
      };
      // An expired session: the native endpoint's token is null.
      final lease = connectionTo(token: () async => null).lease('games/search');

      await expectLater(
        lease.ready(timeout: _wire),
        throwsA(
          isA<RealtimeUnavailableException>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect(server.connects.single.auth, isEmpty, reason: 'no token sent');
    });

    test(
      'a refused namespace connects again when its lease next asks',
      () async {
        // socket.io destroys a socket the server refused, and never retries
        // it: the next ready connects the same socket again.
        server.refusal = (_) => {
          'message': 'Internal server error',
          'data': {'statusCode': 500},
        };
        var token = 't1';
        final lease = connectionTo(token: () async => token)
            .lease('games/search');
        await expectLater(
          lease.ready(timeout: _wire),
          throwsA(isA<RealtimeUnavailableException>()),
        );

        server.refusal = (_) => null;
        token = 't2';
        await lease.ready(timeout: _wire);

        expect(server.connects.map((c) => c.auth), [
          {'token': 't1'},
          {'token': 't2'},
        ]);
        final heard = lease.frames.first;
        server.connections.last.send(
          '/games/search',
          'search:done',
          {'correlationId': 'c1'},
        );
        expect((await heard.timeout(_wire)).event, 'search:done');
      },
    );

    test('with no token, the handshake carries no auth', () async {
      final lease = connectionTo().lease('games/search');

      await lease.ready(timeout: _wire);

      expect(server.connects.single.auth, isNull);
    });

    test(
      'frames carry server events, and the server disconnecting the '
      'namespace ends it',
      () async {
        final lease = connectionTo().lease('games/search');
        await lease.ready(timeout: _wire);
        final heard = lease.frames.take(2).toList();

        server.connections.single
          ..send('/games/search', 'search:result', {'correlationId': 'c1'})
          ..disconnect('/games/search');
        final frames = await heard.timeout(_wire);

        expect(frames.first.event, 'search:result');
        expect(frames.first.data, {'correlationId': 'c1'});
        expect(frames.last.event, RealtimeLease.disconnectEvent);
        // socket.io does not retry a namespace the server disconnected, so
        // the lease's next ready connects it again.
        expect(server.connects, hasLength(1));
        await lease.ready(timeout: _wire);
        expect(server.connects, hasLength(2));
      },
    );

    test(
      'a frame carries its payload alone, with or without the offset the '
      "server's connection-state recovery appends",
      () async {
        final lease = connectionTo().lease('games/search');
        await lease.ready(timeout: _wire);
        final heard = lease.frames.take(4).toList();
        const offset = '1794869781894-0';

        server.connections.single
          ..send('/games/search', 'search:result', {'correlationId': 'c1'})
          ..send(
            '/games/search',
            'exception',
            {'statusCode': 403, 'correlationId': 'c1'},
            extra: [offset],
          )
          ..send(
            '/games/search',
            'auth:error',
            {'statusCode': 401},
            extra: [offset, 'more'],
          )
          // A payload that is itself a list is still the frame's whole data
          // when an offset follows it.
          ..send('/games/search', 'listed', ['a', 'b'], extra: [offset]);
        final frames = await heard.timeout(_wire);

        expect(frames.map((f) => f.event), [
          'search:result',
          'exception',
          'auth:error',
          'listed',
        ]);
        expect(frames[0].data, {'correlationId': 'c1'});
        expect(frames[1].data, {'statusCode': 403, 'correlationId': 'c1'});
        expect(frames[2].data, {'statusCode': 401});
        expect(frames[3].data, ['a', 'b']);
      },
    );

    test('an event with no payload is heard with none', () async {
      final lease = connectionTo().lease('games/search');
      await lease.ready(timeout: _wire);
      final heard = lease.frames.first;

      server.connections.single.sendBare('/games/search', 'search:done');

      expect(
        await heard.timeout(_wire),
        (event: 'search:done', data: null),
      );
    });

    test(
      'a lease sends on its namespace, and its release disconnects it',
      () async {
        final lease = connectionTo().lease('games/search');
        await lease.ready(timeout: _wire);
        final engine = server.connections.single;

        lease
          ..emit('search:cancel', {'correlationId': 'c1'})
          // socket.io would spread a list into several arguments.
          ..emit('search:start', ['a', 'b']);
        await server.until(() => engine.events.length == 2);
        await lease.release();
        await server.until(() => engine.disconnected.isNotEmpty);

        expect(engine.events.map((e) => e.namespace), [
          '/games/search',
          '/games/search',
        ]);
        expect(engine.events.first.event, 'search:cancel');
        expect(engine.events.first.data, {'correlationId': 'c1'});
        expect(engine.events.last.data, ['a', 'b']);
        expect(engine.events.map((e) => e.arity), [1, 1]);
        expect(engine.disconnected, ['/games/search']);
      },
    );

    test('a null payload is sent as the one argument', () async {
      final lease = connectionTo().lease('games/search');
      await lease.ready(timeout: _wire);
      final engine = server.connections.single;

      // socket.io would send a bare null as no argument at all.
      lease.emit('search:done', null);
      await server.until(() => engine.events.isNotEmpty);

      expect(engine.events.single.event, 'search:done');
      expect(engine.events.single.arity, 1);
      expect(engine.events.single.data, isNull);
    });

    test(
      'a namespace leased again on a live connection connects again',
      () async {
        // socket.io hands a namespace's old socket back, with the auth hook
        // it was built with: with a token to send, a stale one never would.
        final connection = connectionTo(token: () async => 't1');
        final search = connection.lease('games/search');
        final imports = connection.lease('games/import');
        await search.ready(timeout: _wire);
        await imports.ready(timeout: _wire);

        await search.release();
        await server.until(
          () => server.connections.single.disconnected.isNotEmpty,
        );
        final again = connection.lease('games/search');

        await again.ready(timeout: _wire);
        expect(
          server.connections,
          hasLength(1),
          reason: 'games/import kept the connection up',
        );
        expect(
          server.connects
              .where((c) => c.namespace == '/games/search')
              .map((c) => c.auth),
          [
            {'token': 't1'},
            {'token': 't1'},
          ],
        );
      },
    );

    test(
      'two connections to one server keep a socket each, never one shared '
      "through socket.io's io() cache",
      () async {
        final alice = connectionTo(
          token: () async => 'alice',
        ).lease('games/search');
        final bob = connectionTo(token: () async => 'bob')
            .lease('games/import');

        await alice.ready(timeout: _wire);
        await bob.ready(timeout: _wire);

        expect(server.connections, hasLength(2));
        expect(
          {for (final c in server.connects) c.namespace: c.auth},
          {
            '/games/search': {'token': 'alice'},
            '/games/import': {'token': 'bob'},
          },
        );
        expect(
          server.connects.map((c) => c.connection).toSet(),
          hasLength(2),
        );
      },
    );
  });
}
