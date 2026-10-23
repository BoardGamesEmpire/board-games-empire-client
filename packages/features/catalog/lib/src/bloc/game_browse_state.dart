import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the browse screen is showing (#42).
sealed class GameBrowseState extends Equatable {
  const GameBrowseState();

  @override
  List<Object?> get props => [];
}

/// The first page has not arrived.
final class GameBrowseLoading extends GameBrowseState {
  const GameBrowseLoading();
}

/// The catalog so far, a page at a time. [games] may be empty, which means
/// the server's catalog is.
///
/// [fromCache] says the server's catalog could not be read, so these are the
/// games cached on this device, in the catalog's order, and [retrying] that
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
  });

  final List<Game> games;
  final bool hasMore;
  final bool fromCache;
  final bool retrying;
  final bool loadingMore;
  final bool loadMoreFailed;

  @override
  List<Object?> get props => [
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
  const GameBrowseFailed();
}

/// The server refused: this user may not read its games at all.
final class GameBrowseDenied extends GameBrowseState {
  const GameBrowseDenied();
}
