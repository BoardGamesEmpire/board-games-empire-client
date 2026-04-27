import 'package:freezed_annotation/freezed_annotation.dart';

/// Lifecycle states for a BGE server context.
///
/// State machine transitions:
/// ```
/// disconnected → active           (user connects)
/// active → backgrounding          (user switches away; co-active window begins)
/// backgrounding → active          (user switches back within timeout)
/// backgrounding → monitoring      (timeout expires or battery threshold)
/// monitoring → active             (user re-activates server)
/// any → disconnected              (explicit disconnect or unrecoverable error)
/// ```
enum ConnectionState {
  /// No connection. DB and WS are closed. Default state for newly added servers.
  @JsonValue('Disconnected')
  disconnected,

  /// Full foreground connection. WS open, all repos live, DB open.
  @JsonValue('Active')
  active,

  /// Co-active window after the user switched to another server.
  /// WS and DB remain open for [DevicePreferences.backgroundingTimeoutSeconds]
  /// (or the per-server override). In-flight and new operations are allowed.
  /// Transitions to [monitoring] on timeout or battery threshold.
  @JsonValue('Backgrounding')
  backgrounding,

  /// Passive connection. WS closed, DB closed.
  /// Notifications are received via OS push (post-MVP) and written as
  /// lightweight summaries to the root DB only.
  @JsonValue('Monitoring')
  monitoring,
}
