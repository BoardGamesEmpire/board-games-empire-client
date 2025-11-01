import 'package:drift/drift.dart';
import 'package:interfaces/interfaces.dart';
import 'package:models/domain.dart';
import 'package:injectable/injectable.dart';
import '../databases/meta_database.dart';
import 'package:cuid2/cuid2.dart';

@LazySingleton(as: ServerRepository)
class ServerRepositoryImpl implements ServerRepository {
  final MetaDatabase _database;

  ServerRepositoryImpl(this._database);

  @override
  Future<ServerConfig> addServer({
    required String displayName,
    required String serverUrl,
    Map<String, dynamic>? metadata,
  }) async {
    // Check for duplicate URL
    final existing = await (_database.select(
      _database.serverConfigs,
    )..where((tbl) => tbl.serverUrl.equals(serverUrl))).getSingleOrNull();

    if (existing != null) {
      throw DuplicateServerException(serverUrl);
    }

    final now = DateTime.now().toUtc();
    final config = ServerConfigsCompanion.insert(
      id: cuid(),
      displayName: displayName,
      serverUrl: serverUrl,
      connectionState: ConnectionState.disconnected.toJsonValue(),
      metadata: Value(metadata ?? {}),
      lastActiveAt: Value(null),
      createdAt: Value(now),
      updatedAt: Value(now),
    );

    await _database.into(_database.serverConfigs).insert(config);

    final inserted = await (_database.select(
      _database.serverConfigs,
    )..where((tbl) => tbl.serverUrl.equals(serverUrl))).getSingle();

    return _mapToModel(inserted);
  }

  @override
  Future<void> removeServer(String serverId) async {
    final server = await getServer(serverId);
    if (server == null) {
      throw ServerNotFoundException(serverId);
    }

    if (server.connectionState == ConnectionState.active) {
      throw ActiveServerException(serverId);
    }

    await (_database.delete(
      _database.serverConfigs,
    )..where((tbl) => tbl.id.equals(serverId))).go();
  }

  @override
  Future<ServerConfig> updateServer(ServerConfig config) async {
    final existing = await getServer(config.id);
    if (existing == null) {
      throw ServerNotFoundException(config.id);
    }

    final companion = ServerConfigsCompanion(
      id: Value(config.id),
      displayName: Value(config.displayName),
      serverUrl: Value(config.serverUrl),
      metadata: Value(config.metadata),
      updatedAt: Value(DateTime.now().toUtc()),
    );

    await (_database.update(
      _database.serverConfigs,
    )..where((tbl) => tbl.id.equals(config.id))).write(companion);

    return (await getServer(config.id))!;
  }

  @override
  Future<ServerConfig> updateConnectionState({
    required String serverId,
    required ConnectionState newState,
  }) async {
    return await _database.transaction(() async {
      final server = await getServer(serverId);
      if (server == null) {
        throw ServerNotFoundException(serverId);
      }

      // If transitioning to connected state, enforce capacity
      if (newState != ConnectionState.disconnected &&
          server.connectionState == ConnectionState.disconnected) {
        final currentCount = await getMonitoredCount();
        // Note: maxMonitoringCapacity should be injected or configured
        // For now using hardcoded 5 as specified
        const maxCapacity = 5;

        if (currentCount >= maxCapacity) {
          // TODO: open a dialog or notify user about capacity limit
          throw ServerCapacityExceededException(
            currentMonitored: currentCount,
            maxCapacity: maxCapacity,
          );
        }
      }

      final companion = ServerConfigsCompanion(
        connectionState: Value(newState.toJsonValue()),
        updatedAt: Value(DateTime.now().toUtc()),
      );

      await (_database.update(
        _database.serverConfigs,
      )..where((tbl) => tbl.id.equals(serverId))).write(companion);

      return (await getServer(serverId))!;
    });
  }

