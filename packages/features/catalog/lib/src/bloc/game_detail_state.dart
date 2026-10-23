import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the game detail screen is showing (#42).
sealed class GameDetailState extends Equatable {
  const GameDetailState();

  @override
  List<Object?> get props => [];
}

/// The game has not arrived.
final class GameDetailLoading extends GameDetailState {
  const GameDetailLoading();
}

/// The game, with the platform games a collection add picks from (#45).
///
/// [platformGames] is empty until the server sends them (backend#791), and
/// always empty [fromCache], when the server's read failed and [game] is the
/// copy cached on this device.
final class GameDetailReady extends GameDetailState {
  const GameDetailReady({
    required this.game,
    this.platformGames = const [],
    this.fromCache = false,
  });

  final Game game;
  final List<PlatformGameSummary> platformGames;
  final bool fromCache;

  @override
  List<Object?> get props => [game, platformGames, fromCache];
}

/// The server has no such game, or this user may not read it.
///
/// One state for both: the user can do nothing different about either, and
/// telling them apart would say a private game exists.
final class GameDetailUnavailable extends GameDetailState {
  const GameDetailUnavailable();
}

/// The server could not be reached, and the game is not cached on this
/// device.
final class GameDetailFailed extends GameDetailState {
  const GameDetailFailed();
}
