import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the browse screen is showing (#42).
///
/// Every state carries the [sort] the list is read in, so the screen can show
/// which one is chosen whatever it is showing, and a retry reads the same
/// order.
sealed class GameBrowseState extends Equatable {
  const GameBrowseState({this.sort = GameSort.title});

  final GameSort sort;

  @override
  List<Object?> get props => [sort];
}

/// The first page has not arrived.
final class GameBrowseLoading extends GameBrowseState {
  const GameBrowseLoading({super.sort});
}

/// The catalog so far, a page at a time. [games] may be empty, which means
/// the server's catalog is.
///
/// [fromCache] says the server's catalog could not be read, so these are the
/// games cached on this device, in the order asked for, and [retrying] that
/// the server is being asked again while they stay up. [loadingMore] says the
/// next page is on its way, and [loadMoreFailed] that the last attempt at it
/// failed.
final class GameBrowseReady extends GameBrowseState {
  const GameBrowseReady({
    this.games = const [],
    this.hasMore = false,
    this.fromCache = false,
    this.retrying = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    super.sort,
  });

  final List<Game> games;
  final bool hasMore;
  final bool fromCache;
  final bool retrying;
  final bool loadingMore;
  final bool loadMoreFailed;

  @override
  List<Object?> get props => [
    ...super.props,
    games,
    hasMore,
    fromCache,
    retrying,
    loadingMore,
    loadMoreFailed,
  ];
}

/// The server could not be reached, and this device has no games cached to
/// show instead.
final class GameBrowseFailed extends GameBrowseState {
  const GameBrowseFailed({super.sort});
}

/// The server refused: this user may not read its games at all.
final class GameBrowseDenied extends GameBrowseState {
  const GameBrowseDenied({super.sort});
}
