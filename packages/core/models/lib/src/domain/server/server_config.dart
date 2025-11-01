import 'package:freezed_annotation/freezed_annotation.dart';
import 'connection_state.dart';

part 'server_config.freezed.dart';
part 'server_config.g.dart';

@freezed
abstract class ServerConfig with _$ServerConfig {
  const ServerConfig._();

  const factory ServerConfig({
    required String id,
    required String displayName,
    required String serverUrl,
    required ConnectionState connectionState,
    DateTime? lastActiveAt,
    @Default({}) Map<String, dynamic> metadata,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _ServerConfig;

  factory ServerConfig.fromJson(Map<String, dynamic> json) =>
      _$ServerConfigFromJson(json);

  bool get isConnected =>
      connectionState == ConnectionState.active ||
      connectionState == ConnectionState.monitoring;

  bool get isActive => connectionState == ConnectionState.active;

  bool get isMonitoring => connectionState == ConnectionState.monitoring;

  bool get isDisconnected => connectionState == ConnectionState.disconnected;

  String get databasePath => 'app_secure_storage/$id/game_empire.db';
}
