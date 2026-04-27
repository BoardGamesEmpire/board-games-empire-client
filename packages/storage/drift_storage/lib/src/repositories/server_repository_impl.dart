import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:injectable/injectable.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:cuid2/cuid2.dart';

import '../databases/meta_database.dart';

@LazySingleton(as: ServerRepository)
class ServerRepositoryImpl implements ServerRepository {
  ServerRepositoryImpl(this._database);

  final MetaDatabase _database;

  @override
  Future<ServerConfig> addServer({
    required String displayName,
    required String serverUrl,
    required String bgeServerId,
    required ServerIdentity identity,
    int? backgroundingTimeoutSeconds,
    Map<String, dynamic>? metadata,
  }) async {
    final existingUrl = await (_database.select(
      _database.serverConfigs,
    )..where((t) => t.serverUrl.equals(serverUrl))).getSingleOrNull();
    if (existingUrl != null) throw DuplicateServerException(serverUrl);

    final existingId = await (_database.select(
      _database.serverConfigs,
    )..where((t) => t.bgeServerId.equals(bgeServerId))).getSingleOrNull();
    if (existingId != null) throw DuplicateServerException(serverUrl);

    final now = DateTime.now().toUtc();
    final id = cuid();

    await _database
        .into(_database.serverConfigs)
        .insert(
          ServerConfigsCompanion.insert(
            id: id,
            bgeServerId: bgeServerId,
            displayName: displayName,
            serverUrl: serverUrl,
            connectionState: ConnectionState.disconnected.toJsonValue(),
            cachedIdentityJson: jsonEncode(identity.toJson()),
            lastIdentityFetchedAt: now,
            lastActiveAt: const Value(null),
            backgroundingTimeoutSeconds: Value(backgroundingTimeoutSeconds),
            metadata: Value(metadata ?? {}),
            createdAt: now,
            updatedAt: now,
          ),
        );

    return (await getServer(id))!;
  }

  @override
  Future<void> removeServer(String serverId) async {
    final server = await getServer(serverId);
    if (server == null) throw ServerNotFoundException(serverId);
    if (server.isActive) throw ActiveServerException(serverId);

    await (_database.delete(
      _database.serverConfigs,
    )..where((t) => t.id.equals(serverId))).go();
  }

