import 'dart:convert';

import 'package:drift/drift.dart';

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

  /// Serialized `ServerIdentity` JSON.
  TextColumn get cachedIdentityJson => text().named('cached_identity_json')();

  /// UTC timestamp of last successful identity fetch.
  DateTimeColumn get lastIdentityFetchedAt =>
      dateTime().named('last_identity_fetched_at')();
  DateTimeColumn get lastActiveAt =>
      dateTime().named('last_active_at').nullable()();

  /// Per-server backgrounding timeout override (seconds).
  /// Null = use device-level `DevicePreferences` value.
  IntColumn get backgroundingTimeoutSeconds =>
      integer().named('backgrounding_timeout_seconds').nullable()();

  TextColumn get metadata =>
      text().map(const JsonMapConverter()).withDefault(const Constant('{}'))();

  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();

  /// UTC time the stored session was marked as not to be restored, or null
  /// when it hasn't been (#356). Written only by `SessionTombstoneStoreImpl`,
  /// so it never moves [updatedAt].
  ///
  /// A column and not a key in [metadata]: `updateServer` rewrites
  /// [metadata] from the caller's in-memory config, which would overwrite a
  /// marker written since that config was read.
  DateTimeColumn get sessionRevokedAt =>
      dateTime().named('session_revoked_at').nullable()();

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