  @override
  Future<ServerConfig?> getServer(String serverId) async {
    final result = await (_database.select(
      _database.serverConfigs,
    )..where((tbl) => tbl.id.equals(serverId))).getSingleOrNull();

    return result != null ? _mapToModel(result) : null;
  }

  @override
  Future<List<ServerConfig>> getAllServers() async {
    final results = await _database.select(_database.serverConfigs).get();
    return results.map(_mapToModel).toList();
  }

  @override
  Future<List<ServerConfig>> getMonitoredServers() async {
    final results =
        await (_database.select(_database.serverConfigs)..where(
              (tbl) =>
                  tbl.connectionState.equals(
                    ConnectionState.active.toJsonValue(),
                  ) |
                  tbl.connectionState.equals(
                    ConnectionState.monitoring.toJsonValue(),
                  ),
            ))
            .get();

    return results.map(_mapToModel).toList();
  }

  @override
  Future<List<ServerConfig>> getDisconnectedServers() async {
    final results =
        await (_database.select(_database.serverConfigs)..where(
              (tbl) => tbl.connectionState.equals(
                ConnectionState.disconnected.toJsonValue(),
              ),
            ))
            .get();

    return results.map(_mapToModel).toList();
  }

  @override
  Future<int> getMonitoredCount() async {
    final count =
        await (_database.selectOnly(_database.serverConfigs)
              ..addColumns([_database.serverConfigs.id.count()])
              ..where(
                _database.serverConfigs.connectionState.equals(
                      ConnectionState.active.toJsonValue(),
                    ) |
                    _database.serverConfigs.connectionState.equals(
                      ConnectionState.monitoring.toJsonValue(),
                    ),
              ))
            .getSingle();

    return count.read(_database.serverConfigs.id.count()) ?? 0;
  }

  @override
  Future<void> updateLastActive(String serverId, DateTime timestamp) async {
    final companion = ServerConfigsCompanion(
      lastActiveAt: Value(timestamp.toUtc()),
      updatedAt: Value(DateTime.now().toUtc()),
    );

    await (_database.update(
      _database.serverConfigs,
    )..where((tbl) => tbl.id.equals(serverId))).write(companion);
  }

  @override
  Stream<List<ServerConfig>> watchServers() {
    return _database
        .select(_database.serverConfigs)
        .watch()
        .map((rows) => rows.map(_mapToModel).toList());
  }

  @override
  Stream<int> watchMonitoredCount() {
    return (_database.selectOnly(_database.serverConfigs)
          ..addColumns([_database.serverConfigs.id.count()])
          ..where(
            _database.serverConfigs.connectionState.equals(
                  ConnectionState.active.toJsonValue(),
                ) |
                _database.serverConfigs.connectionState.equals(
                  ConnectionState.monitoring.toJsonValue(),
                ),
          ))
        .watchSingle()
        .map((row) => row.read(_database.serverConfigs.id.count()) ?? 0);
  }

  ServerConfig _mapToModel(ServerConfigData data) {
    return ServerConfig(
      id: data.id,
      displayName: data.displayName,
      serverUrl: data.serverUrl,
      connectionState: _parseConnectionState(data.connectionState),
      lastActiveAt: data.lastActiveAt,
      metadata: data.metadata,
      createdAt: data.createdAt,
      updatedAt: data.updatedAt,
    );
  }

  ConnectionState _parseConnectionState(String value) {
    switch (value) {
      case 'Active':
        return ConnectionState.active;
      case 'Monitoring':
        return ConnectionState.monitoring;
      case 'Disconnected':
        return ConnectionState.disconnected;
      default:
        throw ArgumentError('Unknown connection state: $value');
    }
  }
}

extension on ConnectionState {
  String toJsonValue() {
    switch (this) {
      case ConnectionState.active:
        return 'Active';
      case ConnectionState.monitoring:
        return 'Monitoring';
      case ConnectionState.disconnected:
        return 'Disconnected';
    }
  }
}
