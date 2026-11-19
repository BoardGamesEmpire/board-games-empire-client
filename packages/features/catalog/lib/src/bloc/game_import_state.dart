import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Why an import ended without its game (#43): what its copy says, and
/// whether trying again could change it.
enum GameImportFailure {
  /// The DataGateway no longer has the game. Trying again cannot help.
  notOnDataGateway,

  /// The DataGateway did not answer the server.
  dataGateway,

  /// The server failed the import, or answered in a way this client cannot
  /// follow.
  server,

  /// The import was cancelled on the server.
  cancelled,

  /// This user may not import games on this server. Trying again cannot
  /// help.
  forbidden,

  /// The start got no answer from the server.
  unreachable,
}

/// Where an import of a DataGateway result stands (#43).
sealed class GameImportState extends Equatable {
  const GameImportState();

  /// The jobs of the latest poll's batch: the requested game's, the
  /// expansions chosen with it, and any base game the server added. Empty
  /// until a poll has answered.
  List<ImportJob> get jobs => const [];

  @override
  List<Object?> get props => [jobs];
}

/// The start is on its way to the server.
final class GameImportStarting extends GameImportState {
  const GameImportStarting();
}

/// The server has queued the import. [running] is false while the requested
/// game's job waits to start.
final class GameImportInProgress extends GameImportState {
  const GameImportInProgress({required this.running, this.jobs = const []});

  final bool running;

  @override
  final List<ImportJob> jobs;

  @override
  List<Object?> get props => [running, jobs];
}

/// The deadline passed with no outcome. Not a failure: the server may still
/// finish the import, and checking again polls it.
final class GameImportStillRunning extends GameImportState {
  const GameImportStillRunning({this.gameId, this.jobs = const []});

  /// The requested game's id once its own job has completed: that game is on
  /// the server and can be opened while the other jobs run on. Null while it
  /// hasn't.
  final String? gameId;

  @override
  final List<ImportJob> jobs;

  @override
  List<Object?> get props => [gameId, jobs];
}

/// Every job of the import completed: the requested game is on the server, as
/// [gameId].
final class GameImportCompleted extends GameImportState {
  const GameImportCompleted({required this.gameId, required this.jobs});

  final String gameId;

  @override
  final List<ImportJob> jobs;

  @override
  List<Object?> get props => [gameId, jobs];
}

/// The requested game is on the server, as [gameId], but another job of the
/// batch ended without its game: [jobs] says which.
final class GameImportPartlyCompleted extends GameImportState {
  const GameImportPartlyCompleted({required this.gameId, required this.jobs});

  final String gameId;

  @override
  final List<ImportJob> jobs;

  @override
  List<Object?> get props => [gameId, jobs];
}

/// The import ended without the requested game, for [failure].
final class GameImportFailed extends GameImportState {
  const GameImportFailed({required this.failure, this.jobs = const []});

  final GameImportFailure failure;

  @override
  final List<ImportJob> jobs;

  @override
  List<Object?> get props => [failure, jobs];
}
