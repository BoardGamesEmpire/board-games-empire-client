import 'package:equatable/equatable.dart';

import 'stuck_sync_op.dart';

sealed class StuckSyncOpsState extends Equatable {
  const StuckSyncOpsState();

  @override
  List<Object?> get props => [];
}

/// Before the first read of the queue.
final class StuckSyncOpsLoading extends StuckSyncOpsState {
  const StuckSyncOpsLoading();
}

/// The queue couldn't be read.
final class StuckSyncOpsError extends StuckSyncOpsState {
  const StuckSyncOpsError();
}

/// What went wrong with the last retry or discard.
enum StuckSyncOpsProblem {
  /// It threw on this device.
  actionFailed,

  /// A retry reached the server, which refused the op again.
  refusedAgain,
}

/// The stuck ops, in queue order.
///
/// [busy] holds the ops with a retry or discard running, which take no
/// second action until it ends. [problem] says what went wrong with the last
/// one, until the next one starts.
final class StuckSyncOpsReady extends StuckSyncOpsState {
  const StuckSyncOpsReady(this.ops, {this.busy = const {}, this.problem});

  final List<StuckSyncOp> ops;
  final Set<String> busy;
  final StuckSyncOpsProblem? problem;

  StuckSyncOpsReady copyWith({List<StuckSyncOp>? ops}) =>
      StuckSyncOpsReady(ops ?? this.ops, busy: busy, problem: problem);

  @override
  List<Object?> get props => [ops, busy, problem];
}
