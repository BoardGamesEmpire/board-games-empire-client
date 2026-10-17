import 'package:equatable/equatable.dart';

import 'stuck_sync_op.dart';

sealed class StuckSyncOpsEvent extends Equatable {
  const StuckSyncOpsEvent();

  @override
  List<Object?> get props => [];
}

/// The queue's stuck ops changed.
final class StuckSyncOpsUpdated extends StuckSyncOpsEvent {
  const StuckSyncOpsUpdated(this.ops);

  final List<StuckSyncOp> ops;

  @override
  List<Object?> get props => [ops];
}

/// The queue couldn't be read.
final class StuckSyncOpsReadFailed extends StuckSyncOpsEvent {
  const StuckSyncOpsReadFailed();
}

/// The user asked to send [entryId] again.
final class StuckSyncOpsRetryRequested extends StuckSyncOpsEvent {
  const StuckSyncOpsRetryRequested(this.entryId);

  final String entryId;

  @override
  List<Object?> get props => [entryId];
}

/// The user confirmed discarding [entryId].
final class StuckSyncOpsDiscardRequested extends StuckSyncOpsEvent {
  const StuckSyncOpsDiscardRequested(this.entryId);

  final String entryId;

  @override
  List<Object?> get props => [entryId];
}
