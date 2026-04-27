import 'package:models/domain.dart';

/// Repository for BGE server configurations stored in the root DB.
///
/// Capacity enforcement (max monitored servers) is NOT the responsibility of
/// this repository — it belongs in [ServerOrchestrator], which has access to
/// [DevicePreferences]. This repository stores and retrieves state faithfully.
abstract class ServerRepository {
  /// Adds a new server in [ConnectionState.disconnected].
  ///
  /// [bgeServerId] is the stable UUID from /.well-known/bge-identity.
  /// [identity] is the initial cached identity (required on add since the
  /// client always fetches well-known before adding).
  ///
  /// Throws [DuplicateServerException] if [serverUrl] or [bgeServerId]
  /// already exists.
  Future<ServerConfig> addServer({
    required String displayName,
    required String serverUrl,
    required String bgeServerId,
    required ServerIdentity identity,
    int? backgroundingTimeoutSeconds,
    Map<String, dynamic>? metadata,
  });

  /// Removes server configuration.
  ///
  /// Throws [ServerNotFoundException] if not found.
  /// Throws [ActiveServerException] if server is [ConnectionState.active].
  Future<void> removeServer(String serverId);

  /// Updates display name, metadata, and backgrounding timeout.
  /// Connection state changes must use [updateConnectionState].
  ///
  /// Throws [ServerNotFoundException] if not found.
  Future<ServerConfig> updateServer(ServerConfig config);

  /// Updates connection state.
  ///
  /// Capacity enforcement is the caller's responsibility.
  /// Throws [ServerNotFoundException] if not found.
  Future<ServerConfig> updateConnectionState({
    required String serverId,
    required ConnectionState newState,
  });

  /// Returns null if not found.
  Future<ServerConfig?> getServer(String serverId);

  /// Finds a server by its BGE server UUID.
  /// Returns null if no server with that UUID is registered.
  Future<ServerConfig?> getServerByBgeId(String bgeServerId);

  Future<List<ServerConfig>> getAllServers();

  /// Active + backgrounding + monitoring servers.
  Future<List<ServerConfig>> getConnectedServers();

  Future<List<ServerConfig>> getDisconnectedServers();

  Future<int> getConnectedCount();

  Future<void> updateLastActive(String serverId, DateTime timestamp);

  Stream<List<ServerConfig>> watchServers();
  Stream<int> watchConnectedCount();
}

class DuplicateServerException implements Exception {
  final String serverUrl;
  const DuplicateServerException(this.serverUrl);
  @override
  String toString() =>
      'DuplicateServerException: Server with URL $serverUrl already exists';
}

class ServerNotFoundException implements Exception {
  final String serverId;
  const ServerNotFoundException(this.serverId);
  @override
  String toString() =>
      'ServerNotFoundException: No server found with id $serverId';
}

class ActiveServerException implements Exception {
  final String serverId;
  const ActiveServerException(this.serverId);
  @override
  String toString() =>
      'ActiveServerException: Cannot remove active server $serverId. '
      'Switch to another server first.';
}
