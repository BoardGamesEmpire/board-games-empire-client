import 'package:flutter/widgets.dart';
import 'package:ui/src/layout/bge_keyed_child_delegate.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// How many covers fit across a grid, from the window's [width] (not the
/// padded or capped width of the pane the grid sits in): 2 below
/// [BgeTokens.breakpointMedium], 3 from it, 4 from
/// [BgeTokens.breakpointExpanded] (#710).
///
/// The thresholds are the window size classes' own, so a grid gains a column
/// where the rest of the layout changes form.
int bgeGridColumns(double width, BgeTokens tokens) {
  if (width >= tokens.breakpointExpanded) {
    return 4;
  }
  if (width >= tokens.breakpointMedium) {
    return 3;
  }
  return 2;
}

/// The grid Games and Collection lay their covers out in (#710):
/// [bgeGridColumns] across, from the window's width, with
/// [BgeTokens.spaceSm] between the covers each way.
///
/// The width is the window's, from [MediaQuery.sizeOf], not the padded and
/// capped width of the pane the grid sits in, so a grid gains its columns at
/// the window size classes' thresholds.
SliverGridDelegateWithFixedCrossAxisCount bgeCoverGridDelegate(
  BuildContext context,
) {
  final tokens = BgeTokens.of(context);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: bgeGridColumns(MediaQuery.sizeOf(context).width, tokens),
    mainAxisSpacing: tokens.spaceSm,
    crossAxisSpacing: tokens.spaceSm,
  );
}

/// A sliver grid of tiles that keep their state when a tile before them
/// leaves or arrives (#549, #710). The grid sibling of `BgeKeyedSliverList`.
///
/// ```dart
/// BgeKeyedSliverGrid<Game>(
///   items: games,
///   keyOf: (game) => ValueKey(game.id),
///   gridDelegate: bgeCoverGridDelegate(context),
///   itemBuilder: (context, game) =>
///       BgeCoverTile(label: game.title, extent: null),
/// )
/// ```
///
/// ## Why the key and the lookup go together
///
/// A `SliverGrid.builder` matches the tiles it already built to the tiles it
/// is asked for by **position**, as a `SliverList.builder` does. A tile that
/// was third and is now second is handed the widget for the new second tile,
/// and when the two differ in key the old subtree is thrown away, focus and
/// all. Two things stop that, and neither is enough alone:
///
/// - **The key has to sit on the grid's own child**, not one level in.
/// - **The sliver needs a `findChildIndexCallback`**, which is how it asks
///   "where is the tile with this key now?".
///
/// This widget takes both from [keyOf], so a grid cannot take the key and
/// forget the lookup.
///
/// ## The key is on the tile's wrapper, not the tile
///
/// Each child is `KeyedSubtree(key: keyOf(item), child: itemBuilder(...))`,
/// so `find.byKey(keyOf(item))` finds the wrapper. The tile widget must not
/// carry the same key: a finder by that key would match both, and a
/// `GlobalKey` would be a duplicate.
///
/// The keys must be unique among [items] and must identify the thing a tile
/// shows, such as an id, not its position.
class BgeKeyedSliverGrid<T> extends StatelessWidget {
  /// Creates a sliver grid with one keyed tile per item in [items].
  const BgeKeyedSliverGrid({
    required this.items,
    required this.keyOf,
    required this.itemBuilder,
    required this.gridDelegate,
    this.semanticIndexOffset = 0,
    super.key,
  });

  /// The tiles' items, in the order they are shown.
  final List<T> items;

  /// The key that identifies `item` from one build to the next.
  ///
  /// Called once per item for the lookup, and once more for each tile built,
  /// so it should be cheap.
  final Key Function(T item) keyOf;

  /// Builds the tile for `item`. The tile must not carry [keyOf]'s key.
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// Lays the tiles out, such as [bgeCoverGridDelegate]'s covers.
  final SliverGridDelegate gridDelegate;

  /// Added to each tile's semantic index, as `SliverGrid.builder` does.
  ///
  /// For a grid that follows other indexed rows in the same scroll view, so
  /// a screen reader counts on from where they stopped.
  final int semanticIndexOffset;

  @override
  Widget build(BuildContext context) => SliverGrid(
    gridDelegate: gridDelegate,
    delegate: bgeKeyedChildDelegate(
      items: items,
      keyOf: keyOf,
      itemBuilder: itemBuilder,
      semanticIndexOffset: semanticIndexOffset,
    ),
  );
}
