import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'bge_keyed_sliver_grid.dart';

/// A cover grid that can open a strip under one row (#711).
///
/// It is told which item's strip is open. [BgeUnfoldingCovers] keeps that
/// itself, for a grid whose tiles open and close their own strips.
///
/// ```dart
/// final index = games.indexWhere((game) => game.id == unfoldedId);
/// BgeUnfoldingCoverGrid<Game>(
///   items: games,
///   keyOf: (game) => ValueKey(game.id),
///   itemBuilder: (context, game) => BgeCoverTile(label: game.title,
///       extent: null),
///   unfolded: index < 0 ? null : index,
///   stripBuilder: (context, game) => ExpansionsShelf(game),
/// )
/// ```
///
/// Folded, it is one [BgeKeyedSliverGrid] of [items], laid out by
/// [bgeCoverGridDelegate]. With [unfolded] set, the grid is split after the
/// row that item is in, and [stripBuilder]'s strip sits between the two
/// halves, as wide as the grid, padded by [BgeTokens.spaceSm] above and below
/// as the rows are spaced. A base game's expansions open under its cover this
/// way, in the grid's own scroll view.
///
/// ## Focus
///
/// The grid of the rows up to the strip stays the first sliver, folded or
/// not, so the tiles in it keep their elements, and any focus, as the strip
/// opens and closes. The item whose strip it is is one of them. A tile after
/// the strip moves into a grid of its own as the strip opens, and back as it
/// closes, so it is built again: wrap the tiles in a `BgeFocusHandoff`, which
/// hands focus to the new one.
///
/// A strip for another item is a new strip, which starts at its own
/// beginning.
///
/// ## Semantics
///
/// The tiles after the strip count on from the ones before it, so a screen
/// reader says "3 of 9" across it. The strip is not one of the covers, and
/// takes no index. The scroll view's `semanticChildCount` is the caller's,
/// as for any sliver page: the number of [items].
class BgeUnfoldingCoverGrid<T> extends StatelessWidget {
  /// Creates a cover grid of [items], with a strip under [unfolded]'s row.
  const BgeUnfoldingCoverGrid({
    required this.items,
    required this.keyOf,
    required this.itemBuilder,
    required this.unfolded,
    required this.stripBuilder,
    this.semanticIndexOffset = 0,
    this.stripKeyOf,
    super.key,
  });

  /// The covers' items, in the order they are shown.
  final List<T> items;

  /// The key that identifies `item` from one build to the next, as for
  /// [BgeKeyedSliverGrid.keyOf].
  final Key Function(T item) keyOf;

  /// Builds the tile for `item`. The tile must not carry [keyOf]'s key.
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// The index in [items] of the item whose strip is open, or null for none.
  final int? unfolded;

  /// Builds the strip for `item`, the one at [unfolded].
  final Widget Function(BuildContext context, T item) stripBuilder;

  /// Added to each tile's semantic index, as for
  /// [BgeKeyedSliverGrid.semanticIndexOffset].
  final int semanticIndexOffset;

  /// The key of `item`'s strip, [keyOf] when null. A strip with a new key is
  /// a new strip. Give one that stays the same while the item's tile changes
  /// form, so the open strip keeps its scroll and focus.
  final Key Function(T item)? stripKeyOf;

  @override
  Widget build(BuildContext context) {
    final unfolded = this.unfolded;
    assert(
      unfolded == null || (unfolded >= 0 && unfolded < items.length),
      'unfolded is $unfolded, outside the ${items.length} items',
    );
    final delegate = bgeCoverGridDelegate(context);
    BgeKeyedSliverGrid<T> grid(List<T> items, int semanticIndexOffset) =>
        BgeKeyedSliverGrid<T>(
          items: items,
          keyOf: keyOf,
          itemBuilder: itemBuilder,
          gridDelegate: delegate,
          semanticIndexOffset: semanticIndexOffset,
        );

    if (unfolded == null) {
      return SliverMainAxisGroup(slivers: [grid(items, semanticIndexOffset)]);
    }

    final columns = delegate.crossAxisCount;
    final rowEnd = math.min(items.length, (unfolded ~/ columns + 1) * columns);
    final item = items[unfolded];
    final spacing = BgeTokens.of(context).spaceSm;
    return SliverMainAxisGroup(
      slivers: [
        grid(items.sublist(0, rowEnd), semanticIndexOffset),
        SliverToBoxAdapter(
          // Keyed by the item, so another item's strip is a new one.
          key: ValueKey<Key>((stripKeyOf ?? keyOf)(item)),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: spacing),
            child: stripBuilder(context, item),
          ),
        ),
        grid(items.sublist(rowEnd), semanticIndexOffset + rowEnd),
      ],
    );
  }
}

