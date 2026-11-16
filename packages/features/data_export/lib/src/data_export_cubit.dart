import 'dart:async';

import 'package:data_export/src/assemble_user_data_export.dart';
import 'package:data_export/src/data_export_state.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:observability/observability.dart';

/// Assembles the user's export for one server and saves it (#93).
///
/// ## A run
///
/// [export] assembles the bundle. A bundle whose every category the server
/// confirmed is saved at once. One with data the server didn't confirm is
/// held at [DataExportPhase.unconfirmed], for the user to choose:
/// [refreshAndExport] assembles again, asking each exporter to refresh first,
/// and [saveAnyway] saves the held bundle as it is. A save the user cancels
/// goes back to where it started, with nothing said.
///
/// [DataExportState.run] says which of the three started the run in flight,
/// and is null whenever none is. A press while a run is in flight does
/// nothing.
///
/// ## The warning
///
/// Its buttons stay from the moment it arrives until a run lands on
/// something else, whichever control started that run: a run begun under
/// the warning is [DataExportState.runUnderWarning] until it lands. Its
/// banner stays while the copy it describes is still the newest one known:
/// through assembling, and through saving when that copy is the one being
/// saved ([saveAnyway]). A newer bundle that comes back confirmed takes the
/// banner down as its save starts; one that comes back unconfirmed is a new
/// warning, a new answer.
///
/// ## The dwell
///
/// An answer that comes in the turn its run began, as a failed session read
/// does offline, would replace the busy state before the page had drawn it,
/// and a run that ends where it began would look like a press that did
/// nothing. So an answer lands no sooner than [answerDwell] after its run
/// went busy. Saving is not held: the save dialog opens at once.
class DataExportCubit extends Cubit<DataExportState> {
  DataExportCubit({
    required this._server,
    required this._assemble,
    required this._sink,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.data_export'),
       super(const DataExportState());

  /// How long a run's busy state stays up before its answer replaces it,
  /// however soon the answer comes. An answer that takes longer is not held
  /// any further.
  static const Duration answerDwell = Duration(milliseconds: 300);

  final ActiveServer _server;
  final AssembleUserDataExport _assemble;
  final UserDataExportSink _sink;
  final BgeLogger _logger;

  /// The bundle the warning is about.
  UserDataExportBundle? _held;

  /// Completes once the running run's busy state has been up for
  /// [answerDwell].
  Completer<void> _dwell = Completer<void>()..complete();
  Timer? _dwellTimer;

  /// Assembles the bundle and saves it, unless the server didn't confirm all
  /// of it.
  void export() => _start(DataExportRun.export);

  /// As [export], asking each exporter to bring its data up to date first.
  void refreshAndExport() => _start(DataExportRun.refreshAndExport);

  /// Saves the bundle the warning is about, as it is.
  void saveAnyway() {
    final held = _held;
    if (isClosed ||
        state.phase != DataExportPhase.unconfirmed ||
        held == null) {
      return;
    }
    _goBusy(
      DataExportState(
        phase: DataExportPhase.saving,
        // The copy the banner describes is the one being saved.
        unconfirmedKeys: state.unconfirmedKeys,
        run: DataExportRun.saveAnyway,
        runUnderWarning: true,
        answers: state.answers,
      ),
    );
    unawaited(_save(held));
  }

  /// Retires the success banner.
  void dismissOutcome() {
    if (isClosed) return;
    if (state.isSuccess) emit(DataExportState(answers: state.answers));
  }

  void _start(DataExportRun run) {
    if (isClosed || state.run != null) return;
    _goBusy(
      DataExportState(
        phase: DataExportPhase.assembling,
        // The held copy is still the newest known until the new one comes.
        unconfirmedKeys: state.unconfirmedKeys,
        run: run,
        runUnderWarning: state.showsWarningButtons,
        answers: state.answers,
      ),
    );
    unawaited(_run(refresh: run == DataExportRun.refreshAndExport));
  }

  Future<void> _run({required bool refresh}) async {
    final UserDataExportBundle bundle;
    try {
      bundle = await _assemble(_server, refresh: refresh);
    } on ExportNotAuthenticatedException {
      return _fail(DataExportFailure.notAuthenticated);
    } on ExportSessionUnavailableException {
      return _fail(DataExportFailure.sessionUnavailable);
    } on Object catch (error, stackTrace) {
      _logger.error(
        'Assembling the export failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _fail(DataExportFailure.unexpected);
    }
    if (isClosed) return;

    if (bundle.unconfirmedKeys.isNotEmpty) {
      _held = bundle;
      return _land(
        DataExportPhase.unconfirmed,
        unconfirmedKeys: List.unmodifiable(bundle.unconfirmedKeys),
      );
    }
    _held = null;
    emit(
      DataExportState(
        phase: DataExportPhase.saving,
        // A newer copy, confirmed: the banner no longer describes anything.
        run: state.run,
        runUnderWarning: state.runUnderWarning,
        answers: state.answers,
      ),
    );
    return _save(bundle);
  }

  Future<void> _save(UserDataExportBundle bundle) async {
    final UserDataExportSaveResult result;
    try {
      result = await _sink.save(
        fileName: bundle.fileName,
        bytes: bundle.toBytes(),
      );
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Saving the export failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _fail(DataExportFailure.saveFailed);
    }
    if (isClosed) return;

    switch (result) {
      case UserDataExportSaveResult.saved:
        _held = null;
        return _land(DataExportPhase.saved);
      case UserDataExportSaveResult.downloaded:
        _held = null;
        return _land(DataExportPhase.downloaded);
      case UserDataExportSaveResult.cancelled:
        // Back where the save started: the warning, with its bundle still
        // held, for "Save this copy"; otherwise ready.
        emit(
          state.run == DataExportRun.saveAnyway
              ? DataExportState(
                  phase: DataExportPhase.unconfirmed,
                  unconfirmedKeys: state.unconfirmedKeys,
                  answers: state.answers,
                )
              : DataExportState(answers: state.answers),
        );
    }
  }

  Future<void> _fail(DataExportFailure failure) {
    _held = null;
    return _land(DataExportPhase.failed, failure: failure);
  }

  /// Emits a run's answer once its busy state has had its dwell.
  Future<void> _land(
    DataExportPhase phase, {
    List<String> unconfirmedKeys = const [],
    DataExportFailure? failure,
  }) async {
    await _dwell.future;
    if (isClosed) return;
    emit(
      DataExportState(
        phase: phase,
        unconfirmedKeys: unconfirmedKeys,
        failure: failure,
        answers: state.answers + 1,
      ),
    );
  }

  void _goBusy(DataExportState busy) {
    emit(busy);
    _dwellTimer?.cancel();
    // Released, so nothing still waiting on the last dwell waits forever.
    if (!_dwell.isCompleted) _dwell.complete();
    final dwell = Completer<void>();
    _dwell = dwell;
    _dwellTimer = Timer(answerDwell, dwell.complete);
  }

  @override
  Future<void> close() {
    // An answer held for the dwell is released, to find the cubit closed.
    _dwellTimer?.cancel();
    if (!_dwell.isCompleted) _dwell.complete();
    return super.close();
  }
}
