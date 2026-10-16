import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../access/data_gateway_access.dart';
import 'data_gateway_list_event.dart';
import 'data_gateway_list_state.dart';

/// Drives the DataGateway list (#41): the server's rows, and the row actions
/// that change them.
///
/// Nothing is cached (#41). The list is read whenever the screen opens and
/// whenever the user comes back from the add or edit form.
///
/// ## Reads and actions overlap
///
/// Coming back from editing one row reloads the list while an action on
/// another may still be running, so the rows, the busy set and the last
/// outcome live in fields here rather than only in the emitted state. A
/// reload over rows already shown keeps showing them instead of going back
/// to the spinner, so an action that finishes mid-reload still has a row to
/// settle and a banner to report in. Of two overlapping reads, the one asked
/// for last wins, whichever answers first.
///
/// An action that ends while a read is in flight asks for the list again.
/// The server may have answered that read before the action's write, and its
/// rows would then put the action's row back the way it was.
///
/// A reload that fails takes the rows down with it. An action that ends
/// meanwhile keeps its outcome, which shows once a read brings the rows back.
///
/// ## Access
///
/// A refused read is [DataGatewayListDenied]. A refused change hides every
/// change action for the rest of the session, here and on every other screen,
/// through [DataGatewayAccess]: Moderators may read DataGateways and not
/// change them, and nothing tells the client which role it has until a change
/// is refused (#41). Both are reported to [access], so the home drawer agrees
/// with what this screen found.
///
/// A null [access] is a composition with no session to report to. The screen
/// still works; what it learns lasts as long as the bloc.
class DataGatewayListBloc
    extends Bloc<DataGatewayListEvent, DataGatewayListState> {
  DataGatewayListBloc({
    required this._remote,
    DataGatewayAccess? access,
    BgeLogger? logger,
  }) : _access = access,
       _logger = logger ?? BgeLogger('bge.data_gateway.list'),
       _mayChange = access?.value.mayChange ?? true,
       super(const DataGatewayListLoading()) {
    on<DataGatewayListLoadRequested>(_onLoadRequested);
    on<DataGatewayListActionRequested>(_onActionRequested);
    on<DataGatewayListOutcomeDismissed>(_onOutcomeDismissed);
    on<DataGatewayListAccessChanged>(_onAccessChanged);
    access?.addListener(_accessListener);
  }

  final DataGatewayRemoteDataSource _remote;
  final DataGatewayAccess? _access;
  final BgeLogger _logger;

  bool _mayChange;

  /// The rows on screen. Null until a read succeeds, and again after one
  /// fails or is refused.
  List<DataGateway>? _rows;

  /// Ids of the rows with an action in flight.
  final Set<String> _busy = {};

  /// What the last action answered, until dismissed or replaced.
  DataGatewayListOutcome? _outcome;

  /// Which read is the latest. An older one that answers late is dropped.
  int _readSequence = 0;

  /// The latest read that has answered. Behind [_readSequence] while that
  /// read is in flight.
  int _readAnswered = 0;

  bool get _reading => _readAnswered != _readSequence;

  /// A bound on how many pages one load follows. DataGateways are
  /// installation configuration, so a real list is one page; this only stops
  /// a server that always says `hasMore` from looping forever. Reaching it is
  /// a failed read, not part of the list shown as the whole of it.
  static const int _maxPages = 50;

  void _accessListener() => add(const DataGatewayListAccessChanged());

  Future<void> _onLoadRequested(
    DataGatewayListLoadRequested event,
    Emitter<DataGatewayListState> emit,
  ) async {
    final read = ++_readSequence;
    if (_rows == null) emit(const DataGatewayListLoading());
    try {
      final rows = <DataGateway>[];
      var whole = false;
      for (var page = 1; page <= _maxPages && !whole; page++) {
        final result = await _remote.fetchPage(page: page);
        if (read != _readSequence) return;
        rows.addAll(result.items);
        whole = !result.meta.hasMore;
      }
      _access?.readGranted();
      if (!whole) {
        throw StateError('the list still had more after $_maxPages pages');
      }
      _rows = rows;
      _emitReady(emit);
    } on DataGatewayForbiddenException {
      if (read != _readSequence) return;
      _rows = null;
      _access?.readDenied();
      emit(const DataGatewayListDenied());
    } on Object catch (error, stackTrace) {
      if (read != _readSequence) return;
      _logger.warn(
        'DataGateway list read failed',
        error: error,
        stackTrace: stackTrace,
      );
      _rows = null;
      emit(const DataGatewayListFailed());
    } finally {
      if (read == _readSequence) _readAnswered = read;
    }
  }

  Future<void> _onActionRequested(
    DataGatewayListActionRequested event,
    Emitter<DataGatewayListState> emit,
  ) async {
    final row = _rows?.where((g) => g.id == event.id).firstOrNull;
    if (row == null || !_mayChange || _busy.contains(event.id)) return;

    _busy.add(event.id);
    _outcome = null;
    _emitReady(emit);

    final (replacement, result) = await _attempt(event.action, row);

    // Settled against the rows as they are now, not as they were when the
    // action started: a reload or another row's action may have landed.
    _busy.remove(event.id);
    _rows = _rows == null
        ? null
        : [
            for (final g in _rows!)
              if (g.id != event.id) g else ?replacement,
          ];
    _outcome = DataGatewayListOutcome(
      action: event.action,
      result: result,
      name: row.name,
    );
    _emitReady(emit);

    // The read in flight is dropped when it lands; this one is answered
    // after the action's write.
    if (_reading && !isClosed) add(const DataGatewayListLoadRequested());
  }

  /// Runs [action] on [row]. Answers with what should replace the row (null
  /// removes it) and how the action ended. Never throws.
  Future<(DataGateway?, DataGatewayActionResult)> _attempt(
    DataGatewayRowAction action,
    DataGateway row,
  ) async {
    try {
      final answer = await switch (action) {
        DataGatewayRowAction.connect => _remote.connect(row.id),
        DataGatewayRowAction.disconnect => _remote.disconnect(row.id),
        DataGatewayRowAction.delete => _remote.delete(row.id),
      };
      return switch (action) {
        // A delete is done once the row is gone. Its disconnect attempt is
        // the server tidying up, and the registry drops the DataGateway on
        // the delete's own config event either way.
        DataGatewayRowAction.delete => (null, DataGatewayActionResult.done),
        DataGatewayRowAction.connect || DataGatewayRowAction.disconnect => (
          answer.dataGateway,
          answer.connectionAttempt?.succeeded == false
              ? DataGatewayActionResult.attemptFailed
              : DataGatewayActionResult.done,
        ),
      };
    } on DataGatewayForbiddenException {
      _mayChange = false;
      _access?.changeDenied();
      return (row, DataGatewayActionResult.refused);
    } on DataGatewayNotFoundException {
      return (null, DataGatewayActionResult.gone);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'DataGateway ${action.name} failed',
        error: error,
        stackTrace: stackTrace,
      );
      return (row, DataGatewayActionResult.failed);
    }
  }

  void _onOutcomeDismissed(
    DataGatewayListOutcomeDismissed event,
    Emitter<DataGatewayListState> emit,
  ) {
    if (_outcome == null) return;
    _outcome = null;
    _emitReady(emit);
  }

  void _onAccessChanged(
    DataGatewayListAccessChanged event,
    Emitter<DataGatewayListState> emit,
  ) {
    final access = _access;
    if (access == null || access.value.mayChange || !_mayChange) return;
    _mayChange = false;
    _emitReady(emit);
  }

  /// Shows the rows, when there are rows to show.
  void _emitReady(Emitter<DataGatewayListState> emit) {
    final rows = _rows;
    if (rows == null) return;
    emit(
      DataGatewayListReady(
        gateways: rows,
        mayChange: _mayChange,
        busy: {..._busy},
        outcome: _outcome,
      ),
    );
  }

  @override
  Future<void> close() {
    _access?.removeListener(_accessListener);
    return super.close();
  }
}
