import 'dart:collection';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A [NotificationRemoteDataSource] that answers each call from a script.
///
/// One queue per method. A call takes the next entry: an `int` (or the
/// method's result type) is returned, a `Future` is awaited, anything else is
/// thrown. A call with an empty queue fails the test with a [StateError], so
/// an unscripted call is loud. Methods nobody scripted yet throw
/// [UnimplementedError].
class FakeNotificationRemote implements NotificationRemoteDataSource {
  /// The answers [fetchUnreadCount] gives, in order.
  final Queue<Object> unreadCounts = Queue<Object>();

  /// How many times [fetchUnreadCount] was called.
  int fetchUnreadCountCalls = 0;

  /// Scripts [fetchUnreadCount]'s next answers. Each is an `int`, a
  /// `Future<int>`, or an exception to throw.
  void scriptUnreadCounts(Iterable<Object> answers) =>
      unreadCounts.addAll(answers);

  @override
  Future<int> fetchUnreadCount() async {
    fetchUnreadCountCalls++;
    if (unreadCounts.isEmpty) {
      throw StateError(
        'fetchUnreadCount call $fetchUnreadCountCalls has no '
        'scripted answer',
      );
    }
    final answer = unreadCounts.removeFirst();
    if (answer is Future<int>) {
      return answer;
    }
    if (answer is int) {
      return answer;
    }
    throw answer as Exception;
  }

  @override
  Future<List<UnreadNotification>> fetchUnread() => throw UnimplementedError();

  @override
  Future<NotificationPage> fetchPage({
    String? cursor,
    int limit = NotificationRemoteDataSource.defaultPageSize,
  }) => throw UnimplementedError();

  @override
  Future<void> markAllRead() => throw UnimplementedError();

  @override
  Future<void> markRead(List<String> ids) => throw UnimplementedError();
}
