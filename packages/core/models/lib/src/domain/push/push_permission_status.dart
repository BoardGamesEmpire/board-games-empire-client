/// Platform notification-permission state (#15).
///
/// Device-local runtime value: never serialized, never persisted, never
/// crosses the wire — it is read fresh from the platform each time.
/// Modeled as an enum rather than a nullable bool so consumers switch
/// exhaustively and the "not yet asked" state is a first-class value.
enum PushPermissionStatus {
  /// The user has not been asked yet. The UI may offer a just-in-time
  /// permission prompt when the user opts into a push-needing feature.
  notDetermined,

  /// The user explicitly denied permission. Re-prompting is
  /// platform-restricted; the UI should route to system settings instead.
  denied,

  /// Full permission granted.
  granted,

  /// APNs provisional authorization (iOS/macOS): notifications are
  /// delivered quietly to the notification center without interrupting.
  /// Unused on other platforms.
  provisional,
}