  @override
  Future<ServerConfig> updateServer(ServerConfig config) async {
    if (await getServer(config.id) == null) {
      throw ServerNotFoundException(config.id);
    }

    await (_database.update(
      _database.serverConfigs,
    )..where((t) => t.id.equals(config.id))).write(
      ServerConfigsCompanion(
        displayName: Value(config.displayName),
        serverUrl: Value(config.serverUrl),
        backgroundingTimeoutSeconds: Value(config.backgroundingTimeoutSeconds),
        metadata: Value(config.metadata),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );

    return (await getServer(config.id))!;
  }

  Future<ServerConfig> cacheIdentity({
    required String serverId,
    required ServerIdentity identity,
  }) async {
    if (await getServer(serverId) == null) {
      throw ServerNotFoundException(serverId);
    }

    await (_database.update(
      _database.serverConfigs,
    )..where((t) => t.id.equals(serverId))).write(
      ServerConfigsCompanion(
        cachedIdentityJson: Value(jsonEncode(identity.toJson())),
        lastIdentityFetchedAt: Value(DateTime.now().toUtc()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );

    return (await getServer(serverId))!;
  }

  @override
  Future<ServerConfig> updateConnectionState({
    required String serverId,
    required ConnectionState newState,
  }) async {
    if (await getServer(serverId) == null) {
      throw ServerNotFoundException(serverId);
    }

    await (_database.update(
      _database.serverConfigs,
    )..where((t) => t.id.equals(serverId))).write(
      ServerConfigsCompanion(
        connectionState: Value(newState.toJsonValue()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );

    return (await getServer(serverId))!;
  }

  @override
  Future<ServerConfig?> getServer(String serverId) async {
    final row = await (_database.select(
      _database.serverConfigs,
    )..where((t) => t.id.equals(serverId))).getSingleOrNull();
    return row != null ? _mapToModel(row) : null;
  }

  @override
  Future<ServerConfig?> getServerByBgeId(String bgeServerId) async {
    final row = await (_database.select(
      _database.serverConfigs,
    )..where((t) => t.bgeServerId.equals(bgeServerId))).getSingleOrNull();
    return row != null ? _mapToModel(row) : null;
  }

  @override
  Future<List<ServerConfig>> getAllServers() async {
    final rows = await _database.select(_database.serverConfigs).get();
    return rows.map(_mapToModel).toList();
  }

  @override
  Future<List<ServerConfig>> getConnectedServers() async {
    final rows =
        await (_database.select(_database.serverConfigs)..where(
              (t) =>
                  t.connectionState.equals(
                    ConnectionState.active.toJsonValue(),
                  ) |
                  t.connectionState.equals(
                    ConnectionState.backgrounding.toJsonValue(),
                  ) |
                  t.connectionState.equals(
                    ConnectionState.monitoring.toJsonValue(),
                  ),
            ))
            .get();
    return rows.map(_mapToModel).toList();
  }

  @override
  Future<List<ServerConfig>> getDisconnectedServers() async {
    final rows =
        await (_database.select(_database.serverConfigs)..where(
              (t) => t.connectionState.equals(
                ConnectionState.disconnected.toJsonValue(),
              ),
            ))
            .get();
    return rows.map(_mapToModel).toList();
  }

  @override
  Future<int> getConnectedCount() async {
    final expr = _database.serverConfigs.id.count();
    final result =
        await (_database.selectOnly(_database.serverConfigs)
              ..addColumns([expr])
              ..where(
                _database.serverConfigs.connectionState.equals(
                      ConnectionState.active.toJsonValue(),
                    ) |
                    _database.serverConfigs.connectionState.equals(
                      ConnectionState.backgrounding.toJsonValue(),
                    ) |
                    _database.serverConfigs.connectionState.equals(
                      ConnectionState.monitoring.toJsonValue(),
                    ),
              ))
            .getSingle();
    return result.read(expr) ?? 0;
  }

  @override
  Future<void> updateLastActive(String serverId, DateTime timestamp) async {
    await (_database.update(
      _database.serverConfigs,
    )..where((t) => t.id.equals(serverId))).write(
      ServerConfigsCompanion(
        lastActiveAt: Value(timestamp.toUtc()),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  }

  @override
  Stream<List<ServerConfig>> watchServers() => _database
      .select(_database.serverConfigs)
      .watch()
      .map((rows) => rows.map(_mapToModel).toList());

  @override
  Stream<int> watchConnectedCount() {
    final expr = _database.serverConfigs.id.count();
    return (_database.selectOnly(_database.serverConfigs)
          ..addColumns([expr])
          ..where(
            _database.serverConfigs.connectionState.equals(
                  ConnectionState.active.toJsonValue(),
                ) |
                _database.serverConfigs.connectionState.equals(
                  ConnectionState.backgrounding.toJsonValue(),
                ) |
                _database.serverConfigs.connectionState.equals(
                  ConnectionState.monitoring.toJsonValue(),
                ),
          ))
        .watchSingle()
        .map((row) => row.read(expr) ?? 0);
  }

  ServerConfig _mapToModel(ServerConfigData data) {
    ServerIdentity identity = ServerIdentity.fromJson(
      jsonDecode(data.cachedIdentityJson) as Map<String, dynamic>,
    );

    return ServerConfig(
      id: data.id,
      bgeServerId: data.bgeServerId,
      displayName: data.displayName,
      serverUrl: data.serverUrl,
      connectionState: _parseConnectionState(data.connectionState),
      cachedIdentity: identity,
      lastIdentityFetchedAt: data.lastIdentityFetchedAt,
      lastActiveAt: data.lastActiveAt,
      backgroundingTimeoutSeconds: data.backgroundingTimeoutSeconds,
      metadata: data.metadata,
      createdAt: data.createdAt,
      updatedAt: data.updatedAt,
    );
  }

  static ConnectionState _parseConnectionState(String value) => switch (value) {
    'Active' => ConnectionState.active,
    'Backgrounding' => ConnectionState.backgrounding,
    'Monitoring' => ConnectionState.monitoring,
    'Disconnected' => ConnectionState.disconnected,
    _ => throw ArgumentError('Unknown ConnectionState: $value'),
  };
}

extension _ConnectionStateJson on ConnectionState {
  String toJsonValue() => switch (this) {
    ConnectionState.active => 'Active',
    ConnectionState.backgrounding => 'Backgrounding',
    ConnectionState.monitoring => 'Monitoring',
    ConnectionState.disconnected => 'Disconnected',
  };
}
