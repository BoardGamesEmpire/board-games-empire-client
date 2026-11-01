import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../access/data_gateway_access.dart';
import 'data_gateway_detail_event.dart';
import 'data_gateway_detail_state.dart';

/// Drives the DataGateway detail screen (#457): the row, interviewing it again,
/// and switching its capabilities off and on.
///
/// Nothing is cached (#41). The row is read whenever the screen opens and
/// whenever the user comes back to it.
///
/// ## One action at a time
///
/// The screen keeps a control enabled through its own action, because a disabled
/// control gives up keyboard focus (#607), so what is pressed during an action
/// is settled here:
///
/// - The interview button during its own interview is a double press, and is
///   dropped. So is a switch, which the screen stops taking presses by then.
/// - A switch during a write waits for that write, as the last press of that
///   switch. It goes out built from the row that write answers with, and if the
///   row already says so, nothing is sent. So a double press writes once, and a
///   second switch pressed quickly isn't lost.
/// - The interview button during a write waits too, and the state says so with
///   [DataGatewayDetailReady.interviewWaiting]. It goes after any switches.
/// - A write that ends with no row to build from, or that is refused, drops what
///   was waiting. Its banner says the write didn't go as asked, and a change
///   sent on behind that could switch back what it may have applied.
///
/// ## Capability writes
///
/// The server takes the whole list on every write, so each one is built from
/// the row as the server last answered it, at the moment the switch is handled.
/// A list built from anything older would silently switch the last change back
/// (#457). Names this client can't label stay in it, and a switch that wouldn't
/// change the list sends nothing.
///
/// ## Reads and actions overlap
///
/// The user can come back to the screen, or refresh it, while an action runs,
/// and a re-interview can run for a minute. The server may have answered a read
/// before it made the action's change, and that read's row would put the change
/// back. So:
///
/// - A read that answers during an action is dropped, whatever it answered. A
///   failure, a refusal or a 404 takes nothing down either: the action still
///   has this row to report on. One more read goes out when the action ends.
/// - A read still in flight when the action ends is dropped the same way, and
///   one more goes out. It is marked dropped in the turn the action ends, so it
///   can't land between that and the next read starting.
/// - Of two overlapping reads, the one asked for last wins, whichever answers
///   first.
///
/// A read over a row on screen keeps showing it instead of going back to the
/// spinner. One that fails with no action running takes the row down, and the
/// last outcome shows again once a read brings the row back.
///
/// ## An action that ends with no word on the row
///
/// A re-interview that doesn't answer with the row, other than a refusal or a
/// 404, and a capability write with no usable answer, always read the row again,
/// and nothing more is sent until a read has answered.
///
/// A write whose answer was lost may have applied, so one built from the row on
/// screen could switch that change back. An interview with no answer may still
/// be running, or may have finished with a row the screen hasn't seen. That goes
/// for a proxy's 504 or a dropped connection as much as a timeout, since the
/// server sets no deadline of its own (backend#722), so it isn't sent twice
/// before the row has been read. If that read fails the row comes down with it,
/// so nothing can be built from the old one.
///
/// A 404 from an action is the server's last word: [DataGatewayDetailGone], and
/// no read follows.
///
/// ## Leaving during an action
///
/// A handler waiting on the server outlives [close], and asking for a read then
/// would throw, so it asks for none once [close] has started. A refusal that
/// lands after that still reaches [access], which outlasts the screen.
///
/// ## Access
///
/// A refused read is [DataGatewayDetailDenied]. A refused change hides every
/// change action for the rest of the session, here and on every other screen,
/// through [DataGatewayAccess]: Moderators may read DataGateways and not change
/// them, and nothing tells the client which role it has until a change is
/// refused (#41). Both are reported to [access], so the home drawer agrees with
/// what this screen found.
///
/// A null [access] is a composition with no session to report to. The screen
/// still works; what it learns lasts as long as the bloc.
class DataGatewayDetailBloc
    extends Bloc<DataGatewayDetailEvent, DataGatewayDetailState> {
  DataGatewayDetailBloc({
    required this._remote,
    required this._id,
    DataGatewayAccess? access,
    BgeLogger? logger,
  }) : _access = access,
       _logger = logger ?? BgeLogger('bge.data_gateway.detail'),
       _mayChange = access?.value.mayChange ?? true,
       super(const DataGatewayDetailLoading()) {
    on<DataGatewayDetailLoadRequested>(_onLoadRequested);
    on<DataGatewayDetailInterviewRequested>(_onInterviewRequested);
    on<DataGatewayDetailCapabilitySwitched>(_onCapabilitySwitched);
    on<DataGatewayDetailOutcomeDismissed>(_onOutcomeDismissed);
    on<DataGatewayDetailAccessChanged>(_onAccessChanged);
    access?.addListener(_accessListener);
  }

  final DataGatewayRemoteDataSource _remote;
  final String _id;
  final DataGatewayAccess? _access;
  final BgeLogger _logger;

  bool _mayChange;

  /// The row on screen, as the server last answered it. Null until a read
  /// succeeds, and again after one fails, is refused or finds it gone.
  ///
  /// The only thing a capability write is built from.
  DataGateway? _row;

  /// The action in flight.
  DataGatewayDetailBusy? _busy;

  /// What the last action answered, until dismissed or replaced.
  DataGatewayDetailOutcome? _outcome;

  /// Which read is the latest. An older one that answers late is dropped.
  int _readSequence = 0;

  /// The latest read that has answered. Behind [_readSequence] while that
  /// read is in flight.
  int _readAnswered = 0;

  bool get _reading => _readAnswered != _readSequence;

  /// A read answered during the action in flight and was dropped, so one more
  /// goes out when it ends.
  bool _readAgain = false;

  /// The last action ended with no word on the row, and no read has brought
  /// the row since. Nothing more is sent until one has.
  bool _rowInDoubt = false;

  /// Nothing has come up that stops an action being sent, other than one
  /// already running.
  bool get _mayAsk => _mayChange && !_rowInDoubt;

  /// Each switch pressed during a write, as last pressed.
  final Map<String, bool> _waitingSwitches = {};

  /// The interview button was pressed during a write.
  bool _interviewWaiting = false;

  void _accessListener() => add(const DataGatewayDetailAccessChanged());

  Future<void> _onLoadRequested(
    DataGatewayDetailLoadRequested event,
    Emitter<DataGatewayDetailState> emit,
  ) async {
    final read = ++_readSequence;
    if (_row == null) emit(const DataGatewayDetailLoading());
    try {
      final row = await _remote.fetchOne(_id);
      if (_drops(read)) return;
      _access?.readGranted();
      _row = row;
      _rowInDoubt = false;
      _emitReady(emit);
    } on DataGatewayForbiddenException {
      if (_drops(read)) return;
      _row = null;
      _access?.readDenied();
      emit(const DataGatewayDetailDenied());
    } on DataGatewayNotFoundException {
      if (_drops(read)) return;
      _row = null;
      emit(const DataGatewayDetailGone());
    } on Object catch (error, stackTrace) {
      if (_drops(read)) return;
      _logger.warn(
        'DataGateway read failed',
        error: error,
        stackTrace: stackTrace,
      );
      _row = null;
      emit(const DataGatewayDetailFailed());
    } finally {
      if (read == _readSequence) _readAnswered = read;
    }
  }

  /// Whether what [read] answered is to be ignored: a newer read has been
  /// asked for, or it answered during an action, which then reads again.
  bool _drops(int read) {
    if (read != _readSequence) return true;
    if (_busy == null) return false;
    _readAgain = true;
    return true;
  }

  Future<void> _onInterviewRequested(
    DataGatewayDetailInterviewRequested event,
    Emitter<DataGatewayDetailState> emit,
  ) async {
    final row = _row;
    if (row == null || !row.enabled || !_mayAsk) {
      // What it was waiting for has gone since it was asked for.
      if (_interviewWaiting) {
        _interviewWaiting = false;
        _emitReady(emit);
      }
      return;
    }
    switch (_busy) {
      case DataGatewayDetailBusy.interview:
        return;
      case DataGatewayDetailBusy.capabilities:
        _interviewWaiting = true;
        _emitReady(emit);
      case null:
        _interviewWaiting = false;
        await _act(DataGatewayDetailBusy.interview, _interview, emit);
    }
  }

  Future<void> _onCapabilitySwitched(
    DataGatewayDetailCapabilitySwitched event,
    Emitter<DataGatewayDetailState> emit,
  ) async {
    final row = _row;
    if (row == null || !_mayAsk) return;
    switch (_busy) {
      case DataGatewayDetailBusy.interview:
        return;
      case DataGatewayDetailBusy.capabilities:
        _waitingSwitches[event.capability] = event.on;
        return;
      case null:
        break;
    }

    final disabled = row.disabledCapabilities;
    final isOn = !disabled.contains(event.capability);
    if (event.on == isOn) return;

    final next = event.on
        ? [
            for (final name in disabled)
              if (name != event.capability) name,
          ]
        : [...disabled, event.capability];
    await _act(DataGatewayDetailBusy.capabilities, () => _write(next), emit);
  }

  /// Runs one action: shows it busy, waits for [attempt], and settles what it
  /// answered.
  Future<void> _act(
    DataGatewayDetailBusy busy,
    Future<_ActionEnd> Function() attempt,
    Emitter<DataGatewayDetailState> emit,
  ) async {
    _busy = busy;
    _outcome = null;
    _emitReady(emit);

    final end = await attempt();

    // All in one turn. A read in flight is marked dropped before anything
    // yields, so it can't land between busy clearing and the next read
    // starting.
    _busy = null;
    final overtaken = _reading;
    if (overtaken) _readSequence++;
    final readAgain = overtaken || _readAgain || end.rowInDoubt;
    _readAgain = false;

    if (end.gone) {
      _row = null;
      _waitingSwitches.clear();
      _interviewWaiting = false;
      emit(const DataGatewayDetailGone());
      return;
    }

    _row = end.row ?? _row;
    _outcome = end.outcome;
    _rowInDoubt = end.rowInDoubt;
    // Only a write that answered with its row sends on what waited for it.
    final switches = {if (end.row != null) ..._waitingSwitches};
    _waitingSwitches.clear();
    _interviewWaiting = _interviewWaiting && end.row != null;
    final interview = _interviewWaiting;
    _emitReady(emit);

    if (isClosed) return;
    if (readAgain) add(const DataGatewayDetailLoadRequested());
    for (final MapEntry(key: name, value: on) in switches.entries) {
      add(DataGatewayDetailCapabilitySwitched(name, on: on));
    }
    if (interview) add(const DataGatewayDetailInterviewRequested());
  }

  /// Interviews the DataGateway. Never throws.
  Future<_ActionEnd> _interview() async {
    try {
      final answer = await _remote.interview(_id);
      return _ActionEnd(
        row: answer.dataGateway,
        outcome: answer.succeeded
            ? DataGatewayDetailOutcome.interviewDone
            : DataGatewayDetailOutcome.interviewFailed,
      );
    } on DataGatewayTimedOutException {
      return const _ActionEnd(
        outcome: DataGatewayDetailOutcome.interviewUnknown,
        rowInDoubt: true,
      );
    } on DataGatewayConflictException {
      return const _ActionEnd(
        outcome: DataGatewayDetailOutcome.interviewDisabled,
        rowInDoubt: true,
      );
    } on DataGatewayNotFoundException {
      return const _ActionEnd(gone: true);
    } on DataGatewayForbiddenException {
      return _refused();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'DataGateway interview failed',
        error: error,
        stackTrace: stackTrace,
      );
      return const _ActionEnd(
        outcome: DataGatewayDetailOutcome.interviewNoAnswer,
        rowInDoubt: true,
      );
    }
  }

  /// Sends [disabled] as the whole list. Never throws.
  Future<_ActionEnd> _write(List<String> disabled) async {
    try {
      final answer = await _remote.setDisabledCapabilities(_id, disabled);
      return _ActionEnd(row: answer.dataGateway);
    } on DataGatewayNotFoundException {
      return const _ActionEnd(gone: true);
    } on DataGatewayForbiddenException {
      return _refused();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'DataGateway capability write failed',
        error: error,
        stackTrace: stackTrace,
      );
      return const _ActionEnd(
        outcome: DataGatewayDetailOutcome.capabilityFailed,
        rowInDoubt: true,
      );
    }
  }

  _ActionEnd _refused() {
    _mayChange = false;
    _access?.changeDenied();
    return const _ActionEnd(outcome: DataGatewayDetailOutcome.refused);
  }

  void _onOutcomeDismissed(
    DataGatewayDetailOutcomeDismissed event,
    Emitter<DataGatewayDetailState> emit,
  ) {
    if (_outcome == null) return;
    _outcome = null;
    _emitReady(emit);
  }

  void _onAccessChanged(
    DataGatewayDetailAccessChanged event,
    Emitter<DataGatewayDetailState> emit,
  ) {
    final access = _access;
    if (access == null || access.value.mayChange || !_mayChange) return;
    _mayChange = false;
    _emitReady(emit);
  }

  /// Shows the row, when there is a row to show.
  void _emitReady(Emitter<DataGatewayDetailState> emit) {
    final row = _row;
    if (row == null) return;
    emit(
      DataGatewayDetailReady(
        gateway: row,
        mayChange: _mayChange,
        busy: _busy,
        interviewWaiting: _interviewWaiting,
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

/// How an action ended.
final class _ActionEnd {
  const _ActionEnd({
    this.row,
    this.outcome,
    this.rowInDoubt = false,
    this.gone = false,
  });

  /// The row as the server left it. Null when the action didn't say.
  final DataGateway? row;

  final DataGatewayDetailOutcome? outcome;

  /// The action ended with no word on the row, which has to be read again.
  final bool rowInDoubt;

  /// The server says the DataGateway is not there.
  final bool gone;
}
