import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A [NotificationRemoteDataSource] that answers each unread read from a
/// script.
///
/// Each [fetchUnread] takes the next entry of [reads]: a list is returned,
/// anything else is thrown. The last entry repeats once the script runs out.
class FakeNotificationRemote implements NotificationRemoteDataSource {
  FakeNotificationRemote(this.reads);

  final List<Object> reads;

  /// How many times [fetchUnread] was called.
  int fetchCalls = 0;

  /// The ids passed to each [markRead].
  final List<List<String>> markReadCalls = [];

  /// What [markRead] throws, when set.
  Exception? markReadError;

  /// What each [markRead] waits on before it answers, when set.
  Future<void>? markReadGate;

  /// How long each [fetchUnread] takes in real time, when set: the bloc
  /// times its reads with a [Stopwatch], which fake time doesn't move.
  Duration? readDelay;

  @override
  Future<List<UnreadNotification>> fetchUnread() async {
    final index = fetchCalls < reads.length ? fetchCalls : reads.length - 1;
    fetchCalls++;
    final delay = readDelay;
    if (delay != null) {
      await Future<void>.delayed(delay);
    }
    final read = reads[index];
    if (read is List<UnreadNotification>) {
      return read;
    }
    throw read as Exception;
  }

  @override
  Future<void> markRead(List<String> ids) async {
    markReadCalls.add(ids);
    final gate = markReadGate;
    if (gate != null) {
      await gate;
    }
    final error = markReadError;
    if (error != null) {
      throw error;
    }
  }
}

/// A test result notification with [id].
UnreadNotification resultNotification(String id, {bool sent = true}) =>
    UnreadNotification(
      id: id,
      type: MailTestResult.notificationType,
      payload: {
        'outcome': sent ? 'sent' : 'failed',
        if (!sent) 'code': 'MAIL_AUTH_FAILED',
        'message': 'm',
      },
      createdAt: DateTime.utc(2026, 11, 12),
    );

/// A notification of another type.
UnreadNotification otherNotification(String id) => UnreadNotification(
  id: id,
  type: 'Other',
  payload: const {},
  createdAt: DateTime.utc(2026, 11, 12),
);