/// Builds the tile for `item` in a [BgeUnfoldingCovers]: `unfolded` says
/// whether its strip is open, and `toggle` opens or closes it.
typedef BgeUnfoldingTileBuilder<T> = Widget Function(
  BuildContext context,
  T item,
  bool unfolded,
  VoidCallback toggle,
);

/// A [BgeUnfoldingCoverGrid] that holds which item is unfolded (#711).
///
/// One item is unfolded at a time, and unfolding another folds the first.
/// The unfold goes once that item is no longer among [items], or no longer
/// [hasStrip], as when its expansions are found gone, so the grid is whole
/// again and the item doesn't come back unfolded.
///
/// ```dart
/// BgeUnfoldingCovers<Game>(
///   items: games,
///   keyOf: (game) => ValueKey(game.id),
///   idOf: (game) => game.id,
///   hasStrip: (game) => expansionsOf(game).isNotEmpty,
///   itemBuilder: (context, game, unfolded, toggle) => BgeCoverTile(
///     label: game.title,
///     extent: null,
///     expansions: BgeCoverExpansions(expanded: unfolded, onToggle: toggle,
///         ...),
///   ),
///   stripBuilder: (context, game) => ExpansionsShelf(game),
/// )
/// ```
class BgeUnfoldingCovers<T> extends StatefulWidget {
  /// Creates a cover grid of [items] that opens one item's strip at a time.
  const BgeUnfoldingCovers({
    required this.items,
    required this.keyOf,
    required this.idOf,
    required this.hasStrip,
    required this.itemBuilder,
    required this.stripBuilder,
    this.semanticIndexOffset = 0,
    super.key,
  });

  /// The covers' items, in the order they are shown.
  final List<T> items;

  /// As for [BgeUnfoldingCoverGrid.keyOf].
  final Key Function(T item) keyOf;

  /// Which item is unfolded, from one build to the next. Unlike [keyOf], it
  /// stays the same when the item's tile changes form, as one copy of a game
  /// becoming a stack of them does, so the item stays unfolded, and its open
  /// strip stays the same strip.
  final Object Function(T item) idOf;

  /// Whether `item` has a strip to open. The unfold goes once it hasn't.
  final bool Function(T item) hasStrip;

  /// Builds the tile for `item`. The tile must not carry [keyOf]'s key.
  final BgeUnfoldingTileBuilder<T> itemBuilder;

  /// As for [BgeUnfoldingCoverGrid.stripBuilder].
  final Widget Function(BuildContext context, T item) stripBuilder;

  /// As for [BgeUnfoldingCoverGrid.semanticIndexOffset].
  final int semanticIndexOffset;

  @override
  State<BgeUnfoldingCovers<T>> createState() => _BgeUnfoldingCoversState<T>();
}

class _BgeUnfoldingCoversState<T> extends State<BgeUnfoldingCovers<T>> {
  /// The [BgeUnfoldingCovers.idOf] of the unfolded item, or null.
  Object? _unfolded;

  @override
  void didUpdateWidget(BgeUnfoldingCovers<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_unfoldedIndex == null) _unfolded = null;
  }

  /// Where the unfolded item is among the items, or null when none is, or it
  /// no longer has a strip.
  int? get _unfoldedIndex {
    final unfolded = _unfolded;
    if (unfolded == null) return null;
    final index = widget.items.indexWhere(
      (item) => widget.idOf(item) == unfolded && widget.hasStrip(item),
    );
    return index < 0 ? null : index;
  }

  void _toggle(Object id) =>
      setState(() => _unfolded = _unfolded == id ? null : id);

  @override
  Widget build(BuildContext context) => BgeUnfoldingCoverGrid<T>(
    items: widget.items,
    keyOf: widget.keyOf,
    unfolded: _unfoldedIndex,
    semanticIndexOffset: widget.semanticIndexOffset,
    stripKeyOf: (item) => ValueKey<Object>(widget.idOf(item)),
    itemBuilder: (context, item) {
      final id = widget.idOf(item);
      return widget.itemBuilder(
        context,
        item,
        _unfolded == id,
        () => _toggle(id),
      );
    },
    stripBuilder: widget.stripBuilder,
  );
}
