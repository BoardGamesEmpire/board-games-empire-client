import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';
import 'package:sync_queue/src/status/session_sync_status.dart';

/// The session's [SessionSyncStatus], from the queue's pending count and its
/// stuck entries (#47). It subscribes on construction and follows both for as
/// long as it lives.
///
/// Each half of the status follows its own stream: [SessionSyncStatus.waiting]
/// is null until the pending count delivers, and
/// [SessionSyncStatus.stuck] until the stuck entries do. Neither waits on the
/// other, so stuck records show as soon as they are read, whatever the
/// pending count is doing.
///
/// A stream that errors is logged, and its half goes back to null until that
/// stream delivers again. Unlike `StuckSyncOpsNotice` nothing is said to be
/// wrong: the indicators this feeds are a hint, and the screen they lead to
/// reports its own read.
class SyncStatusCubit extends Cubit<SessionSyncStatus> {
  SyncStatusCubit({required SyncQueueRepository queue, BgeLogger? logger})
    : _log = logger ?? BgeLogger('bge.sync.status'),
      super(const SessionSyncStatus()) {
    _pending = queue.watchPendingCount().listen(
      (count) => _set(
        SessionSyncStatus(
          waiting: count,
          stuck: state.stuck,
          stuckRecordIds: state.stuckRecordIds,
        ),
      ),
      onError: (Object error, StackTrace stackTrace) {
        _log.warn(
          'Pending count read failed',
          error: error,
          stackTrace: stackTrace,
        );
        _set(
          SessionSyncStatus(
            stuck: state.stuck,
            stuckRecordIds: state.stuckRecordIds,
          ),
        );
      },
    );
    _stuck = queue.watchStuckEntries().listen(
      (entries) => _set(
        SessionSyncStatus(
          waiting: state.waiting,
          stuck: entries.length,
          stuckRecordIds: _recordIdsOf(entries),
        ),
      ),
      onError: (Object error, StackTrace stackTrace) {
        _log.warn(
          'Stuck entries read failed',
          error: error,
          stackTrace: stackTrace,
        );
        _set(SessionSyncStatus(waiting: state.waiting));
      },
    );
  }

  final BgeLogger _log;
  late final StreamSubscription<int> _pending;
  late final StreamSubscription<List<SyncQueueEntry>> _stuck;

  static Set<String> _recordIdsOf(List<SyncQueueEntry> entries) => {
    for (final entry in entries) ?_recordIdOf(entry),
  };

  // An entry this build can't decode still names its record when its payload
  // does; one that doesn't is counted, not named.
  static String? _recordIdOf(SyncQueueEntry entry) {
    try {
      return entry.operation.recordId;
    } on Object {
      // Broad on purpose: a decode fails as a FormatException or a cast's
      // TypeError, and the payload read is the fallback for either.
      return SyncOperation.recordIdOf(entry.payload);
    }
  }

  // bloc 9.2.1 emits a state equal to the initial one on the first emit, so
  // the equality check is made here.
  void _set(SessionSyncStatus next) {
    if (isClosed || next == state) return;
    emit(next);
  }

  @override
  Future<void> close() async {
    // Both cancelled before either is awaited: awaited one after the other,
    // the second stream could still deliver, and a closing cubit emit, in
    // between.
    await Future.wait([_pending.cancel(), _stuck.cancel()]);
    return super.close();
  }
}
