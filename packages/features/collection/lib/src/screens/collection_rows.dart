import 'package:game_collection/src/screens/collection_groups.dart';
import 'package:models/domain.dart';

/// One row of the collection list: a game's entries, as one stack when it is
/// owned more than once (#709), with the base game it is shown under (#711).
typedef CollectionRow = ({
  List<GameCollectionListItem> group,

  /// The base game this row is nested under, or null at top level.
  String? parentGameId,
  String? parentTitle,

  /// True when the game is an expansion and the whole collection holds none
  /// of its base games (#715): see [placeCollection].
  bool missingBase,
});

/// [items] gathered by game ([groupByGame]), then placed under the owned
/// base games they belong to (#711).
///
/// [items] is what the list shows, and [all] is the whole collection it was
/// filtered from (#715); [all] left out is [items], a list nothing filtered.
/// A filter runs before grouping, so a game's stack (#709) is made of the
/// entries that matched, and an expansion is nested only under a base game
/// [items] shows.
///
/// A top-level expansion is marked `missingBase` only when [all] holds none
/// of its base games, so the marker says what is true of the collection,
/// not of what a filter left: an expansion whose owned base game a filter
/// hid is top level and unmarked. `placeExpansions` decides it, from the
/// game ids of [all].
///
/// Matching is by game, not by platform: a base game owned on Steam holds an
/// expansion owned as a tabletop copy. The collection is read whole from the
/// cache, so the list is complete.
///
/// Placed once per list: the screen counts the rows for the page and draws
/// them in its sliver, from the same state's [items] and [all]. So neither
/// may change after the first call, as a bloc state's lists don't. The
/// answer is kept by [items], with the [all] it was placed from: a call for
/// the same [items] from another [all] places it again, for that one.
List<PlacedGame<List<GameCollectionListItem>>> placeCollection(
  List<GameCollectionListItem> items, {
  List<GameCollectionListItem>? all,
}) {
  final whole = all ?? items;
  final kept = _placed[items];
  if (kept != null && identical(kept.all, whole)) return kept.placed;

  final placed = placeExpansions(
    groupByGame(items),
    gameIdOf: (group) => group.first.gameId,
    baseGamesOf: (group) => group.first.baseGames,
    contentTypeOf: (group) => group.first.contentType,
    // A list nothing filtered owns what it shows.
    ownedGameIds: identical(whole, items)
        ? null
        : {for (final item in whole) item.gameId},
  );
  _placed[items] = (all: whole, placed: placed);
  return placed;
}

/// [placeCollection]'s answer for each list it was given, with the whole
/// collection it was placed from, kept as long as the list is.
final _placed =
    Expando<
      ({
        List<GameCollectionListItem> all,
        List<PlacedGame<List<GameCollectionListItem>>> placed,
      })
    >('placeCollection');

/// [placeCollection] flattened: each top-level group, then the groups nested
/// under it. An expansion of two owned base games appears under each.
///
/// [items] and [all] are [placeCollection]'s: [all], the whole collection,
/// decides a top-level row's `missingBase`. A nested row is never marked.
///
/// [titleOf] names a base game in `CollectionRow.parentTitle`; the screen
/// passes the formatter its own rows use, so the parent is named as its row
/// names it, subtitle and all. It stays out of this file so the file needs no
/// localizations.
List<CollectionRow> collectionRows(
  List<GameCollectionListItem> items, {
  List<GameCollectionListItem>? all,
  String Function(GameCollectionListItem item) titleOf = _plainTitle,
}) => [
  for (final top in placeCollection(items, all: all)) ...[
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
