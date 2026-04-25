import 'package:drift/drift.dart';
import 'dart:convert';

@DataClassName('ServerConfigData')
class ServerConfigs extends Table {
  /// Client-generated CUID. Local primary key.
  TextColumn get id => text()();

  /// Stable UUID vended by the server via /.well-known/bge-identity.
  /// UNIQUE constraint ensures the same BGE instance is never added twice.
  TextColumn get bgeServerId =>
      text().named('bge_server_id').customConstraint('UNIQUE NOT NULL')();

  TextColumn get displayName => text().named('display_name')();

  TextColumn get serverUrl => text()
      .named('server_url')
      .customConstraint('UNIQUE COLLATE NOCASE NOT NULL')();

  TextColumn get connectionState => text().named('connection_state')();

  /// Serialized [ServerIdentity] JSON.
  TextColumn get cachedIdentityJson => text().named('cached_identity_json')();

  /// UTC timestamp of last successful identity fetch.
  DateTimeColumn get lastIdentityFetchedAt =>
      dateTime().named('last_identity_fetched_at')();
  DateTimeColumn get lastActiveAt =>
      dateTime().named('last_active_at').nullable()();

  /// Per-server backgrounding timeout override (seconds).
  /// Null = use device-level [DevicePreferences] value.
  IntColumn get backgroundingTimeoutSeconds =>
      integer().named('backgrounding_timeout_seconds').nullable()();

  TextColumn get metadata =>
      text().map(const JsonMapConverter()).withDefault(const Constant('{}'))();

  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();

  @override
  Set<Column> get primaryKey => {id};
}

class JsonMapConverter extends TypeConverter<Map<String, dynamic>, String> {
  const JsonMapConverter();

  @override
  Map<String, dynamic> fromSql(String fromDb) =>
      json.decode(fromDb) as Map<String, dynamic>;

  @override
  String toSql(Map<String, dynamic> value) => json.encode(value);
}
