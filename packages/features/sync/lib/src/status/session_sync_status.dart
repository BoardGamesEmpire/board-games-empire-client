import 'package:equatable/equatable.dart';

/// What the sync queue holds for the current session (#47): how many changes
/// are waiting to go out, how many are stuck, and which records the stuck
/// ones name.
///
/// Each half is read from its own stream, and is known or not on its own: a
/// failed or not-yet-arrived pending count leaves the stuck records as read,
/// and the other way round. A null count is one nobody has read, so it
/// claims nothing, neither that everything has synced nor that nothing is
/// stuck. It is never a sign that something is wrong: a failed read is
/// logged, and the stuck-changes screen reports its own.
final class SessionSyncStatus extends Equatable {
  // No assert that [stuckRecordIds] is empty while [stuck] is null: a const
  // constructor's assert can't read a set's contents. `BgeSyncStatusScope`,
  // which the host builds from this, asserts it.
  const SessionSyncStatus({
    this.waiting,
    this.stuck,
    this.stuckRecordIds = const {},
  });

  /// Changes queued and not yet delivered; null until the pending count is
  /// read, and while its last read failed.
  final int? waiting;

  /// Changes the queue gave up on until the user retries or discards them;
  /// null until the stuck entries are read, and while their last read
  /// failed.
  final int? stuck;

  /// The ids of the records the stuck changes concern, so a list row can
  /// show its own change as stuck. Smaller than [stuck] when an entry names
  /// no record this build can read, and empty while [stuck] is null.
  final Set<String> stuckRecordIds;

  @override
  List<Object?> get props => [waiting, stuck, stuckRecordIds];
}
