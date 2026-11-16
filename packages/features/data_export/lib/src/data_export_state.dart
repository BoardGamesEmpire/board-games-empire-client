import 'package:equatable/equatable.dart';

/// Where an export stands (#93).
enum DataExportPhase {
  /// Nothing is running and nothing is said.
  ready,

  /// The bundle is being assembled.
  assembling,

  /// The bundle holds data the server didn't confirm, and waits for the user
  /// to refresh or to save it as it is.
  unconfirmed,

  /// The bundle is being handed to the save sink.
  saving,

  /// The file was written where the user chose.
  saved,

  /// The browser was handed the file as a download.
  downloaded,

  /// The run failed; [DataExportState.failure] says why.
  failed,
}

/// Which control started the run in flight.
enum DataExportRun {
  /// The Export button.
  export,

  /// The warning's "Refresh and export".
  refreshAndExport,

  /// The warning's "Save this copy".
  saveAnyway,
}

/// Why an export failed.
enum DataExportFailure {
  /// There is no signed-in session on the server.
  notAuthenticated,

  /// The session could not be read.
  sessionUnavailable,

  /// The bundle was assembled but the file could not be saved.
  saveFailed,

  /// Assembling failed for any other reason.
  unexpected,
}

/// The export screen's state (#93).
///
/// The warning is two things, and the state says each: its banner
/// ([showsWarningBanner]) and its two buttons ([showsWarningButtons]). The
/// buttons stay from the moment the warning arrives until a run lands on
/// something else; the banner stays for as long as the copy it describes is
/// still the newest one known.
final class DataExportState extends Equatable {
  const DataExportState({
    this.phase = DataExportPhase.ready,
    this.unconfirmedKeys = const [],
    this.run,
    this.runUnderWarning = false,
    this.failure,
    this.answers = 0,
  });

  final DataExportPhase phase;

  /// The keys of the categories the warning's banner names, in the bundle's
  /// order.
  ///
  /// Not empty exactly while the banner is up: [DataExportPhase.unconfirmed],
  /// and a run started from there until a newer bundle comes back, the run
  /// fails, or, for "Save this copy", that copy's save lands.
  final List<String> unconfirmedKeys;

  /// Which control's run is in flight, through [DataExportPhase.assembling]
  /// and [DataExportPhase.saving]; null whenever none is.
  final DataExportRun? run;

  /// Whether the run in flight began with the warning up, whichever control
  /// started it. Its buttons then stay until the run lands, after its
  /// banner has gone if need be. False whenever no run is.
  final bool runUnderWarning;

  /// Set only in [DataExportPhase.failed].
  final DataExportFailure? failure;

  /// How many runs have answered: landed on [DataExportPhase.unconfirmed],
  /// [DataExportPhase.saved], [DataExportPhase.downloaded] or
  /// [DataExportPhase.failed]. A cancelled save is no answer.
  ///
  /// Banners are keyed by it, so the same answer twice is a new banner,
  /// announced and revealed again.
  final int answers;

  /// Whether the warning's banner is up.
  bool get showsWarningBanner => unconfirmedKeys.isNotEmpty;

  /// Whether the warning's two buttons are up.
  bool get showsWarningButtons =>
      phase == DataExportPhase.unconfirmed || runUnderWarning;

  /// Whether the last run put the file where the user can keep it.
  bool get isSuccess =>
      phase == DataExportPhase.saved || phase == DataExportPhase.downloaded;

  @override
  List<Object?> get props => [
    phase,
    unconfirmedKeys,
    run,
    runUnderWarning,
    failure,
    answers,
  ];
}
