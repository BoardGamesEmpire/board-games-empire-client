import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:observability/observability.dart';

import 'stuck_sync_op.dart';
import 'stuck_sync_ops_event.dart';
import 'stuck_sync_ops_state.dart';
import 'sync_recovery.dart';

/// Drives the retry-or-discard screen (#190) from [SyncRecovery].
///
/// The list comes from the queue alone: a retried or discarded op leaves it
/// because the queue changed, not because this bloc removed it. So a retry
/// another tab made, or one that parks again, shows the same way.
class StuckSyncOpsBloc extends Bloc<StuckSyncOpsEvent, StuckSyncOpsState> {
  StuckSyncOpsBloc({required this._recovery, BgeLogger? logger})
    : _log = logger ?? BgeLogger('bge.sync.recovery.screen'),
      super(const StuckSyncOpsLoading()) {
    on<StuckSyncOpsUpdated>(_onUpdated);
    on<StuckSyncOpsReadFailed>((_, emit) => emit(const StuckSyncOpsError()));
    on<StuckSyncOpsRetryRequested>(
      (event, emit) => _act(event.entryId, emit, _retry, 'retry'),
    );
    on<StuckSyncOpsDiscardRequested>(
      (event, emit) => _act(event.entryId, emit, _discard, 'discard'),
    );

    _stuck = _recovery.watch().listen(
      (ops) => add(StuckSyncOpsUpdated(ops)),
      onError: (Object error, StackTrace stackTrace) {
        _log.warn(
          'Stuck sync ops read failed',
          error: error,
          stackTrace: stackTrace,
        );
        add(const StuckSyncOpsReadFailed());
      },
      // Closes with the session, while the auth redirect pops the screen:
      // what it shows then is kept.
    );
  }

  final SyncRecovery _recovery;
  final BgeLogger _log;
  late final StreamSubscription<List<StuckSyncOp>> _stuck;

  void _onUpdated(StuckSyncOpsUpdated event, Emitter<StuckSyncOpsState> emit) {
    final current = state;
    emit(
      current is StuckSyncOpsReady
          ? current.copyWith(ops: event.ops)
          : StuckSyncOpsReady(event.ops),
    );
  }

  Future<StuckSyncOpsProblem?> _retry(String entryId) async =>
      await _recovery.retry(entryId) ? null : StuckSyncOpsProblem.refusedAgain;

  Future<StuckSyncOpsProblem?> _discard(String entryId) async {
    await _recovery.discard(entryId);
    return null;
  }

  Future<void> _act(
    String entryId,
    Emitter<StuckSyncOpsState> emit,
    Future<StuckSyncOpsProblem?> Function(String entryId) action,
    String name,
  ) async {
    final started = state;
    if (started is! StuckSyncOpsReady || started.busy.contains(entryId)) {
      return;
    }
    emit(StuckSyncOpsReady(started.ops, busy: {...started.busy, entryId}));

    StuckSyncOpsProblem? problem;
    try {
      problem = await action(entryId);
    } on Object catch (error, stackTrace) {
      _log.error(
        'Could not $name a stuck sync op',
        error: error,
        stackTrace: stackTrace,
      );
      problem = StuckSyncOpsProblem.actionFailed;
    }

    // Read again: the list may have changed while the action ran.
    final ended = state;
    if (ended is! StuckSyncOpsReady) return;
    emit(
      StuckSyncOpsReady(
        ended.ops,
        busy: {...ended.busy}..remove(entryId),
        problem: problem ?? ended.problem,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _stuck.cancel();
    return super.close();
  }
}
