import 'dart:collection';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A [NotificationRemoteDataSource] that answers each call from a script.
///
/// One queue per method. A call takes the next entry: the method's result is
/// returned, a `Future` is awaited, anything else is thrown. For [markRead]
/// and [markAllRead], which return nothing, a `null` entry succeeds. A call
/// with an empty queue fails the test with a [StateError], so an unscripted
/// call is loud. Each call's arguments are recorded. [fetchUnread] is not
/// scripted, and throws [UnimplementedError].
class FakeNotificationRemote implements NotificationRemoteDataSource {
  /// The answers [fetchUnreadCount] gives, in order.
  final Queue<Object> unreadCounts = Queue<Object>();

  /// How many times [fetchUnreadCount] was called.
  int fetchUnreadCountCalls = 0;

  /// The answers [fetchPage] gives, in order.
  final Queue<Object> pages = Queue<Object>();

  /// The arguments of each [fetchPage] call, in order.
  final List<({String? cursor, int limit})> fetchPageCalls = [];

  /// The answers [markRead] gives, in order.
  final Queue<Object?> markReadAnswers = Queue<Object?>();

  /// The ids each [markRead] call sent, in order.
  final List<List<String>> markReadCalls = [];

  /// The answers [markAllRead] gives, in order.
  final Queue<Object?> markAllReadAnswers = Queue<Object?>();

  /// How many times [markAllRead] was called.
  int markAllReadCalls = 0;

  /// Scripts [fetchUnreadCount]'s next answers. Each is an `int`, a
  /// `Future<int>`, or an exception to throw.
  void scriptUnreadCounts(Iterable<Object> answers) =>
      unreadCounts.addAll(answers);

  /// Scripts [fetchPage]'s next answers. Each is a [NotificationPage], a
  /// `Future<NotificationPage>`, or an exception to throw.
  void scriptPages(Iterable<Object> answers) => pages.addAll(answers);

  /// Scripts [markRead]'s next answers. Each is `null` to succeed, a
  /// `Future<void>`, or an exception to throw.
  void scriptMarkRead(Iterable<Object?> answers) =>
      markReadAnswers.addAll(answers);

  /// Scripts [markAllRead]'s next answers. Each is `null` to succeed, a
  /// `Future<void>`, or an exception to throw.
  void scriptMarkAllRead(Iterable<Object?> answers) =>
      markAllReadAnswers.addAll(answers);

  @override
  Future<int> fetchUnreadCount() async {
    fetchUnreadCountCalls++;
    final answer = _next(
      unreadCounts,
      'fetchUnreadCount',
      fetchUnreadCountCalls,
    );
    if (answer is Future<int>) {
      return answer;
    }
    if (answer is int) {
      return answer;
    }
    throw answer! as Exception;
  }

  @override
  Future<List<UnreadNotification>> fetchUnread() => throw UnimplementedError();

  @override
  Future<NotificationPage> fetchPage({
    String? cursor,
    int limit = NotificationRemoteDataSource.defaultPageSize,
  }) async {
    fetchPageCalls.add((cursor: cursor, limit: limit));
    final answer = _next(pages, 'fetchPage', fetchPageCalls.length);
    if (answer is Future<NotificationPage>) {
      return answer;
    }
    if (answer is NotificationPage) {
      return answer;
    }
    throw answer! as Exception;
  }

  @override
  Future<void> markAllRead() async {
    markAllReadCalls++;
    await _nothing(
      _next(markAllReadAnswers, 'markAllRead', markAllReadCalls),
    );
  }

  @override
  Future<void> markRead(List<String> ids) async {
    markReadCalls.add(List.of(ids));
    await _nothing(_next(markReadAnswers, 'markRead', markReadCalls.length));
  }

  /// The next answer in [answers], for [method]'s [call]th call.
  static Object? _next(Queue<Object?> answers, String method, int call) {
    if (answers.isEmpty) {
      throw StateError('$method call $call has no scripted answer');
    }
    return answers.removeFirst();
  }

  /// Settles a method that returns nothing with [answer].
  static Future<void> _nothing(Object? answer) async {
    if (answer == null) {
      return;
    }
    if (answer is Future<void>) {
      return answer;
    }
    throw answer as Exception;
  }
}
