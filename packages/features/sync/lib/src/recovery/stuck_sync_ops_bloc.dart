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
///
/// The one exception is an op whose retry or discard is still running. A
/// retry takes the op out of the stuck list before it sends it, so the op
/// stays listed, where it was, until the action ends. Its button keeps its
/// place and its focus.
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

  /// The stuck list as the queue last reported it.
  List<StuckSyncOp> _queued = const [];

  void _onUpdated(StuckSyncOpsUpdated event, Emitter<StuckSyncOpsState> emit) {
    _queued = event.ops;
    final current = state;
    emit(
      current is StuckSyncOpsReady
          ? current.copyWith(ops: _keepBusy(current.ops, current.busy))
          : StuckSyncOpsReady(event.ops),
    );
  }

  /// [_queued], with each op in [busy] that has left it put back where
  /// [shown] listed it.
  List<StuckSyncOp> _keepBusy(List<StuckSyncOp> shown, Set<String> busy) {
    if (busy.isEmpty) return _queued;
    final ops = [..._queued];
    var at = 0;
    for (final op in shown) {
      final queuedAt = ops.indexWhere((queued) => queued.entryId == op.entryId);
      if (queuedAt >= 0) {
        at = queuedAt + 1;
      } else if (busy.contains(op.entryId)) {
        ops.insert(at++, op);
      }
    }
    return ops;
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
    final busy = {...ended.busy}..remove(entryId);
    emit(
      StuckSyncOpsReady(
        _keepBusy(ended.ops, busy),
        busy: busy,
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
