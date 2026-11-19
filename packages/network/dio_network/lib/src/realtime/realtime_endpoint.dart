import 'package:flutter/foundation.dart' show immutable;

/// Where a server's socket connects, and the credential its handshake sends
/// (#473).
///
/// The server scope registers one, native's in `registerServerNetwork` and
/// web's in `registerServerNetworkWeb`, and the user scope's
/// `RealtimeInstaller` builds the session's connection from it.
@immutable
final class RealtimeEndpoint {
  const RealtimeEndpoint({required this.server, this.token});

  /// The server's URL, as the user added it. Its path is kept: a server
  /// reached under a prefix serves its socket under that prefix too.
  final Uri server;

  /// Reads the token the handshake sends, or null to send none.
  ///
  /// Called on every connect and reconnect, never once and kept, so the
  /// handshake carries the token as it is then. Null on web, where the
  /// browser sends the session cookie with the socket's upgrade request.
  final Future<String?> Function()? token;
}
