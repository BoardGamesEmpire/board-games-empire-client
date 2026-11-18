import 'dart:async';

import 'package:dio_network/src/realtime/realtime_endpoint.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:socket_io_client/socket_io_client.dart' as socket_io;
// socket.io's `Manager` is part of its API (every `Socket` names its own), but
// the package exports no way to build one except `io()`, whose process-wide
// cache this file exists to avoid (#473).
// ignore: implementation_imports
import 'package:socket_io_client/src/manager.dart' as socket_io show Manager;

/// The seam over socket.io (#473): one connection to a server, on which each
/// namespace gets a [NamespaceSocket].
///
/// `RealtimeConnectionImpl` drives it. [socketIoManager] is the real one, and
/// tests stand in for it.
abstract interface class SocketManager {
  /// A socket for [namespace], with its leading `/`, not yet connected.
  ///
  /// [auth] gives the handshake's `auth`. It is called on every connect and
  /// reconnect, so the handshake carries the credential as it is then.
  /// Without it the handshake sends no `auth`, as on web, where the browser
  /// sends the session cookie.
  NamespaceSocket socket(
    String namespace, {
    Future<Map<String, Object?>> Function()? auth,
  });

  /// Closes the connection, once every namespace's socket has been disposed.
  void close();
}

/// One namespace's socket on a [SocketManager]: as much of socket.io's
/// `Socket` as a lease needs.
abstract interface class NamespaceSocket {
  /// Whether the server accepted the namespace, and it is still connected.
  bool get connected;

  /// Whether socket.io still means to connect it: from [connect] until either
  /// side disconnects it or the server refuses it. A connection that failed
  /// or dropped on the way stays active while socket.io retries it.
  bool get active;

  void connect();

  void disconnect();

  /// Sends [event] with [data] as its one argument.
  void emit(String event, Object? data);

  /// The server accepted the namespace.
  void onConnect(void Function() f);

  /// The server refused the handshake, or the connect failed on the way.
  void onConnectError(void Function(Object? error) f);

  /// The namespace's connection ended, for [f]'s reason.
  void onDisconnect(void Function(Object? reason) f);

  /// Every event the server sends on the namespace, with its first argument as
  /// its data. Anything after that, such as the offset the server's
  /// connection-state recovery appends, is dropped.
  void onAny(void Function(String event, Object? data) f);

  /// Disconnects, and forgets every listener.
  void dispose();
}

/// Builds the [SocketManager] for an endpoint.
typedef SocketManagerFactory = SocketManager Function(
  RealtimeEndpoint endpoint,
);

/// The [SocketManager] over socket.io for [endpoint], on a `Manager` it builds
/// itself (#473).
///
/// Never `io()`. It caches managers process-wide, keyed by scheme, host and
/// port alone, so two servers on one host, or one session and the next, would
/// share a connection and the credential it opened with. A manager built here
/// belongs to the one connection that asked for it.
SocketManager socketIoManager(RealtimeEndpoint endpoint) =>
    _SocketIoManager(endpoint);

/// The options [socketIoManager] builds its manager with (#473).
///
/// - **WebSocket alone,** the only transport socket.io's native client has, so
///   both platforms connect the same way.
/// - **No auto-connect.** A namespace connects on its first lease.
/// - **Reconnection,** with socket.io's backoff, so a dropped connection comes
///   back by itself.
/// - **The server's path.** A server reached under a prefix
///   (`https://host/bge`) serves socket.io at `/bge/socket.io`. socket.io's
///   default, `/socket.io`, would 404 there, and every search would fall back
///   to REST without a word.
@visibleForTesting
Map<String, dynamic> socketIoOptions(RealtimeEndpoint endpoint) =>
    socket_io.OptionBuilder()
        .setTransports(['websocket'])
        .disableAutoConnect()
        .enableReconnection()
        .setPath(
          '${endpoint.server.path.replaceFirst(_trailingSlashes, '')}'
          '/socket.io',
        )
        .build();

final RegExp _trailingSlashes = RegExp(r'/+$');

final class _SocketIoManager implements SocketManager {
  _SocketIoManager(RealtimeEndpoint endpoint)
    : _manager = socket_io.Manager(
        uri: _origin(endpoint.server),
        options: socketIoOptions(endpoint),
      );

