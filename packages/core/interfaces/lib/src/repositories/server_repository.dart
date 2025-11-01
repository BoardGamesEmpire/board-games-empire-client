import 'package:models/domain.dart';

abstract class ServerRepository {
  /// Adds a new server configuration in disconnected state
  /// Throws [DuplicateServerException] if URL already exists
  Future<ServerConfig> addServer({
    required String displayName,
    required String serverUrl,
    Map<String, dynamic>? metadata,
  });

  /// Removes server configuration and all associated data
  /// This is destructive and cannot be undone
  /// Throws [ServerNotFoundException] if server doesn't exist
  /// Throws [ActiveServerException] if attempting to remove active server
  Future<void> removeServer(String serverId);

  /// Updates server metadata and display name
  /// Connection state changes must use dedicated methods
  Future<ServerConfig> updateServer(ServerConfig config);

  /// Updates connection state with capacity enforcement
  /// Throws [ServerCapacityExceededException] when attempting to connect
  /// beyond monitoring capacity
  Future<ServerConfig> updateConnectionState({
    required String serverId,
    required ConnectionState newState,
  });

  /// Retrieves single server configuration
  /// Returns null if server doesn't exist
  Future<ServerConfig?> getServer(String serverId);

  /// Retrieves all configured servers regardless of connection state
  Future<List<ServerConfig>> getAllServers();

  /// Retrieves only servers in active or monitoring states
  Future<List<ServerConfig>> getMonitoredServers();

  /// Retrieves servers in disconnected state
  Future<List<ServerConfig>> getDisconnectedServers();

  /// Counts currently monitored servers against capacity
  Future<int> getMonitoredCount();

  /// Updates last active timestamp
  Future<void> updateLastActive(String serverId, DateTime timestamp);

  /// Stream of server configuration changes
  Stream<List<ServerConfig>> watchServers();

  /// Stream of monitored server count changes
  Stream<int> watchMonitoredCount();
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
