import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/game/content_type.dart';
import 'package:models/src/domain/game/expansion_link.dart';
import 'package:models/src/domain/game/game_collection.dart';
import 'package:models/src/domain/game/platform_type.dart';

part 'game_collection_list_item.freezed.dart';

/// One row of the collection list: the entry plus what it takes to show it
/// (#259).
///
/// Built by `GameCollectionRepository.watchCollectionListItems` from a join of
/// the entry onto its cached platform game and game. The display fields and
/// the facts a filter and sort read (#715) are resolved once, in that join,
/// so no widget has to know the fallback rule.
@freezed
abstract class GameCollectionListItem with _$GameCollectionListItem {
  const factory GameCollectionListItem({
    required GameCollection entry,

    /// The id of the `Game` the entry's platform game belongs to: what a
    /// caller counts the distinct games in a collection by.
    required String gameId,
    required String title,
    required String platformName,
    String? subtitle,

    /// The platform game's own picture when it has one, otherwise the
    /// game's: each one's thumbnail, else its full image (#709). Null when
    /// none of the four is set.
    String? thumbnail,

    /// The game's base games (#711); none for a base game.
    @Default(<ExpansionLink>[]) List<ExpansionLink> baseGames,

    /// What the game is (#711).
    @Default(ContentType.baseGame) ContentType contentType,

    /// What kind of platform the entry's platform game is on (#715). Null
    /// when the cache holds none.
    PlatformType? platformType,

    /// The year the game was published (#715). Null when the cache holds no
    /// value.
    int? publishYear,

    /// The players the entry's platform game takes, as a pair (#715): the
    /// platform game's own two when either is set, otherwise the game's two.
    /// A null side means the cache holds no value for it.
    int? minPlayers,
    int? maxPlayers,

    /// The play time in minutes, resolved as a pair the way the players are
    /// (#715): the platform game's own two when either is set, otherwise the
    /// game's two. A null side means the cache holds no value for it.
    int? minPlayTime,
    int? maxPlayTime,
  }) = _GameCollectionListItem;
}
