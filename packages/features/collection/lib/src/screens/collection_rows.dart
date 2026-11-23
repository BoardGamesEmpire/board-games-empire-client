import 'package:game_collection/src/screens/collection_groups.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart' show BgeFoldedRow, foldNested;

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
/// expansion owned as a tabletop copy.
///
/// The cache is read whole, but not always finished: a pass writes it a page
/// at a time, so while the device's first sync runs, a base game may not
/// have landed (#810). [complete] false says so, and `placeExpansions` then
/// holds an expansion whose base game is not in [all] rather than show it
/// marked, to move it under the base game when that lands. A base game in
/// [all] holds nothing, filtered out or not. [complete] is true at any other
/// time: while no pass runs, once a pass has completed on this device, and
/// once one has failed in this session.
///
/// The hold is the device's, not the session's (#1011): on a cold start over
/// a cache an earlier session's pass completed, an expansion whose base game
/// isn't owned is shown marked throughout the pass.
///
/// Placed once per list: the screen counts the rows for the page and draws
/// them in its sliver, from the same state's [items], [all] and [complete].
/// So none may change after the first call, as a bloc state's lists don't.
/// The answer is kept by [items], with the [all] and [complete] it was
/// placed from: a call for the same [items] from another [all], or once the
/// list is complete, places it again, for that one.
List<PlacedGame<List<GameCollectionListItem>>> placeCollection(
  List<GameCollectionListItem> items, {
  List<GameCollectionListItem>? all,
  bool complete = true,
}) {
  final whole = all ?? items;
  final kept = _placed[items];
  if (kept != null && identical(kept.all, whole) && kept.complete == complete) {
    return kept.placed;
  }

  final placed = placeExpansions(
    groupByGame(items),
    gameIdOf: (group) => group.first.gameId,
    baseGamesOf: (group) => group.first.baseGames,
    contentTypeOf: (group) => group.first.contentType,
    complete: complete,
    // A list nothing filtered owns what it shows.
    ownedGameIds: identical(whole, items)
        ? null
        : {for (final item in whole) item.gameId},
  );
  _placed[items] = (all: whole, complete: complete, placed: placed);
  return placed;
}

/// [placeCollection]'s answer for each list it was given, with the whole
/// collection and the completeness it was placed from, kept as long as the
/// list is.
final _placed =
    Expando<
      ({
        List<GameCollectionListItem> all,
        bool complete,
        List<PlacedGame<List<GameCollectionListItem>>> placed,
      })
    >('placeCollection');

/// [placeCollection] as the list lays it out (#711, #1048): each top-level
/// group, and under a base game the groups nested under it, while [open]
/// holds the base game's id ([foldNested]). An expansion of two owned base
/// games is under each.
///
/// A base game starts folded: its `BgeTopRow` alone, which carries the rows
/// nested under it for the count on its control. Open, up to
/// `BgeNestedRowsBox.inlineLimit`, four, nested rows follow it, each a
/// `BgeNestedRow`, and more are one `BgeNestedBox`.
///
/// [items], [all] and [complete] are [placeCollection]'s: [all], the whole
/// collection, decides a top-level row's `missingBase`. A nested row is never
/// marked.
///
/// [titleOf] names a base game in `CollectionRow.parentTitle`; the screen
/// passes the formatter its own rows use, so the parent is named as its row
/// names it, subtitle and all. It stays out of this file so the file needs no
/// localizations.
List<BgeFoldedRow<CollectionRow>> collectionRows(
  List<GameCollectionListItem> items, {
  required Set<Object> open,
  List<GameCollectionListItem>? all,
  String Function(GameCollectionListItem item) titleOf = _plainTitle,
  bool complete = true,
}) => foldNested<CollectionRow>(
  groups: [
    for (final top in placeCollection(items, all: all, complete: complete))
      (
        (
          group: top.item,
          parentGameId: null,
          parentTitle: null,
          missingBase: top.missingBase,
        ),
        [
          for (final nested in top.expansions)
            (
              group: nested,
              parentGameId: top.item.first.gameId,
              parentTitle: titleOf(top.item.first),
              missingBase: false,
            ),
        ],
      ),
  ],
  open: open,
  idOf: (row) => row.group.first.gameId,
);

/// The games of the whole collection, [all], with games nested under them,
/// placed as [complete] says (#1048): the base games a list may hold open.
///
/// Read from the whole collection, not from what a filter left, so that a
/// search or a filter that hides an open base game, or its expansions,
/// folds nothing: cleared, it shows the game open as it was.
List<String> collectionNestingGameIds(
  List<GameCollectionListItem> all, {
  bool complete = true,
}) => [
  for (final top in placeCollection(all, complete: complete))
    if (top.expansions.isNotEmpty) top.item.first.gameId,
];

String _plainTitle(GameCollectionListItem item) => item.title;
