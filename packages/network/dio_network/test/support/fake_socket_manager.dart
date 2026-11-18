import 'package:dio_network/src/realtime/realtime_endpoint.dart';
import 'package:dio_network/src/realtime/socket_manager.dart';
import 'package:network_interface/network_interface.dart';

/// A [SocketManagerFactory] standing in for socket.io: it records every
/// manager it builds, so a test can find the sockets a connection opened and
/// drive their callbacks itself.
class FakeSocketManagerFactory {
  /// Every manager built, in order.
  final List<FakeSocketManager> managers = [];

  /// The factory, as a connection takes it.
  SocketManager call(RealtimeEndpoint endpoint) {
    final manager = FakeSocketManager(endpoint);
    managers.add(manager);
    return manager;
  }
}

/// One recorded manager: the endpoint it was built for, the sockets asked of
/// it, and whether it was closed.
class FakeSocketManager implements SocketManager {
  FakeSocketManager(this.endpoint);

  final RealtimeEndpoint endpoint;

  /// Every socket asked for, in order.
  final List<FakeNamespaceSocket> sockets = [];

  /// How many times [close] ran.
  int closes = 0;

  bool get closed => closes > 0;

  @override
  NamespaceSocket socket(
    String namespace, {
    Future<Map<String, Object?>> Function()? auth,
  }) {
    final socket = FakeNamespaceSocket(namespace, auth: auth);
    sockets.add(socket);
    return socket;
  }

  @override
  void close() => closes += 1;
}

/// One namespace's socket. Its `connected` and `active` follow what the test
/// has it do, as socket.io's would.
class FakeNamespaceSocket implements NamespaceSocket {
  FakeNamespaceSocket(this.namespace, {this.auth});

  final String namespace;

  /// The handshake's credential, as the connection handed it over.
  final Future<Map<String, Object?>> Function()? auth;

  @override
  bool connected = false;

  @override
  bool active = false;

  /// How many times [connect] ran.
  int connects = 0;

  /// How many times [dispose] ran.
  int disposals = 0;

  bool get disposed => disposals > 0;

  /// Every frame sent through [emit], in order.
  final List<RealtimeFrame> sent = [];

  final List<void Function()> _onConnect = [];
  final List<void Function(Object? error)> _onConnectError = [];
  final List<void Function(Object? reason)> _onDisconnect = [];
  final List<void Function(String event, Object? data)> _onAny = [];

  @override
  void connect() {
    connects += 1;
    active = true;
  }

  @override
  void disconnect() {
    connected = false;
    active = false;
  }

  @override
  void emit(String event, Object? data) => sent.add((event: event, data: data));

  @override
  void onConnect(void Function() f) => _onConnect.add(f);

  @override
  void onConnectError(void Function(Object? error) f) => _onConnectError.add(f);

  @override
  void onDisconnect(void Function(Object? reason) f) => _onDisconnect.add(f);

  @override
  void onAny(void Function(String event, Object? data) f) => _onAny.add(f);

  /// Disconnects and forgets every listener, as socket.io's does.
  @override
  void dispose() {
    disposals += 1;
    connected = false;
    active = false;
    _onConnect.clear();
    _onConnectError.clear();
    _onDisconnect.clear();
    _onAny.clear();
  }

  /// The server accepted the namespace.
  void accept() {
    connected = true;
    for (final f in [..._onConnect]) {
      f();
    }
  }

  /// The server refused the handshake with [error]. socket.io destroys a
  /// refused socket before it reports the refusal, so it never retries.
  void refuse(Object? error) {
    active = false;
    for (final f in [..._onConnectError]) {
      f(error);
    }
  }

  /// The connection failed on the way, with [error]. The socket stays active,
  /// as socket.io goes on retrying.
  void fail(Object? error) {
    for (final f in [..._onConnectError]) {
      f(error);
    }
  }

  /// The connection dropped, for [reason]. socket.io reconnects a transport
  /// that closed, but not a socket the server disconnected.
  void drop(Object? reason, {bool reconnects = true}) {
    connected = false;
    active = reconnects;
    for (final f in [..._onDisconnect]) {
      f(reason);
    }
  }

  /// The server sent [event] with [data].
  void hear(String event, Object? data) {
    for (final f in [..._onAny]) {
      f(event, data);
    }
  }
}
