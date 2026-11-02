import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Events of `GameBrowseBloc`.
sealed class GameBrowseEvent extends Equatable {
  const GameBrowseEvent();

  @override
  List<Object?> get props => [];
}

/// A read of the catalog. One runs at a time, and another arriving while it
/// does is dropped. A [GameBrowseSortChanged] is not one of them, and ends
/// the one running.
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

/// Read the catalog again from its first page, in [sort].
///
/// Not a [GameBrowseRead]: those are dropped while another runs, and a
/// change the user asked for must not be.
final class GameBrowseSortChanged extends GameBrowseEvent {
  const GameBrowseSortChanged(this.sort);

  final GameSort sort;

  @override
  List<Object?> get props => [sort];
}

/// A game turned out to be gone, wherever it was opened: the server has no
/// such game, or this user may no longer read it.
final class GameBrowseGameGone extends GameBrowseEvent {
  const GameBrowseGameGone(this.gameId);

  final String gameId;

  @override
  List<Object?> get props => [gameId];
}
