import 'package:freezed_annotation/freezed_annotation.dart';

import 'push_platform.dart';

part 'push_registration.freezed.dart';
part 'push_registration.g.dart';

/// A device's push registration with one BGE server (#15).
///
/// Multi-server: each server gets its own independent registration for
/// the same user/device — the same user on the same device with three
/// servers has three of these records.
///
/// This record is the **payload → local-server resolution table**. A
/// push payload can only carry the originating server's own identity
/// ([bgeServerId]) — servers never know client-local ids — so the
/// receiving implementation looks the payload's server identity up here
/// to produce the client-local `PushNotification.localServerId`. The
/// [localServerId] / [bgeServerId] pairing mirrors `NotificationSummary`.
///
/// Persisted client-locally. The server-side wire shape of the
/// registration exchange is owned by the backend contract
/// (BoardGamesEmpire/board-games-empire-backend#186); JSON here uses
/// plain camelCase field names until that contract exists.
@freezed
abstract class PushRegistration with _$PushRegistration {
  const factory PushRegistration({
    /// Server-issued registration id, returned by the server's register
    /// endpoint. Used to unregister.
    required String registrationId,

    /// Client-local CUID of the registered server. FK to
    /// `ServerConfig.id` in the root DB. Never sent to the server.
    required String localServerId,

    /// BGE server UUID of the registered server — the identity a push
    /// payload carries, and therefore the lookup key for resolving an
    /// incoming payload to [localServerId].
    required String bgeServerId,

    /// Platform-issued token (FCM token, APNs device token, UnifiedPush
    /// endpoint, ...) uploaded to the server. Rotation handling is
    /// internal to the platform implementation, which re-uploads to
    /// every registered server on rotation.
    required String platformToken,

    /// Transport that issued [platformToken].
    required PushPlatform platform,

    /// When this registration was accepted by the server.
    required DateTime registeredAt,
  }) = _PushRegistration;

  factory PushRegistration.fromJson(Map<String, dynamic> json) =>
      _$PushRegistrationFromJson(json);
}
