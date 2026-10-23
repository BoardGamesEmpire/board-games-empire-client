import 'package:equatable/equatable.dart';

/// Events of `GameBrowseBloc`.
sealed class GameBrowseEvent extends Equatable {
  const GameBrowseEvent();

  @override
  List<Object?> get props => [];
}

/// A read of the catalog. One runs at a time, and another arriving while it
/// does is dropped.
sealed class GameBrowseRead extends GameBrowseEvent {
  const GameBrowseRead();
}

/// Read the catalog from its first page: on entry, and on a retry.
final class GameBrowseLoadRequested extends GameBrowseRead {
  const GameBrowseLoadRequested();
}

/// Read the next page onto the end of the list.
final class GameBrowseMoreRequested extends GameBrowseRead {
  const GameBrowseMoreRequested();
}

/// A game turned out to be gone, wherever it was opened: the server has no
/// such game, or this user may no longer read it.
final class GameBrowseGameGone extends GameBrowseEvent {
  const GameBrowseGameGone(this.gameId);

  final String gameId;

  @override
  List<Object?> get props => [gameId];
}
