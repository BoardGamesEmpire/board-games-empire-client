import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:cuid2/cuid2.dart';

import '../databases/meta_database.dart';

class ServerRepositoryImpl implements ServerRepository {
  ServerRepositoryImpl(this._database);

  final MetaDatabase _database;

  /// The table's UNIQUE constraints on `server_url` and `bge_server_id` are
  /// what keeps a server from being added twice (#184). The two lookups
  /// before the insert only answer the common case without one: two adds
  /// can both pass them, and the second insert then breaks a constraint,
  /// which leaves as the same [DuplicateServerException].
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
    if (existingUrl != null) throw DuplicateServerException.url(serverUrl);

    final existingId = await (_database.select(
      _database.serverConfigs,
    )..where((t) => t.bgeServerId.equals(bgeServerId))).getSingleOrNull();
    if (existingId != null) {
      throw DuplicateServerException.identity(bgeServerId);
    }

    final now = DateTime.now().toUtc();
    final id = cuid();

    try {
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
    } catch (error, stackTrace) {
      final duplicate = switch (_duplicateKindOf(error)) {
        DuplicateServerKind.url => DuplicateServerException.url(serverUrl),
        DuplicateServerKind.identity => DuplicateServerException.identity(
          bgeServerId,
        ),
        null => null,
      };
      if (duplicate == null) rethrow;
      Error.throwWithStackTrace(duplicate, stackTrace);
    }

    return (await getServer(id))!;
  }

  static final _uniqueViolationPattern = RegExp(
    r'UNIQUE constraint failed: server_configs\.(\w+)',
  );

  /// The uniqueness [error] reports breaking, or null when it reports
  /// something else.
  ///
  /// Read from SQLite's own message rather than the `SqliteException` type:
  /// this library is importable from web, which must never import `sqlite3`
  /// (`test/platform_boundary_test.dart`), and a database running in a
  /// background isolate wraps the exception in drift's
  /// `DriftRemoteException`, whose `toString` is the wrapped one's.
  static DuplicateServerKind? _duplicateKindOf(Object error) =>
      switch (_uniqueViolationPattern.firstMatch(error.toString())?.group(1)) {
        'server_url' => DuplicateServerKind.url,
        'bge_server_id' => DuplicateServerKind.identity,
        _ => null,
      };

  /// The check and the delete run in one transaction, so the row the check
  /// approved is the row deleted (#184).
  @override
  Future<void> removeServer(String serverId) => _database.transaction(() async {
    final server = await getServer(serverId);
    if (server == null) throw ServerNotFoundException(serverId);
    if (server.isActive) throw ActiveServerException(serverId);

    await (_database.delete(
      _database.serverConfigs,
    )..where((t) => t.id.equals(serverId))).go();
  });

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
    final ServerIdentity identity;
    try {
      identity = ServerIdentity.fromJson(
        jsonDecode(data.cachedIdentityJson) as Map<String, dynamic>,
      );
    } catch (e, stackTrace) {
      // The identity document's shape can change between app versions
      // (new required fields, renamed wire keys); a row written by an
      // older build may throw anything from a FormatException (bad
      // JSON) to a TypeError (missing required field deserialized as
      // null). Catch broadly and rethrow as a typed, actionable
      // exception rather than letting a raw TypeError escape through
      // watchServers()/getServer() and break the caller.
      //
      // Rethrow with the *original* stack trace so logs still point at
      // the actual parse/type failure inside fromJson rather than at
      // this catch site.
      Error.throwWithStackTrace(
        CorruptedServerIdentityException(data.id, e),
        stackTrace,
      );
    }

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