  final socket_io.Manager _manager;

  @override
  NamespaceSocket socket(
    String namespace, {
    Future<Map<String, Object?>> Function()? auth,
  }) => _SocketIoNamespaceSocket(_manager, namespace, auth);

  // socket.io has most often closed the manager already, as its last
  // socket was disposed (`Manager.destroy`), and closing it again changes
  // nothing. The close here keeps [SocketManager.close]'s promise without
  // leaning on that.
  @override
  void close() => _manager.close();

  /// The scheme, host and port: socket.io takes its path from the options,
  /// and would take a query from here.
  static String _origin(Uri server) => Uri(
    scheme: server.scheme,
    host: server.host,
    port: server.hasPort ? server.port : null,
  ).toString();
}

final class _SocketIoNamespaceSocket implements NamespaceSocket {
  _SocketIoNamespaceSocket(this._manager, this._namespace, this._auth) {
    _socket = _manager.socket(
      _namespace,
      _auth == null
          ? <String, dynamic>{}
          : socket_io.OptionBuilder().setAuthFn(_authenticate).build(),
    );
  }

  final socket_io.Manager _manager;
  final String _namespace;
  final Future<Map<String, Object?>> Function()? _auth;
  late final socket_io.Socket _socket;
  bool _disposed = false;

  @override
  bool get connected => _socket.connected;

  @override
  bool get active => _socket.active;

  @override
  void connect() => _socket.connect();

  @override
  void disconnect() => _socket.disconnect();

  @override
  void emit(String event, Object? data) =>
      // socket.io spreads a list into several arguments, and sends a bare
      // null as none. Wrapped, any payload, null too, is the event's one
      // argument.
      _socket.emit(event, [data]);

  @override
  void onConnect(void Function() f) => _socket.onConnect((_) => f());

  @override
  void onConnectError(void Function(Object? error) f) =>
      _socket.onConnectError(f);

  @override
  void onDisconnect(void Function(Object? reason) f) => _socket.onDisconnect(f);

  @override
  void onAny(void Function(String event, Object? data) f) =>
      _socket.onAny((event, [arguments]) => f(event, _firstOf(arguments)));

  /// An event's first argument, from what socket.io's `onAny` hands on.
  ///
  /// socket.io passes the event alone when it came with no arguments (so the
  /// parameter above is optional), its one argument as it came, and two or
  /// more packed into one list. The server's connection-state recovery
  /// appends a stream offset to every frame it sends through its adapter, as
  /// `exception` and `auth:error` are, so those arrive packed. No event in
  /// this protocol has a list as its whole payload (#473), so a list of two
  /// or more is packed arguments, and its first is the payload.
  ///
  /// The packing is socket.io's own (`Socket.emitEvent`), and it does the
  /// same for a listener on one event: a lone list of two or more and as
  /// many arguments reach every listener as the same list. An event whose
  /// payload is a list would need the payload wrapped on the server.
  static Object? _firstOf(Object? arguments) =>
      arguments is List && arguments.length >= 2 ? arguments.first : arguments;

  @override
  void dispose() {
    _disposed = true;
    _socket.dispose();
    // The manager keeps a namespace's socket for its whole life and hands the
    // same one back from `socket()`, with the auth it was first built with.
    // Forgotten here, the namespace's next lease gets a socket of its own.
    if (identical(_manager.nsps[_namespace], _socket)) {
      _manager.nsps.remove(_namespace);
    }
  }

  /// socket.io's auth hook. It calls this on every connect and reconnect, with
  /// the callback that sends the namespace's CONNECT, so the credential is
  /// read then. Once read, it is sent, unless the socket has been disposed or
  /// socket.io has opened another engine meanwhile, whose own call sends its
  /// own. A read that fails sends an empty `auth`.
  void _authenticate(void Function(Map<dynamic, dynamic> auth) send) {
    final engine = _manager.engine;
    void sendIfCurrent(Map<String, Object?> auth) {
      if (!_disposed && identical(_manager.engine, engine)) send(auth);
    }

    unawaited(
      _auth!().then(
        sendIfCurrent,
        onError: (Object _) => sendIfCurrent(const {}),
      ),
    );
  }
}
