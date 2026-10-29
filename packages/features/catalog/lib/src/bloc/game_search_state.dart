import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the search screen is showing (#42).
///
/// Every state carries the filter, so the filter's controls read the same
/// value whether or not a search is running.
sealed class GameSearchState extends Equatable {
  const GameSearchState({this.filter = const GameSearchFilter()});

  final GameSearchFilter filter;

  @override
  List<Object?> get props => [filter];
}

/// Nothing to search for yet.
final class GameSearchIdle extends GameSearchState {
  const GameSearchIdle({super.filter});
}

/// A search is running. Searching DataGateways can take up to 15 seconds.
final class GameSearchLoading extends GameSearchState {
  const GameSearchLoading({required this.query, super.filter});

  final String query;

  @override
  List<Object?> get props => [query, filter];
}

/// What the search found, in two sections (#42).
///
/// [onServer] is what this server holds. [fromSources] is what its
/// DataGateways found, less any game [onServer] already lists.
/// [missingSources] names every DataGateway that did not answer, so one that
/// dropped out does not read as one that found nothing.
///
/// [fromCache] says the server's search failed, so [onServer] is the games
/// cached on this device that match, and there is nothing from DataGateways.
final class GameSearchReady extends GameSearchState {
  const GameSearchReady({
    required this.query,
    this.onServer = const [],
    this.fromSources = const [],
    this.missingSources = const [],
    this.fromCache = false,
    super.filter,
  });

  final String query;
  final List<GameSearchHit> onServer;
  final List<GameSearchSourceHit> fromSources;
  final List<GameSearchSource> missingSources;
  final bool fromCache;

  /// How many results the screen lists.
  int get resultCount => onServer.length + fromSources.length;

  @override
  List<Object?> get props => [
    query,
    onServer,
    fromSources,
    missingSources,
    fromCache,
    filter,
  ];
}

/// The search could not run, and there was nothing on this device to show
/// instead.
final class GameSearchFailed extends GameSearchState {
  const GameSearchFailed({required this.query, super.filter});

  final String query;

  @override
  List<Object?> get props => [query, filter];
}

/// The server refused: this user may not read its games at all.
final class GameSearchDenied extends GameSearchState {
  const GameSearchDenied({required this.query, super.filter});

  final String query;

  @override
  List<Object?> get props => [query, filter];
}

/// A DataGateway, as a search result names it.
final class GameSearchSource extends Equatable {
  const GameSearchSource({required this.id, this.name});

  final String id;

  /// The DataGateway's name, or null where the user may not read
  /// DataGateways (#42). An unnamed DataGateway's results carry no source,
  /// and the note under the results counts the unnamed ones that did not
  /// answer.
  final String? name;

  @override
  List<Object?> get props => [id, name];
}

/// A result from one DataGateway.
final class GameSearchSourceHit extends Equatable {
  const GameSearchSourceHit({required this.source, required this.hit});

  final GameSearchSource source;
  final GameSearchHit hit;

  @override
  List<Object?> get props => [source, hit];
}
