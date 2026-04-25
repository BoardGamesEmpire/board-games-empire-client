import 'package:freezed_annotation/freezed_annotation.dart';
import 'connection_state.dart';
import 'server_identity.dart';

part 'server_config.freezed.dart';
part 'server_config.g.dart';

/// Local client-side record for a configured BGE server.
///
/// [id] is a client-generated cuid used as the root DB primary key.
/// [bgeServerId] is the stable UUID vended by the server via
/// /.well-known/bge-identity. Null on schema migration for pre-existing rows;
/// always set for newly added servers.
///
/// [cachedIdentity] is the last-known [ServerIdentity] fetched from the
/// server. Null until first successful identity fetch. Stored as JSON in the
/// DB and deserialized on read.
@freezed
abstract class ServerConfig with _$ServerConfig {
  const ServerConfig._();

  const factory ServerConfig({
    /// Client-generated local identifier (cuid). Root DB primary key.
    required String id,
    required String displayName,
    required String serverUrl,
    required ConnectionState connectionState,

    /// Stable server-vended UUID (`bge_server_id` from well-known doc).
    required String bgeServerId,

    /// Last known server identity document.
    /// Re-fetched when [isIdentityStale] is true.
    required ServerIdentity cachedIdentity,

    required DateTime lastIdentityFetchedAt,
    DateTime? lastActiveAt,

    /// Per-server backgrounding timeout override (seconds).
    /// Null = use the device-level [DevicePreferences] default.
    int? backgroundingTimeoutSeconds,

    @Default({}) Map<String, dynamic> metadata,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _ServerConfig;

  factory ServerConfig.fromJson(Map<String, dynamic> json) =>
      _$ServerConfigFromJson(json);

  bool get isConnected =>
      connectionState == ConnectionState.active ||
      connectionState == ConnectionState.backgrounding ||
      connectionState == ConnectionState.monitoring;

  bool get isActive => connectionState == ConnectionState.active;
  bool get isBackgrounding => connectionState == ConnectionState.backgrounding;
  bool get isMonitoring => connectionState == ConnectionState.monitoring;
  bool get isDisconnected => connectionState == ConnectionState.disconnected;

  /// Whether a server-vended UUID has been obtained.
  bool get hasIdentity => bgeServerId != null;

  /// Whether the cached identity should be refreshed.
  /// True if never fetched, or if older than the server's Cache-Control
  /// max-age of 3600 seconds.
  bool get isIdentityStale {
    final fetched = lastIdentityFetchedAt;
    return DateTime.now().toUtc().difference(fetched).inHours >= 1;
  }

  /// Relative path for the per-server Drift DB file.
  /// Resolved against the app support directory by the storage layer.
  String get databasePath => 'servers/$id/server.db';
}
