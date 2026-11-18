// `dart:io` is test-only here: this server runs on the VM, so the real
// socket.io client can be checked on the wire. A suite that imports it is
// VM-only: it would not compile for a browser, and CI runs this package's
// tests on the VM alone.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One namespace CONNECT the server heard: the engine connection it came on,
/// the namespace, and the handshake's `auth` (null when it carried none).
typedef FakeConnect = ({
  FakeEngineConnection connection,
  String namespace,
  Object? auth,
});

/// A socket.io server small enough to read: engine.io 4 over WebSocket alone,
/// and only the packets a namespace's life needs (#473).
///
/// It answers the engine.io handshake at [path] and nowhere else, records
/// each namespace CONNECT, and accepts it, or refuses it with what [refusal]
/// returns. socket.io 4 sends a refusal as `{message, data}`, the server's
/// envelope as `data` (`socket.io/dist/namespace.js`, a middleware error), so
/// a test passes that shape.
class FakeSocketIoServer {
  FakeSocketIoServer._(this._server, this.path);

  /// Starts a server on a free loopback port, answering at [path].
  static Future<FakeSocketIoServer> start({
    String path = '/socket.io/',
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeSocketIoServer._(server, path);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;

  /// The engine.io path, with the trailing slash socket.io adds.
  final String path;

  /// How the server answers a CONNECT: null accepts it, anything else is
  /// what it is refused with.
  Object? Function(FakeConnect connect) refusal = (_) => null;

  /// Every request for a path other than [path], each answered 404.
  final List<String> missed = [];

  /// Every engine connection, in the order they opened.
  final List<FakeEngineConnection> connections = [];

  /// Every namespace CONNECT, in order.
  final List<FakeConnect> connects = [];

  final StreamController<void> _changes = StreamController.broadcast();

  /// Wakes [until]. A connection can still close after [close] has.
  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// The server's address with [prefix] as its path, as a client would be
  /// configured to reach it.
  Uri url([String prefix = '']) =>
      Uri.parse('http://${_server.address.host}:${_server.port}$prefix');

  /// Completes once [ready] holds, checking again whenever a packet arrives.
  Future<void> until(bool Function() ready) async {
    while (!ready()) {
      await _changes.stream.first.timeout(const Duration(seconds: 10));
    }
  }

  Future<void> close() async {
    for (final connection in connections) {
      await connection.close();
    }
    await _server.close(force: true);
    await _changes.close();
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path != path ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      missed.add(request.uri.path);
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      _changed();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    final connection = FakeEngineConnection._(this, socket);
    connections.add(connection);
    // engine.io's OPEN: no upgrades, as the client asked for WebSocket alone,
    // and ping times long enough never to fire in a test.
    socket
      ..add(
        '0${jsonEncode({
          'sid': 'engine-${connections.length}',
          'upgrades': <String>[],
          'pingInterval': 60000,
          'pingTimeout': 60000,
          'maxPayload': 1000000,
        })}',
      )
      ..listen(connection._receive, onDone: _changed);
    _changed();
  }

  void _heard(FakeConnect connect) {
    connects.add(connect);
    final refused = refusal(connect);
    if (refused == null) {
      connect.connection._send('0${connect.namespace},', {
        'sid': 'socket-${connects.length}',
      });
    } else {
      connect.connection._send('4${connect.namespace},', refused);
    }
    _changed();
  }
}

/// One client's engine connection to a [FakeSocketIoServer].
class FakeEngineConnection {
  FakeEngineConnection._(this._server, this._socket);

  final FakeSocketIoServer _server;
  final WebSocket _socket;

  /// Each namespace the client sent a DISCONNECT for, in order.
  final List<String> disconnected = [];

  /// Each event the client sent, in order, with its first argument and how
  /// many arguments it came with.
  final List<({String namespace, String event, Object? data, int arity})>
  events = [];

  /// Sends the server event [event] with [data] on [namespace], and [extra]
  /// after it. The real server appends its connection-state recovery's stream
  /// offset (`'1794869781894-0'`) to a frame it sends through its adapter.
  void send(
    String namespace,
    String event,
    Object? data, {
    List<Object?> extra = const [],
  }) => _send('2$namespace,', [event, data, ...extra]);

  /// Sends the server event [event] on [namespace] with no payload at all.
  void sendBare(String namespace, String event) =>
      _send('2$namespace,', [event]);

  /// Disconnects [namespace] from the server's side, as `socket.disconnect()`
  /// does there.
  void disconnect(String namespace) => _socket.add('41$namespace,');

  /// Drops the whole connection, as a network fault or a restart would.
  Future<void> close() => _socket.close();

  void _send(String header, Object? data) =>
      _socket.add('4$header${jsonEncode(data)}');

  void _receive(dynamic message) {
    // A socket.io packet rides an engine.io MESSAGE (`4`): its type, then its
    // namespace and a comma, then its JSON.
    if (message is! String || !message.startsWith('4')) return;
    final type = message[1];
    final rest = message.substring(2);
    final comma = rest.indexOf(',');
    final namespace = comma == -1 ? rest : rest.substring(0, comma);
    final body = comma == -1 ? '' : rest.substring(comma + 1);
    switch (type) {
      case '0':
        _server._heard((
          connection: this,
          namespace: namespace,
          auth: body.isEmpty ? null : jsonDecode(body),
        ));
      case '1':
        disconnected.add(namespace);
        _server._changed();
      case '2':
        final arguments = jsonDecode(body) as List<Object?>;
        events.add((
          namespace: namespace,
          event: arguments.first! as String,
          data: arguments.length > 1 ? arguments[1] : null,
          arity: arguments.length - 1,
        ));
        _server._changed();
    }
  }
}
