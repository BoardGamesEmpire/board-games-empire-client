import 'package:equatable/equatable.dart';

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

  @override
  List<Object?> get props => [];
}

/// The start is on its way to the server.
final class GameImportStarting extends GameImportState {
  const GameImportStarting();
}

/// The server has queued the import. [running] is false while the base
/// game's job waits to start.
final class GameImportInProgress extends GameImportState {
  const GameImportInProgress({required this.running});

  final bool running;

  @override
  List<Object?> get props => [running];
}

/// The deadline passed with no outcome. Not a failure: the server may still
/// finish the import, and checking again polls it.
final class GameImportStillRunning extends GameImportState {
  const GameImportStillRunning();
}

/// The base game is on the server, as [gameId].
final class GameImportCompleted extends GameImportState {
  const GameImportCompleted({required this.gameId});

  final String gameId;

  @override
  List<Object?> get props => [gameId];
}

/// The import ended without the game, for [failure].
final class GameImportFailed extends GameImportState {
  const GameImportFailed({required this.failure});

  final GameImportFailure failure;

  @override
  List<Object?> get props => [failure];
}
