import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../access/data_gateway_names.dart';
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
/// So does an action that ends after a read landed while it ran, when it
/// settles its row over that read's rows. A connect or disconnect answers
/// with the row the server saved before its attempt, and a read during the
/// attempt may already hold a change someone made since.
///
/// A reload that fails takes the rows down with it. An action that ends
/// meanwhile keeps its outcome, which shows once a read brings the rows back.
///
/// ## Access
///
/// Each action is offered while the caller's access, as the server answers
/// it, says they may take it (#456): add needs create, connect and disconnect
/// need update, and delete needs delete. The switches follow [access] as its
/// answer changes, up or down, without reading the list again. An action
/// they no longer allow is dropped, as from a menu opened before they fell.
///
/// A refused read is [DataGatewayListDenied], and a refused change is
/// reported in the banner. Neither turns a switch off: each asks [access]
/// again, and the switches follow what it answers. The refusal is the
/// server's word that the answer here may be out of date, as when the
/// caller's role changed since it was asked. A refused read asks even when a
/// newer read has superseded it: what it says is about the caller, not the
/// rows.
///
/// [DataGatewayListDenied] reads the list again once a changed answer allows
/// read. A refusal can come before the server has written a new user's
/// roles, as for a fresh server's first owner (backend#490), and the answer
/// that follows them is the one that says the read would now go through.
///
/// A read that succeeds while the answer is still unknown asks [access]
/// again too. The first ask can fail with the server up, as on a 502 from a
/// proxy, and nothing else asks again until a rehydrate trigger. The server
/// has just answered this caller, so an ask now is likely to be answered
/// too.
///
/// A null [access] is a composition with no session to ask. The rows still
/// show, and nothing is offered, as while the answer is unknown.
class DataGatewayListBloc
    extends Bloc<DataGatewayListEvent, DataGatewayListState> {
  DataGatewayListBloc({
    required this._remote,
    CallerAccessRepository? access,
    BgeLogger? logger,
  }) : _access = access,
       _logger = logger ?? BgeLogger('bge.data_gateway.list'),
       super(const DataGatewayListLoading()) {
    on<DataGatewayListLoadRequested>(_onLoadRequested);
    on<DataGatewayListActionRequested>(_onActionRequested);
    on<DataGatewayListOutcomeDismissed>(_onOutcomeDismissed);
    on<DataGatewayListAccessChanged>(_onAccessChanged);
    _accessChanges = access?.changes.listen((_) {
      if (!isClosed) add(const DataGatewayListAccessChanged());
    });
  }

  final DataGatewayRemoteDataSource _remote;
  final CallerAccessRepository? _access;
  final BgeLogger _logger;
  StreamSubscription<CallerAccess>? _accessChanges;

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

  /// A bound on how many pages one load follows: see
  /// [dataGatewayListMaxPages]. Reaching it is a failed read, not part of the
  /// list shown as the whole of it.
  static const int _maxPages = dataGatewayListMaxPages;

  /// Whether the caller's access lets them take [action] on DataGateways.
  /// False while the answer is unknown, and with no [_access] to ask.
  bool _may(AccessAction action) =>
      _access?.current.allows(ResourceType.dataGateway, action) ?? false;

  /// The access a row [action] needs.
  static AccessAction _needs(DataGatewayRowAction action) => switch (action) {
    DataGatewayRowAction.connect ||
    DataGatewayRowAction.disconnect => AccessAction.update,
    DataGatewayRowAction.delete => AccessAction.delete,
  };

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
      if (!whole) {
        throw StateError('the list still had more after $_maxPages pages');
      }
      _rows = rows;
      _emitReady(emit);
      // The server answered this caller: see Access in the class doc.
      if (_access?.current.isKnown == false) unawaited(_access?.refresh());
    } on DataGatewayForbiddenException {
      unawaited(_access?.refresh());
      if (read != _readSequence) return;
      _rows = null;
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
    if (row == null ||
        !_may(_needs(event.action)) ||
        _busy.contains(event.id)) {
      return;
    }

    _busy.add(event.id);
    _outcome = null;
    _emitReady(emit);
    final answeredBefore = _readAnswered;

    final (after, result) = await _attempt(event.action, row);

    // Settled against the rows as they are now, not as they were when the
    // action started: a reload or another row's action may have landed. A
    // failed or refused action says nothing about the row, so whatever is
    // there now stays.
    _busy.remove(event.id);
    final rows = _rows;
    final settled = rows != null && _answered(result);
    if (settled) {
      _rows = [
        for (final g in rows)
          if (g.id != event.id) g else ?after,
      ];
    }
    _outcome = DataGatewayListOutcome(
      action: event.action,
      result: result,
      name: row.name,
    );
    _emitReady(emit);

    // The read in flight is dropped when it lands, and the row just settled
    // may be older than a read that landed meanwhile; this one is answered
    // after both.
    final landed = _readAnswered != answeredBefore;
    if ((_reading || (settled && landed)) && !isClosed) {
      add(const DataGatewayListLoadRequested());
    }
  }

  /// Whether [result] came with the server's word on the row.
  static bool _answered(DataGatewayActionResult result) => switch (result) {
    DataGatewayActionResult.done ||
    DataGatewayActionResult.attemptFailed ||
    DataGatewayActionResult.gone => true,
    DataGatewayActionResult.refused || DataGatewayActionResult.failed => false,
  };

  /// Runs [action] on [row]. Answers with the row as the server left it and
  /// how the action ended. The row is null when it is gone, and when the
  /// action failed or was refused, which says nothing about it. Never throws.
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
      unawaited(_access?.refresh());
      return (null, DataGatewayActionResult.refused);
    } on DataGatewayNotFoundException {
      return (null, DataGatewayActionResult.gone);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'DataGateway ${action.name} failed',
        error: error,
        stackTrace: stackTrace,
      );
      return (null, DataGatewayActionResult.failed);
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
    // A refused read tries again: see Access in the class doc.
    if (state is DataGatewayListDenied && _may(AccessAction.read)) {
      if (!isClosed) add(const DataGatewayListLoadRequested());
      return;
    }
    _emitReady(emit);
  }

  /// Shows the rows, when there are rows to show, with the actions the
  /// caller's access allows now.
  void _emitReady(Emitter<DataGatewayListState> emit) {
    final rows = _rows;
    if (rows == null) return;
    emit(
      DataGatewayListReady(
        gateways: rows,
        mayCreate: _may(AccessAction.create),
        mayUpdate: _may(AccessAction.update),
        mayDelete: _may(AccessAction.delete),
        busy: {..._busy},
        outcome: _outcome,
      ),
    );
  }

  @override
  Future<void> close() {
    // Not awaited first, so that the bloc reads as closed from the turn this
    // starts in: an action that lands then asks for no read.
    unawaited(_accessChanges?.cancel());
    return super.close();
  }
}
