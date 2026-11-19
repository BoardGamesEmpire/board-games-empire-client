import 'dart:async';

import 'package:dio_network/src/realtime/realtime_endpoint.dart';
import 'package:dio_network/src/realtime/socket_manager.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// The session's socket connection to one server (#473): one socket.io
/// connection, on which each feature leases its namespace.
///
/// ## Leases
///
/// The user-session scope owns the connection (`RealtimeInstaller`), so it
/// closes when the session ends. Nothing connects at sign-in.
///
/// - **The first lease on a namespace connects it,** and later leases share
///   its socket. The last release disconnects it.
/// - **Every namespace rides one manager,** which the first lease builds and
///   the last namespace to go closes. The next lease builds a new one.
/// - **The manager is never socket.io's `io()`** ([socketIoManager] says
///   why).
///
/// ## When a namespace can serve
///
/// [RealtimeLease.ready] waits only while a namespace is connecting: on its
/// first connect, and while socket.io reconnects one that dropped. A connect
/// that fails, is refused or outruns a wait leaves the namespace unavailable
/// at once to every lease, until it connects. socket.io goes on retrying a
/// connect that failed on the way, so the namespace serves again once a retry
/// gets through. One the server refused or disconnected socket.io never
/// retries, so the next [RealtimeLease.ready] connects it again, and waits
/// for it as for a first connect.
///
/// ## The handshake
///
/// The endpoint's token is read on every connect and reconnect, never once
/// and kept, as the stored session can change or expire between connects. A
/// token that is null, or can't be read, sends an empty `auth`, which the
/// server refuses with a 401. With no token to read at all, as on web, the
/// handshake sends no `auth`, and the browser's session cookie authenticates.
final class RealtimeConnectionImpl implements RealtimeConnection {
  RealtimeConnectionImpl({
    required this._endpoint,
    this._managerFactory = socketIoManager,
  });

  final RealtimeEndpoint _endpoint;
  final SocketManagerFactory _managerFactory;

  static final BgeLogger _log = BgeLogger('bge.network.realtime');

  /// The manager every leased namespace rides, while any is leased.
  SocketManager? _manager;

  /// Each leased namespace, by its name with the leading `/`.
  final Map<String, _Namespace> _namespaces = {};

  bool _closed = false;

  @override
  RealtimeLease lease(String namespace) {
    if (_closed) {
      throw StateError(
        'This realtime connection is closed: the session that owned it has '
        'ended.',
      );
    }
    final name = namespace.startsWith('/') ? namespace : '/$namespace';
    return (_namespaces[name] ??= _open(name)).lease();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    const closed = RealtimeUnavailableException(
      'The realtime connection is closed',
    );
    for (final namespace in [..._namespaces.values]) {
      namespace.end(closed);
    }
    _namespaces.clear();
    _manager?.close();
    _manager = null;
  }

  _Namespace _open(String name) {
    final manager = _manager ??= _managerFactory(_endpoint);
    final token = _endpoint.token;
    return _Namespace(
      name,
      manager.socket(name, auth: token == null ? null : () => _auth(token)),
      onLastRelease: _letGo,
    );
  }

  /// Drops [namespace], whose last lease has gone, and closes the manager
  /// once no namespace is left.
  void _letGo(_Namespace namespace) {
    _namespaces.remove(namespace.name);
    if (_namespaces.isEmpty) {
      _manager?.close();
      _manager = null;
    }
  }

  /// The handshake's `auth`: the token as [token] reads it now.
  Future<Map<String, Object?>> _auth(Future<String?> Function() token) async {
    try {
      final current = await token();
      return current == null ? const {} : {'token': current};
    } on Object catch (error, stackTrace) {
      _log.warn(
        'Could not read the session token for the socket handshake; '
        'connecting without one',
        error: error,
        stackTrace: stackTrace,
      );
      return const {};
    }
  }
}

/// Where a namespace stands. Leases wait on it only while it is
/// [connecting].
enum _Phase { connecting, connected, unavailable }

/// One leased namespace: its socket, its leases, and where it stands.
final class _Namespace {
  _Namespace(this.name, this.socket, {required this._onLastRelease}) {
    socket
      ..onConnect(_connected)
      ..onConnectError(_connectFailed)
      ..onDisconnect(_disconnected)
      ..onAny(_heard)
      ..connect();
  }

  final String name;
  final NamespaceSocket socket;
  final void Function(_Namespace namespace) _onLastRelease;
  final Set<_Lease> _leases = {};

  _Phase _phase = _Phase.connecting;

  /// Why the namespace can't serve, while it is [_Phase.unavailable].
  RealtimeUnavailableException? _failure;

  /// Set once the socket has been let go of. Its callbacks are ignored from
  /// then on: a socket being disposed still reports its own disconnect.
  bool _ended = false;

  bool get connected => _phase == _Phase.connected;

  _Lease lease() {
    final lease = _Lease(this);
    _leases.add(lease);
    return lease;
  }

  /// Answers [_Lease.ready] for [lease].
  Future<void> ready(_Lease lease, Duration timeout) {
    if (_phase == _Phase.unavailable && !socket.active) _connectAgain();
    return switch (_phase) {
      _Phase.connected => Future<void>.value(),
      _Phase.unavailable => Future<void>.error(_failure!),
      _Phase.connecting => lease.wait(timeout, onTimeout: _timedOut),
    };
  }

  /// Connects the namespace again, on its same socket: the server refused it
  /// or disconnected it, and socket.io never retries either.
  ///
  /// A refusal can pass, as a 500 while the server's auth hiccups does, and
  /// a lease can last as long as its screen. So a lease that asks connects
  /// it, rather than the namespace staying unavailable until every lease has
  /// gone. Only a lease's asking does it, so a refusal that stands costs one
  /// handshake per search, and nothing while no one searches.
  void _connectAgain() {
    _phase = _Phase.connecting;
    _failure = null;
    socket.connect();
  }

  /// Lets go of [lease], and of the socket when it was the last.
  void release(_Lease lease) {
    if (!_leases.remove(lease) || _leases.isNotEmpty) return;
    _dispose();
    _onLastRelease(this);
  }

  /// Ends every lease with [why] and lets go of the socket: the connection
  /// is closing.
  void end(RealtimeUnavailableException why) {
    final leases = [..._leases];
    _leases.clear();
    for (final lease in leases) {
      lease.end(why);
    }
    _dispose();
  }

  void _dispose() {
    _ended = true;
    socket.dispose();
  }

  void _connected() {
    if (_ended) return;
    _phase = _Phase.connected;
    _failure = null;
    for (final lease in _leases) {
      lease.settle();
    }
  }

  void _connectFailed(Object? error) {
    if (_ended) return;
    final statusCode = _statusCodeOf(error);
    RealtimeConnectionImpl._log.debug(
      'A realtime namespace could not connect',
      context: {'namespace': name, 'statusCode': statusCode},
    );
    _unavailable(
      RealtimeUnavailableException(
        statusCode == null
            ? 'The $name namespace could not connect'
            : 'The server refused the $name namespace',
        statusCode: statusCode,
        cause: error,
      ),
    );
  }

  void _disconnected(Object? reason) {
    // A connect that never happened shows on connect_error, or as a wait that
    // ran out, and a lease has heard nothing from it to be told is gone.
    if (_ended || _phase != _Phase.connected) return;
    if (socket.active) {
      // socket.io is reconnecting: a dropped transport, or a missed ping.
      _phase = _Phase.connecting;
    } else {
      // The server disconnected the namespace, and socket.io won't retry it.
      _unavailable(
        RealtimeUnavailableException(
          'The server disconnected the $name namespace',
          cause: reason,
        ),
      );
    }
    for (final lease in _leases) {
      lease.hear((event: RealtimeLease.disconnectEvent, data: reason));
    }
  }

  void _heard(String event, Object? data) {
    if (_ended) return;
    for (final lease in _leases) {
      lease.hear((event: event, data: data));
    }
  }

  /// A wait ran out. The namespace answers at once from now on, until it
  /// connects, and every other wait ends with this one, so nothing waits on
  /// a connect already given up on.
  void _timedOut(Duration timeout) {
    _unavailable(
      RealtimeUnavailableException(
        'The $name namespace did not connect within $timeout',
      ),
    );
  }

  void _unavailable(RealtimeUnavailableException failure) {
    _phase = _Phase.unavailable;
    _failure = failure;
    for (final lease in _leases) {
      lease.settle(failure);
    }
  }

  /// The status a refused handshake carries. socket.io 4 sends a middleware's
  /// refusal as `{message, data}`, with the server's envelope as `data`, so it
  /// is read there and at the top.
  static int? _statusCodeOf(Object? error) {
    if (error is! Map) return null;
    final status = error['statusCode'];
    if (status is int) return status;
    final data = error['data'];
    if (data is! Map) return null;
    final nested = data['statusCode'];
    return nested is int ? nested : null;
  }
}

final class _Lease implements RealtimeLease {
  _Lease(this._namespace);

  final _Namespace _namespace;
  final StreamController<RealtimeFrame> _frames =
      StreamController<RealtimeFrame>.broadcast();

  /// The [ready] calls still waiting.
  final Set<_Wait> _waits = {};

  /// Why this lease no longer serves, once it was released or its connection
  /// closed.
  RealtimeUnavailableException? _ended;

  @override
  String get namespace => _namespace.name;

  @override
  bool get connected => _ended == null && _namespace.connected;

  @override
  Stream<RealtimeFrame> get frames => _frames.stream;

  @override
  Future<void> ready({Duration timeout = RealtimeConnection.connectTimeout}) {
    final ended = _ended;
    if (ended != null) return Future<void>.error(ended);
    return _namespace.ready(this, timeout);
  }

  @override
  void emit(String event, Object? data) {
    if (connected) _namespace.socket.emit(event, data);
  }

  @override
  Future<void> release() async {
    if (_ended != null) return;
    end(
      RealtimeUnavailableException(
        'This lease on the $namespace namespace was released',
      ),
    );
    _namespace.release(this);
  }

  /// Waits for the namespace to settle, for at most [timeout].
  Future<void> wait(
    Duration timeout, {
    required void Function(Duration timeout) onTimeout,
  }) {
    final wait = _Wait(timeout, () => onTimeout(timeout));
    _waits.add(wait);
    return wait.future;
  }

  /// Ends every wait: in success, or with [failure].
  void settle([RealtimeUnavailableException? failure]) {
    final waits = [..._waits];
    _waits.clear();
    for (final wait in waits) {
      wait.settle(failure);
    }
  }

  void hear(RealtimeFrame frame) {
    if (_ended == null) _frames.add(frame);
  }

  /// Ends this lease with [why]: its waits throw it, and its frames are done.
  void end(RealtimeUnavailableException why) {
    _ended = why;
    settle(why);
    unawaited(_frames.close());
  }
}

/// One [_Lease.ready] call waiting, with its timer.
final class _Wait {
  _Wait(Duration timeout, void Function() onTimeout) {
    _timer = Timer(timeout, onTimeout);
  }

  final Completer<void> _completer = Completer<void>();
  late final Timer _timer;

  Future<void> get future => _completer.future;

  void settle(RealtimeUnavailableException? failure) {
    _timer.cancel();
    if (_completer.isCompleted) return;
    if (failure == null) {
      _completer.complete();
    } else {
      _completer.completeError(failure);
    }
  }
}
