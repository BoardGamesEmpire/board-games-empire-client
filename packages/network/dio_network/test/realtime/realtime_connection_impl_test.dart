import 'dart:async';

import 'package:dio_network/src/realtime/realtime_connection_impl.dart';
import 'package:dio_network/src/realtime/realtime_endpoint.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_socket_manager.dart';

/// The session's socket connection over a fake socket.io (#473): which
/// sockets a lease opens and lets go of, when a lease is ready, what it
/// hears and sends, and what its handshake carries.
void main() {
  late FakeSocketManagerFactory factory;
  late RealtimeConnectionImpl connection;

  RealtimeConnectionImpl connectionTo({Future<String?> Function()? token}) =>
      RealtimeConnectionImpl(
        endpoint: RealtimeEndpoint(
          server: Uri.parse('https://h.test'),
          token: token,
        ),
        managerFactory: factory.call,
      );

  setUp(() {
    factory = FakeSocketManagerFactory();
    connection = connectionTo();
  });

  tearDown(() => connection.close());

  /// The first manager built.
  FakeSocketManager manager() => factory.managers.first;

  /// The first manager's first socket.
  FakeNamespaceSocket socket() => manager().sockets.first;

  /// The first manager's socket for [namespace].
  FakeNamespaceSocket socketFor(String namespace) =>
      manager().sockets.singleWhere((s) => s.namespace == namespace);

  TypeMatcher<RealtimeUnavailableException> unavailable({
    Object? statusCode = anything,
  }) => isA<RealtimeUnavailableException>().having(
    (e) => e.statusCode,
    'statusCode',
    statusCode,
  );

  /// What [future] failed with. Fails the test unless it settled once the
  /// event queue drained, so without waiting on any timer.
  Future<Object?> failureAtOnce(Future<void> future) async {
    Object? failure;
    var settled = false;
    unawaited(
      future.then<void>(
        (_) => settled = true,
        onError: (Object error) {
          failure = error;
          settled = true;
        },
      ),
    );
    await pumpEventQueue();
    expect(settled, isTrue, reason: 'it should answer without waiting');
    return failure;
  }

  group('leases', () {
    test(
      'the first lease connects its namespace and the last release '
      'disconnects it',
      () async {
        expect(factory.managers, isEmpty, reason: 'nothing connects unasked');

        final lease = connection.lease('games/search');

        expect(manager().endpoint.server, Uri.parse('https://h.test'));
        expect(socket().namespace, '/games/search');
        expect(socket().connects, 1);

        await lease.release();

        expect(socket().disposals, 1);
      },
    );

    test('two leases on one namespace share one socket', () async {
      final first = connection.lease('games/search');
      final second = connection.lease('games/search');
      final firstHeard = <RealtimeFrame>[];
      final secondHeard = <RealtimeFrame>[];
      first.frames.listen(firstHeard.add);
      second.frames.listen(secondHeard.add);

      expect(manager().sockets, hasLength(1));
      expect(socket().connects, 1);

      socket()
        ..accept()
        ..hear('search:done', null);
      await pumpEventQueue();

      expect(firstHeard, [(event: 'search:done', data: null)]);
      expect(secondHeard, [(event: 'search:done', data: null)]);

      await first.release();

      expect(socket().disposed, isFalse, reason: 'the second lease holds it');
      expect(second.connected, isTrue);

      await second.release();

      expect(socket().disposed, isTrue);
    });

    test('a namespace is one with or without its leading slash', () {
      final bare = connection.lease('games/search');
      final slashed = connection.lease('/games/search');

      expect(manager().sockets, hasLength(1));
      expect(bare.namespace, '/games/search');
      expect(slashed.namespace, '/games/search');
    });

    test(
      'two namespaces share one manager, and the manager closes when the '
      'last namespace goes',
      () async {
        final search = connection.lease('games/search');
        final imports = connection.lease('games/import');

        expect(factory.managers, hasLength(1));
        expect(manager().sockets.map((s) => s.namespace), [
          '/games/search',
          '/games/import',
        ]);

        await search.release();

        expect(socketFor('/games/search').disposed, isTrue);
        expect(manager().closed, isFalse, reason: 'games/import rides it');

        await imports.release();

        expect(socketFor('/games/import').disposed, isTrue);
        expect(manager().closes, 1);
      },
    );

    test('a lease after the manager closed builds a new manager', () async {
      await connection.lease('games/search').release();
      expect(manager().closed, isTrue);

      final again = connection.lease('games/search');

      expect(factory.managers, hasLength(2));
      final reopened = factory.managers.last.sockets.single;
      expect(reopened.connects, 1);

      reopened.accept();

      expect(again.connected, isTrue);
    });

    test('release is idempotent', () async {
      final first = connection.lease('games/search');
      final second = connection.lease('games/search');

      await first.release();
      await first.release();

      expect(
        socket().disposed,
        isFalse,
        reason: "a second release must not let go of the other lease's hold",
      );
      socket().accept();
      expect(second.connected, isTrue);

      await second.release();
      await second.release();

      expect(socket().disposals, 1);
      expect(manager().closes, 1);
    });

    test(
      'close disconnects everything, and a later lease throws StateError',
      () async {
        final search = connection.lease('games/search');
        final imports = connection.lease('games/import');
        socketFor('/games/search').accept();
        final searchEnds = expectLater(search.frames, emitsDone);
        final importWaitEnds = expectLater(
          imports.ready(),
          throwsA(unavailable()),
        );

        await connection.close();

        expect(socketFor('/games/search').disposed, isTrue);
        expect(socketFor('/games/import').disposed, isTrue);
        expect(manager().closes, 1);
        expect(search.connected, isFalse);
        await searchEnds;
        await importWaitEnds;
        expect(() => connection.lease('games/search'), throwsStateError);

        await search.release();
        await connection.close();

        expect(socketFor('/games/search').disposals, 1);
        expect(manager().closes, 1);
      },
    );
  });

  group('ready', () {
    test('ready completes on connect', () async {
      final lease = connection.lease('games/search');
      expect(lease.connected, isFalse);
      final ready = expectLater(lease.ready(), completes);

      socket().accept();

      await ready;
      expect(lease.connected, isTrue);
      await expectLater(lease.ready(), completes);
    });

    test(
      "ready throws RealtimeUnavailableException with the connect_error's "
      'statusCode',
      () async {
        final lease = connection.lease('games/search');
        final ready = expectLater(
          lease.ready(),
          throwsA(unavailable(statusCode: 403)),
        );

        socket().refuse({
          'statusCode': 403,
          'message': 'Anonymous sessions cannot use this',
        });

        await ready;
      },
    );

    test(
      "a refusal's statusCode is read where socket.io puts it, under data",
      () async {
        // socket.io 4 sends a refused handshake as `{message, data}`, with the
        // server's envelope as `data` (#473).
        final lease = connection.lease('games/search');
        final ready = expectLater(
          lease.ready(),
          throwsA(unavailable(statusCode: 401)),
        );

        socket().refuse({
          'message': 'Your session is invalid',
          'data': {
            'statusCode': 401,
            'error': 'Unauthorized',
            'message': 'Your session is invalid',
          },
        });

        await ready;
      },
    );

    test(
      'a connect that failed on the way keeps what socket.io said',
      () async {
        final lease = connection.lease('games/search');
        final ready = expectLater(
          lease.ready(),
          throwsA(
            unavailable(
              statusCode: isNull,
            ).having((e) => e.cause, 'cause', 'websocket error'),
          ),
        );

        socket().fail('websocket error');

        await ready;
      },
    );

    test('ready times out as RealtimeUnavailableException', () async {
      final lease = connection.lease('games/search');

      await expectLater(
        lease.ready(timeout: const Duration(milliseconds: 1)),
        throwsA(unavailable(statusCode: isNull)),
      );
    });

    test('a lease that failed to connect is unavailable at once', () async {
      final lease = connection.lease('games/search');
      final first = expectLater(lease.ready(), throwsA(unavailable()));

      // socket.io goes on retrying in the background, so the socket is still
      // active: it is the failure that answers, not the socket's state.
      socket().fail('websocket error');
      await first;
      expect(socket().active, isTrue);

      expect(await failureAtOnce(lease.ready()), unavailable());
      expect(
        await failureAtOnce(connection.lease('games/search').ready()),
        unavailable(),
        reason: 'a new lease shares the failed namespace',
      );
    });

    test(
      'a wait that ran out leaves the namespace unavailable at once',
      () async {
        final lease = connection.lease('games/search');
        await expectLater(
          lease.ready(timeout: const Duration(milliseconds: 1)),
          throwsA(unavailable()),
        );

        expect(await failureAtOnce(lease.ready()), unavailable());
      },
    );

    test('a wait that ran out ends every wait on the namespace', () async {
      final first = connection.lease('games/search');
      final second = connection.lease('games/search');
      var longerEnded = false;
      final longer = expectLater(
        second.ready(),
        throwsA(unavailable()),
      ).whenComplete(() => longerEnded = true);

      await expectLater(
        first.ready(timeout: const Duration(milliseconds: 1)),
        throwsA(unavailable()),
      );
      await pumpEventQueue();

      // Ended with the shorter wait, not by its own timer, which runs for
      // seconds more.
      expect(longerEnded, isTrue);
      await longer;
    });

    test('a namespace that connects after failing is ready again', () async {
      final lease = connection.lease('games/search');

      socket()
        ..fail('websocket error')
        // socket.io's next attempt got through.
        ..accept();

      expect(lease.connected, isTrue);
      await expectLater(lease.ready(), completes);
    });

    test('a dropped connection waits for socket.io to reconnect', () async {
      final lease = connection.lease('games/search');
      socket()
        ..accept()
        ..drop('transport close');
      expect(lease.connected, isFalse);

      var settled = false;
      final ready = lease.ready();
      unawaited(ready.then<void>((_) => settled = true, onError: (_) {}));
      await pumpEventQueue();
      expect(settled, isFalse, reason: 'socket.io is reconnecting');

      socket().accept();

      await expectLater(ready, completes);
    });

    test(
      'a namespace the server refused connects again when a lease next asks',
      () async {
        // A refusal can be a passing one, such as a 500 while the server's
        // auth hiccups, and the search screen holds its lease for its whole
        // life: socket.io never retries a refusal, so this is what does.
        final lease = connection.lease('games/search');
        final refused = expectLater(
          lease.ready(),
          throwsA(unavailable(statusCode: 500)),
        );
        socket().refuse({'statusCode': 500});
        await refused;
        expect(socket().connects, 1);

        final again = expectLater(lease.ready(), completes);
        expect(socket().connects, 2);
        expect(socket().active, isTrue);
        socket().accept();

        await again;
        expect(lease.connected, isTrue);
        expect(manager().sockets, hasLength(1), reason: 'the same socket');
      },
    );

    test(
      'a namespace refused again answers that refusal',
      () async {
        final lease = connection.lease('games/search');
        socket().refuse({'statusCode': 500});

        final again = expectLater(
          lease.ready(),
          throwsA(unavailable(statusCode: 403)),
        );
        socket().refuse({'statusCode': 403});

        await again;
      },
    );

    test(
      'a namespace the server disconnected connects again when a lease next '
      'asks',
      () async {
        final lease = connection.lease('games/search');
        socket()
          ..accept()
          ..drop('io server disconnect', reconnects: false);
        expect(socket().connects, 1);

        final again = expectLater(lease.ready(), completes);
        expect(socket().connects, 2);
        socket().accept();

        await again;
      },
    );

    test(
      'a namespace socket.io is still retrying is not connected again',
      () async {
        final lease = connection.lease('games/search');
        socket().fail('websocket error');

        expect(await failureAtOnce(lease.ready()), unavailable());
        expect(socket().connects, 1, reason: 'socket.io is on it');
      },
    );

    test('a release ends its own wait, and no other', () async {
      final first = connection.lease('games/search');
      final second = connection.lease('games/search');
      final firstEnds = expectLater(first.ready(), throwsA(unavailable()));
      final secondConnects = expectLater(second.ready(), completes);

      await first.release();
      await firstEnds;
      socket().accept();

      await secondConnects;
      expect(await failureAtOnce(first.ready()), unavailable());
      expect(first.connected, isFalse);
    });

    test('a release while connecting lets go of the socket', () async {
      final lease = connection.lease('games/search');
      final ends = expectLater(lease.ready(), throwsA(unavailable()));

      await lease.release();

      await ends;
      expect(socket().disposed, isTrue);
      expect(manager().closed, isTrue);
    });

    test('a release after a failure lets go of the socket', () async {
      final lease = connection.lease('games/search');
      socket().fail('websocket error');

      await lease.release();

      expect(socket().disposed, isTrue, reason: 'socket.io stops retrying');
      expect(manager().closed, isTrue);
    });
  });

  group('frames', () {
    test('frames carry every event and a synthetic disconnect', () async {
      final lease = connection.lease('games/search');
      final heard = <RealtimeFrame>[];
      lease.frames.listen(heard.add);
      final result = {'correlationId': 'c1', 'source': 'local'};
      final refused = {'statusCode': 429, 'message': 'Too many requests'};

      socket()
        ..accept()
        ..hear('search:result', result)
        ..hear('exception', refused)
        ..drop('transport close');
      await pumpEventQueue();

      expect(heard, [
        (event: 'search:result', data: result),
        (event: 'exception', data: refused),
        (event: RealtimeLease.disconnectEvent, data: 'transport close'),
      ]);
    });

    test('a connect that never happened sends no disconnect frame', () async {
      final lease = connection.lease('games/search');
      final heard = <RealtimeFrame>[];
      lease.frames.listen(heard.add);

      socket()
        ..fail('websocket error')
        ..drop('transport close');
      await pumpEventQueue();

      expect(heard, isEmpty);
    });

    test('each lease hears its own namespace', () async {
      final search = connection.lease('games/search');
      final imports = connection.lease('games/import');
      final searchHeard = <RealtimeFrame>[];
      final importsHeard = <RealtimeFrame>[];
      search.frames.listen(searchHeard.add);
      imports.frames.listen(importsHeard.add);

      socketFor('/games/search')
        ..accept()
        ..hear('search:done', null);
      await pumpEventQueue();

      expect(searchHeard, [(event: 'search:done', data: null)]);
      expect(importsHeard, isEmpty);
    });

    test('a released lease hears nothing more', () async {
      final first = connection.lease('games/search');
      final second = connection.lease('games/search');
      final secondHeard = <RealtimeFrame>[];
      second.frames.listen(secondHeard.add);
      final firstEnds = expectLater(first.frames, emitsDone);

      await first.release();
      await firstEnds;
      socket()
        ..accept()
        ..hear('search:done', null);
      await pumpEventQueue();

      expect(secondHeard, [(event: 'search:done', data: null)]);
    });

    test('emit sends only while connected', () async {
      final lease = connection.lease('games/search');
      final early = {'correlationId': 'c0'};
      final start = {'correlationId': 'c1'};
      final cancel = {'correlationId': 'c1'};
      final released = {'correlationId': 'c2'};

      lease.emit('search:start', early);
      socket().accept();
      lease.emit('search:start', start);
      socket().drop('transport close');
      lease.emit('search:cancel', cancel);
      socket().accept();
      await lease.release();
      lease.emit('search:start', released);

      expect(socket().sent, [(event: 'search:start', data: start)]);
    });
  });

  group('auth', () {
    test('auth reads the current token on each connect', () async {
      final tokens = ['t1', 't2'];
      var reads = 0;
      final native = connectionTo(token: () async => tokens[reads++]);
      addTearDown(native.close);

      native.lease('games/search');
      final auth = factory.managers.single.sockets.single.auth!;

      expect(reads, 0, reason: 'nothing is read before socket.io connects');
      expect(await auth(), {'token': 't1'});
      expect(
        await auth(),
        {'token': 't2'},
        reason: 'a reconnect sends the token as it is then',
      );
      expect(reads, 2);
    });

    test('an expired token connects without auth', () async {
      // The native endpoint's token is null once the stored session has
      // expired (`registerServerNetwork`).
      final expired = connectionTo(token: () async => null);
      addTearDown(expired.close);

      expired.lease('games/search');

      expect(await factory.managers.single.sockets.single.auth!(), isEmpty);
    });

    test('a token that cannot be read connects without one', () async {
      final locked = connectionTo(
        token: () async => throw StateError('the keychain is locked'),
      );
      addTearDown(locked.close);

      locked.lease('games/search');

      expect(await factory.managers.single.sockets.single.auth!(), isEmpty);
    });

    test('with no token to send, the handshake carries no auth at all', () {
      // Web: the browser sends the session cookie itself.
      connection.lease('games/search');

      expect(socket().auth, isNull);
    });
  });
}
