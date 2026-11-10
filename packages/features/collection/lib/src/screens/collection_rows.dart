import 'package:game_collection/src/screens/collection_groups.dart';
import 'package:models/domain.dart';

/// One row of the collection list: a game's entries, as one stack when it is
/// owned more than once (#709), with the base game it is shown under (#711).
typedef CollectionRow = ({
  List<GameCollectionListItem> group,

  /// The base game this row is nested under, or null at top level.
  String? parentGameId,
  String? parentTitle,

  /// True when the game is an expansion shown without its base game.
  bool missingBase,
});

/// [items] gathered by game ([groupByGame]), then placed under the owned
/// base games they belong to (#711).
///
/// Matching is by game, not by platform: a base game owned on Steam holds an
/// expansion owned as a tabletop copy. The collection is read whole from the
/// cache, so the list is complete.
///
/// Placed once per list: the screen counts the rows for the page and draws
/// them in its sliver, from the same state's [items]. So [items] must not
/// change after the first call, as a bloc state's list doesn't.
List<PlacedGame<List<GameCollectionListItem>>> placeCollection(
  List<GameCollectionListItem> items,
) => _placed[items] ??= placeExpansions(
  groupByGame(items),
  gameIdOf: (group) => group.first.gameId,
  baseGamesOf: (group) => group.first.baseGames,
  contentTypeOf: (group) => group.first.contentType,
);

/// [placeCollection]'s answer for each list it was given, kept as long as
/// the list is.
final _placed = Expando<List<PlacedGame<List<GameCollectionListItem>>>>(
  'placeCollection',
);

/// [placeCollection] flattened: each top-level group, then the groups nested
/// under it. An expansion of two owned base games appears under each.
///
/// [titleOf] names a base game in `CollectionRow.parentTitle`; the screen
/// passes the formatter its own rows use, so the parent is named as its row
/// names it, subtitle and all. It stays out of this file so the file needs no
/// localizations.
List<CollectionRow> collectionRows(
  List<GameCollectionListItem> items, {
  String Function(GameCollectionListItem item) titleOf = _plainTitle,
}) => [
  for (final top in placeCollection(items)) ...[
    (
      group: top.item,
      parentGameId: null,
      parentTitle: null,
      missingBase: top.missingBase,
    ),
    for (final nested in top.expansions)
      (
        group: nested,
        parentGameId: top.item.first.gameId,
        parentTitle: titleOf(top.item.first),
        missingBase: false,
      ),
  ],
];

String _plainTitle(GameCollectionListItem item) => item.title;
