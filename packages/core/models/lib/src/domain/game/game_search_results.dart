import 'package:freezed_annotation/freezed_annotation.dart';

import 'content_type.dart';
import 'platform_type.dart';

part 'game_search_results.freezed.dart';

/// One platform a search result says the game is on (#42).
@freezed
abstract class GameSearchPlatform with _$GameSearchPlatform {
  const factory GameSearchPlatform({
    required String name,
    String? abbreviation,
    required PlatformType platformType,
  }) = _GameSearchPlatform;
}

/// One game a search found (#42), on this server or at a DataGateway.
///
/// Stored nowhere: a search result is not a cached game. A result that is
/// already on this server carries its [gameId], and the detail screen reads
/// the game itself by that id.
@freezed
abstract class GameSearchHit with _$GameSearchHit {
  const GameSearchHit._();

  const factory GameSearchHit({
    /// The game's id where it was found: the server's game id for a result
    /// from this server, the DataGateway's own id otherwise.
    required String externalId,
    required String title,
    required ContentType contentType,

    /// The server's game id when the game is already on this server. Null
    /// for a DataGateway result the server does not hold.
    ///
    /// A DataGateway result can carry one too: the server recognises a game
    /// it imported earlier and says so (backend#662).
    String? gameId,
    int? yearPublished,
    int? minPlayers,
    int? maxPlayers,
    String? thumbnailUrl,
    @Default(<GameSearchPlatform>[]) List<GameSearchPlatform> platforms,
  }) = _GameSearchHit;

  /// Whether this server already holds the game.
  bool get isOnServer => gameId != null;
}

/// What one search answered (#42), by source, as the server groups it.
///
/// Every DataGateway that found nothing to show for a reason other than
/// having no matches is named in exactly one of four sets: the three ways it
/// can fail to answer, and [unfilterableDataGateways] for one the search's
/// filter skipped (#580). So a source that dropped out, or wasn't asked,
/// does not read as one that found nothing.
@freezed
abstract class GameSearchResults with _$GameSearchResults {
  const factory GameSearchResults({
    /// What this server holds. Empty when it found nothing.
    @Default(<GameSearchHit>[]) List<GameSearchHit> local,

    /// What each DataGateway found, keyed by its id, in the server's order.
    /// A DataGateway that found nothing has no key.
    @Default(<String, List<GameSearchHit>>{})
    Map<String, List<GameSearchHit>> byDataGateway,

    /// DataGateways whose search failed.
    @Default(<String>{}) Set<String> failedDataGateways,

    /// DataGateways that refused the search for now.
    @Default(<String>{}) Set<String> rateLimitedDataGateways,

    /// DataGateways the server could not reach.
    @Default(<String>{}) Set<String> unavailableDataGateways,

    /// DataGateways the search's filter skipped: they can't apply a player
    /// count or play time it names (#580).
    @Default(<String>{}) Set<String> unfilterableDataGateways,
  }) = _GameSearchResults;
}
