import 'package:models/domain.dart';

/// Repository for lightweight notification summaries stored in the root DB.
///
/// These records are written without opening a per-server DB, enabling unified
/// badge counts and the merged notification feed across all connection states.
/// Full notification detail is stored in per-server DBs and reconciled on
/// context activation.
abstract class NotificationSummaryRepository {
  /// Persists a new notification summary.
  Future<NotificationSummary> add(NotificationSummary summary);

  /// Marks a single notification as read.
  Future<void> markRead(String notificationId);

  /// Marks all notifications for a given server as read.
  Future<void> markAllReadForServer(String localServerId);

  /// Permanently removes a notification summary.
  Future<void> delete(String notificationId);

  /// Removes all notification summaries for a server. Called when a server
  /// is removed from the device.
  Future<void> deleteAllForServer(String localServerId);

  /// Returns all unread notification summaries ordered by [receivedAt] desc.
  Future<List<NotificationSummary>> getUnread();

  /// Returns all summaries for a specific server ordered by [receivedAt] desc.
  Future<List<NotificationSummary>> getForServer(String localServerId);

  /// Total unread count across all servers. Powers the app badge.
  Future<int> getUnreadCount();

  /// Unread count for a specific server. Powers per-server badges.
  Future<int> getUnreadCountForServer(String localServerId);

  /// Stream of all notifications ordered by [receivedAt] desc.
  /// Emits on any change (add, mark-read, delete).
  Stream<List<NotificationSummary>> watchAll();

  /// Stream of unread count across all servers.
  Stream<int> watchUnreadCount();

  /// Stream of unread count for a specific server.
  Stream<int> watchUnreadCountForServer(String localServerId);
}
