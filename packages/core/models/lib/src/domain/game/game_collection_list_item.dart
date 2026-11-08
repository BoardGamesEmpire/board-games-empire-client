import 'package:freezed_annotation/freezed_annotation.dart';

import 'content_type.dart';
import 'expansion_link.dart';
import 'game_collection.dart';

part 'game_collection_list_item.freezed.dart';

/// One row of the collection list: the entry plus what it takes to show it
/// (#259).
///
/// Built by `GameCollectionRepository.watchCollectionListItems` from a join of
/// the entry onto its cached platform game and game. The display fields are
/// resolved once, in that join, so no widget has to know the fallback rule.
@freezed
abstract class GameCollectionListItem with _$GameCollectionListItem {
  const factory GameCollectionListItem({
    required GameCollection entry,

    /// The id of the [Game] the entry's platform game belongs to: what a
    /// caller counts the distinct games in a collection by.
    required String gameId,
    required String title,
    String? subtitle,
    required String platformName,

    /// The platform game's own picture when it has one, otherwise the
    /// game's: each one's thumbnail, else its full image (#709). Null when
    /// none of the four is set.
    String? thumbnail,

    /// The game's base games (#711); none for a base game.
    @Default(<ExpansionLink>[]) List<ExpansionLink> baseGames,

    /// What the game is (#711).
    @Default(ContentType.baseGame) ContentType contentType,
  }) = _GameCollectionListItem;
}
