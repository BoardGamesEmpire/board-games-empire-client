import 'package:freezed_annotation/freezed_annotation.dart';

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
    required String title,
    String? subtitle,
    required String platformName,

    /// The platform game's thumbnail when it has one, otherwise the game's.
    /// Null when neither does.
    String? thumbnail,
  }) = _GameCollectionListItem;
}
