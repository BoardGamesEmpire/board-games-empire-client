import 'dart:async';

import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

/// A queue whose two watched streams a test drives by hand: push values,
/// errors, and end them. Every other call is unexpected and throws.
class StreamingQueue implements SyncQueueRepository {
  final StreamController<int> pending = StreamController<int>();
  final StreamController<List<SyncQueueEntry>> stuck =
      StreamController<List<SyncQueueEntry>>();

  @override
  Stream<int> watchPendingCount() => pending.stream;

  @override
  Stream<List<SyncQueueEntry>> watchStuckEntries() => stuck.stream;

  Future<void> dispose() async {
    await pending.close();
    await stuck.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
