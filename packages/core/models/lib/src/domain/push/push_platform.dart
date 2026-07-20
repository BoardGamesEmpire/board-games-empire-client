/// Push transport that issued a [PushRegistration.platformToken] (#15).
///
/// Deliberately open-ended: the backend transport is the hoster's choice
/// (plugin vs. env config — backend investigation
/// BoardGamesEmpire/board-games-empire-backend#186), and the Android
/// transport decision (UnifiedPush vs. FCM) is unresolved (#111).
///
/// Serialization uses the default `json_serializable` behaviour (Dart
/// enum name), producing `'fcm'`, `'apns'`, `'webPush'`, `'unifiedPush'`,
/// `'unsupported'`. Today this value is only persisted client-locally;
/// the server-side wire casing is owned by the backend registration
/// contract (#186) and `@JsonValue` annotations will be added here if
/// that contract lands on a different casing.
enum PushPlatform {
  /// Firebase Cloud Messaging (Google-brokered Android transport).
  fcm,

  /// Apple Push Notification service (iOS/macOS).
  apns,

  /// Browser Push API (service worker + VAPID). Web support is a
  /// go/no-go investigation (#113).
  webPush,

  /// UnifiedPush (FOSS distributor-based Android transport; FCM can be
  /// one distributor under it).
  unifiedPush,

  /// No push transport on this platform build. The value carried by
  /// the `UnsupportedPushNotificationService` era and by platforms with
  /// no transport (e.g. Windows/Linux today).
  unsupported,
}
