/// One frame a leased namespace heard: a server event's name and its payload,
/// or [RealtimeLease.disconnectEvent] when the connection dropped (#473).
typedef RealtimeFrame = ({String event, Object? data});

/// The session's socket connection to its server (#473).
///
/// There is one per server and signed-in session. The user-session scope owns
/// it, so it ends with the session, and the next sign-in opens its own with
/// its own credential.
///
/// Features never open sockets of their own. Each takes a [RealtimeLease] on
/// its namespace (`games/search`, and later import events and chat), and
/// every namespace is multiplexed over the one connection. A screen holds its
/// lease while it shows and releases it when it goes. Listening off-screen is
/// the job of a holder that lives as long as the session, never of a page.
abstract interface class RealtimeConnection {
  /// How long [RealtimeLease.ready] waits, by default, for a namespace that
  /// is still connecting.
  static const Duration connectTimeout = Duration(seconds: 5);

  /// Takes a lease on [namespace], such as `games/search`. The leading `/` is
  /// optional: `games/search` and `/games/search` are one namespace.
  ///
  /// The first lease on a namespace connects it, and later ones share its
  /// socket. Throws [StateError] once the connection is closed.
  RealtimeLease lease(String namespace);

  /// Disconnects every namespace and ends every lease, as the session ends.
  /// Later [lease]s throw. Idempotent.
  ///
  /// The session's teardown calls this. A feature releases its leases
  /// instead.
  Future<void> close();
}

/// A feature's hold on one namespace of the session's [RealtimeConnection]
/// (#473).
///
/// The namespace stays connected while any lease on it is held, and
/// disconnects when the last one is released.
abstract interface class RealtimeLease {
  /// The event of the frame [frames] carries when a connected namespace loses
  /// its connection. socket.io reserves the name, so no server event has it.
  static const String disconnectEvent = 'disconnect';

  /// The namespace, with its leading `/`.
  String get namespace;

  /// Whether the namespace is connected now. False once the lease is
  /// released.
  bool get connected;

  /// Completes once the namespace is connected, and at once while it is.
  ///
  /// Waits only while the namespace is connecting, and at most [timeout].
  /// Throws [RealtimeUnavailableException] when the server refuses the
  /// handshake, when the connect fails, or when the wait runs out. Once a
  /// connect has failed on the way or outrun a wait, every call throws at
  /// once until the namespace connects, as socket.io goes on retrying it. So
  /// a caller with another way to do its work, as search has REST, never
  /// waits on a socket that is down.
  ///
  /// A namespace the server refused or disconnected is the exception:
  /// socket.io never retries it, so a call connects it again and waits, as
  /// on a first connect. A refusal can pass, and a lease can last a screen's
  /// whole life.
  ///
  /// It also throws at once after [release], and a wait still running then
  /// ends with the throw.
  Future<void> ready({Duration timeout = RealtimeConnection.connectTimeout});

  /// Every event the server sends on the namespace, in order, and a
  /// [disconnectEvent] frame each time a connected namespace drops. Done once
  /// the lease is released or the connection closed.
  ///
  /// Broadcast: a frame no one listens for is lost. So is everything sent
  /// while the namespace was down, as the server replays nothing after a
  /// reconnect.
  Stream<RealtimeFrame> get frames;

  /// Sends [event] with [data] as its one argument, while [connected].
  ///
  /// A frame sent while the namespace is down is dropped, not held for the
  /// next connect. The server forgets a connection's work when it drops (the
  /// search gateway cancels its searches), so a frame sent late would start
  /// work no one is waiting for.
  void emit(String event, Object? data);

  /// Lets go of the namespace: [frames] is done, and a [ready] still waiting
  /// throws. Idempotent: a second release changes nothing, and never lets go
  /// of another lease's hold.
  Future<void> release();
}

/// The socket can't serve a namespace now (#473): the server refused the
/// handshake, the connect failed, or it didn't connect in time.
///
/// A caller with another way to do its work, as search has REST, takes it.
final class RealtimeUnavailableException implements Exception {
  const RealtimeUnavailableException(
    this.message, {
    this.statusCode,
    this.cause,
  });

  /// This client's own account of what happened.
  final String message;

  /// The status the server refused the handshake with: 401 without a live
  /// session, 403 for an anonymous one. Null when it didn't refuse.
  final int? statusCode;

  /// What socket.io reported, when it reported anything.
  final Object? cause;

  @override
  String toString() =>
      'RealtimeUnavailableException(message: $message, '
      'statusCode: $statusCode)';
}
