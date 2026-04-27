import 'package:freezed_annotation/freezed_annotation.dart';

part 'notification_summary.freezed.dart';
part 'notification_summary.g.dart';

/// Lightweight notification record stored in the root DB.
///
/// Written when a notification arrives for a server in any connection state,
/// allowing the unified notification feed and badge counts to work without
/// opening per-server DBs.
///
/// When the full notification detail is needed (e.g. user taps the item),
/// [requiresFullLoad] signals that the per-server context must be activated
/// and the full notification fetched from the server DB or network.
///
/// Full notification details are stored in the per-server DB and reconciled
/// when the server context activates.
@freezed
abstract class NotificationSummary with _$NotificationSummary {
  const NotificationSummary._();

  const factory NotificationSummary({
    /// Client-generated CUID. Local PK in the root DB.
    required String id,

    /// Local CUID of the server that generated this notification.
    /// FK to [ServerConfig.id] in the root DB servers table.
    required String localServerId,

    /// BGE server UUID of the originating server, denormalized for fast
    /// display (e.g. badge attribution) without a join.
    required String bgeServerId,

    /// Display name of the originating server at time of receipt.
    /// Denormalized so the notification renders even if server is renamed.
    required String serverDisplayName,

    required String title,
    String? body,

    @Default(false) bool isRead,

    /// When true, the per-server context must be activated to show full detail.
    @Default(false) bool requiresFullLoad,

    required DateTime receivedAt,
    required DateTime createdAt,
  }) = _NotificationSummary;

  factory NotificationSummary.fromJson(Map<String, dynamic> json) =>
      _$NotificationSummaryFromJson(json);

  bool get isUnread => !isRead;
}
