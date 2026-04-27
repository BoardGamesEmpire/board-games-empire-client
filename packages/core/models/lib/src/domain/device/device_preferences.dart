import 'package:freezed_annotation/freezed_annotation.dart';

part 'device_preferences.freezed.dart';
part 'device_preferences.g.dart';

/// Device-level preferences governing multi-server connection behavior.
///
/// These are personal client settings, not server-side concerns. Stored in
/// the root DB as a single row (upserted on change). The orchestrator reads
/// these before making connection and backgrounding decisions.
///
/// Battery-aware transition thresholds are included in the schema now for
/// forward-compatibility — [batteryAwareTransitions] defaults to false until
/// that feature is implemented.
@freezed
abstract class DevicePreferences with _$DevicePreferences {
  const DevicePreferences._();

  const factory DevicePreferences({
    /// Maximum number of servers that may be in [ConnectionState.active],
    /// [ConnectionState.backgrounding], or [ConnectionState.monitoring] at
    /// once. User-configurable. Enforced by [ServerOrchestrator].
    @Default(5) int maxMonitoredServers,

    /// How long (seconds) a server stays in [ConnectionState.backgrounding]
    /// on desktop before transitioning to [ConnectionState.monitoring].
    /// Desktop default: 15 minutes.
    @Default(900) int backgroundingTimeoutDesktopSeconds,

    /// How long (seconds) a server stays in [ConnectionState.backgrounding]
    /// on mobile before transitioning to [ConnectionState.monitoring].
    /// Mobile default: 5 minutes.
    @Default(300) int backgroundingTimeoutMobileSeconds,

    /// When true, battery level influences backgrounding timeout duration.
    /// Disabled by default — battery awareness is post-MVP.
    @Default(false) bool batteryAwareTransitions,
  }) = _DevicePreferences;

  factory DevicePreferences.fromJson(Map<String, dynamic> json) =>
      _$DevicePreferencesFromJson(json);

  /// Returns the appropriate backgrounding timeout for the current platform.
  int backgroundingTimeoutSeconds({required bool isDesktop}) => isDesktop
      ? backgroundingTimeoutDesktopSeconds
      : backgroundingTimeoutMobileSeconds;
}
