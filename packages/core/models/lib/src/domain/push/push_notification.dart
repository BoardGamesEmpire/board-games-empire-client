import 'package:freezed_annotation/freezed_annotation.dart';

part 'push_notification.freezed.dart';
part 'push_notification.g.dart';

/// A received push notification, as surfaced to the app by
/// `PushNotificationService.watchIncoming()` (#15).
///
/// [localServerId] is **resolved by the implementation**: the platform
/// payload carries only the originating server's own identity, which the
/// implementation maps to the client-local id via the persisted
/// [PushRegistration] record before emitting.
///
/// Privacy: payloads stay minimal (title + body). Sensitive content is
/// fetched after the app opens via the regular authenticated channels;
/// [data] and [deepLink] exist to support that pattern, not to carry
/// content. Persistence into the root-DB notification feed is
/// `NotificationSummary`'s job, not this type's.
@freezed
abstract class PushNotification with _$PushNotification {
  const factory PushNotification({
    /// Client-local CUID of the originating server. FK to
    /// `ServerConfig.id` in the root DB.
    required String localServerId,

    required String title,
    required String body,

    /// Opaque payload extras (e.g. entity ids for post-open fetch).
    Map<String, Object?>? data,

    /// Optional `bge://` deep link to open on tap (#10, #82).
    String? deepLink,
  }) = _PushNotification;

  factory PushNotification.fromJson(Map<String, dynamic> json) =>
      _$PushNotificationFromJson(json);
}
