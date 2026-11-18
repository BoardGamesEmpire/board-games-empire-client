import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show clampDouble, precisionErrorTolerance;
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/widgets.dart';
import 'package:ui/src/layout/bge_keyed_sliver_grid.dart';
import 'package:ui_tokens/ui_tokens.dart';

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
/// The grid doesn't scroll to a strip. [stripBoxKey] lets a caller find the
/// strip's box once it is laid out, as [BgeUnfoldingCovers] does to bring a
/// strip it opens into view.
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
    this.stripBoxKey,
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

  /// A key put on the strip's own box, inside its padding, so that a caller
  /// can find the strip once it is laid out. [BgeUnfoldingCovers] gives a new
  /// one with each open, to scroll the strip that open laid out into view
  /// (#818).
  ///
  /// The strip is built again when the key changes, so keep it while the
  /// same strip stays open.
  final Key? stripBoxKey;

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
            child: KeyedSubtree(
              key: stripBoxKey,
              child: stripBuilder(context, item),
            ),
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
  VoidCallback toggle, {
  required bool unfolded,
});

/// [BgeUnfoldingCovers.stripPlace]'s place: a type of its own, so that no
/// place a screen names can equal it.
@immutable
final class _StripPlace {
  const _StripPlace(this.id);

  final Object id;

  @override
  bool operator ==(Object other) => other is _StripPlace && other.id == id;

  @override
  int get hashCode => Object.hash(_StripPlace, id);
}

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
///   itemBuilder: (context, game, toggle, {required unfolded}) => BgeCoverTile(
///     label: game.title,
///     extent: null,
///     expansions: BgeCoverExpansions(expanded: unfolded, onToggle: toggle,
///         ...),
///   ),
///   stripBuilder: (context, game) => ExpansionsShelf(game),
/// )
/// ```
///
/// ## Scrolling
///
/// An open brings its strip into view (#818). After the frame that lays the
/// strip out, the scroll view moves the shortest distance that shows the
/// whole strip, so a strip opened under the last row in view ends at the
/// view's bottom. It never moves so far that the top of the tapped tile's
/// row leaves the view's top, so a strip taller than the room under its row
/// is shown from its top. A strip already in view doesn't move the page.
/// A strip whose top is above the view's, as when the open folds a strip
/// above it and its row moves up with everything under that strip, moves
/// the page back until the tapped tile's row is at the view's top, which
/// shows the strip from its top, and the control that opened it.
///
/// Only an open scrolls. A close doesn't, nor a strip that folds as another
/// opens, nor one that goes with its item or with the covers, and each of
/// them stops a reveal still on its way where it is. Under reduced motion
/// the page jumps; otherwise it moves over [BgeTokens.motionMedium]. Focus
/// isn't moved: it stays on the control that called `toggle`, such as the
/// cover's badge. A cover's "Show expansions" custom action calls the same
/// `toggle`, and scrolls the same way.
///
/// It isn't `Scrollable.ensureVisible`, which lines the strip up with an
/// edge of the view: its `keepVisibleAtEnd` policy would scroll a tall
/// strip's top, and the badge's row, off screen. The offset is worked out
/// from the strip's box and the tile's instead, as `BgeInlineBanner` works
/// out its own reveal.
///
/// The tile is found after the frame, where it was last built. A tile after
/// an open strip is built again as its own strip opens, as it moves into
/// the first grid, and its strip is brought into view all the same.
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

  /// The place a cover in the strip of the item whose [idOf] is [id] names
  /// in its `BgeFocusHandoff`, as the item's own tile names it in
  /// `BgeFocusHandoff.foldedPlace`. A top-level cover names none.
  ///
  /// Equal for equal ids, and never equal to a place a screen names itself.
  static Object stripPlace(Object id) => _StripPlace(id);

  /// A `BgeFocusHandoffScope.isShown` for covers laid out by a
  /// [BgeUnfoldingCovers] of [items] (#819): each item's cover at top level,
  /// under no place, and each of [stripIdsOf]'s covers in its strip, at
  /// [stripPlace].
  ///
  /// Every strip counts, folded or open, as the screen can't tell which is
  /// open: `BgeFocusHandoffScope.isShown` says why that is safe. The set is
  /// built at the first question, as the scope asks only once a focused
  /// item has left.
  static bool Function(Object identity, Object? place) isShownIn<T>(
    List<T> items, {
    required Object Function(T item) idOf,
    required Iterable<Object> Function(T item) stripIdsOf,
  }) {
    Set<(Object, Object?)>? shown;
    return (identity, place) => (shown ??= {
      for (final item in items) ...[
        (idOf(item), null),
        for (final id in stripIdsOf(item)) (id, stripPlace(idOf(item))),
      ],
    }).contains((identity, place));
  }

  @override
  State<BgeUnfoldingCovers<T>> createState() => _BgeUnfoldingCoversState<T>();
}

class _BgeUnfoldingCoversState<T> extends State<BgeUnfoldingCovers<T>> {
  /// The [BgeUnfoldingCovers.idOf] of the unfolded item, or null.
  Object? _unfolded;

  /// The key on the open strip's box, a new one with each open, so that a
  /// reveal finds the strip its own open laid out, and another item's strip
  /// never takes over the box of the one before it.
  GlobalKey? _stripBoxKey;

  /// The context each item's tile was last built in, by the item's
  /// [BgeUnfoldingCovers.idOf], for a reveal to find the opened item's tile.
  ///
  /// The last, not the one tapped: a tile that moves between the grid's
  /// slivers as its strip opens, as one after an open strip does, is built
  /// again in that frame, and the one tapped has gone.
  final _tiles = <Object, BuildContext>{};

  /// The reveal whose animation runs, until it ends.
  _Reveal? _revealing;

  @override
  void didUpdateWidget(BgeUnfoldingCovers<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_unfolded != null && _unfoldedIndex == null) {
      _unfolded = null;
      // A strip that goes with its item doesn't scroll the page: a reveal
      // still on its way stops.
      _stopRevealingAfterFrame();
    }
    final ids = {for (final item in widget.items) widget.idOf(item)};
    _tiles.removeWhere((id, tile) => !ids.contains(id) || !tile.mounted);
  }

  @override
  void dispose() {
    // The covers can go while their scroll view stays, as on a switch to the
    // list, which the reveal mustn't go on scrolling.
    _stopRevealingAfterFrame();
    super.dispose();
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

  /// Opens the strip of the item [id], or closes it. Only an open scrolls,
  /// once its strip is laid out.
  void _toggle(Object id) {
    // Either way, a reveal on its way stops where it is: a close doesn't
    // scroll, and an open reveals its own strip.
    _stopRevealing();
    if (_unfolded == id) {
      setState(() => _unfolded = null);
      return;
    }
    final strip = GlobalKey(debugLabel: 'BgeUnfoldingCovers.strip');
    setState(() {
      _unfolded = id;
      _stripBoxKey = strip;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(strip, id));
  }

  /// Scrolls the shortest distance that shows the whole of the strip on
  /// [strip], but never so far that the top of [id]'s tile leaves the
  /// view's, and not at all when the strip is already in view (#818). A
  /// strip whose top is above the view's scrolls back to the top of [id]'s
  /// tile instead.
  void _reveal(GlobalKey strip, Object id) {
    // Nothing for an open that a later toggle closed or replaced before its
    // frame.
    if (!mounted || strip != _stripBoxKey) return;
    final stripContext = strip.currentContext;
    final tile = _tiles[id];
    if (stripContext == null || tile == null || !tile.mounted) return;
    final stripBox = stripContext.findRenderObject();
    final tileBox = tile.findRenderObject();
    if (stripBox is! RenderBox ||
        !stripBox.attached ||
        !stripBox.hasSize ||
        tileBox is! RenderBox ||
        !tileBox.attached ||
        !tileBox.hasSize) {
      return;
    }
    final viewport = RenderAbstractViewport.maybeOf(stripBox);
    final position = Scrollable.maybeOf(stripContext)?.position;
    // The offsets below are worked out for a page that scrolls down, as
    // every page with covers does.
    if (viewport == null ||
        position == null ||
        position.axisDirection != AxisDirection.down) {
      return;
    }

    // Measured in the scroll view's own space, with no room left for an app
    // bar. A page's app bar is the Scaffold's, above the scroll view and not
    // over it, and neither Games nor Collection pins a sliver: measured under
    // `BgePage.slivers` on both, the view starts at the app bar's bottom, and
    // a revealed row's top and strip's bottom are clear of it.
    final stripTop = viewport.getOffsetToReveal(stripBox, 0).offset;
    final stripEnd = viewport.getOffsetToReveal(stripBox, 1).offset;
    final tileTop = viewport.getOffsetToReveal(tileBox, 0).offset;
    // A strip whose top is above the view's, as when the open folded a
    // strip above it and its row moved up, is revealed backwards: to the
    // tapped row's top, which shows the strip from its top and the badge
    // with it.
    final above = position.pixels - stripTop > precisionErrorTolerance;
    final target = clampDouble(
      above ? tileTop : math.min(stripEnd, tileTop),
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (!above && target <= position.pixels) return;

    // A jump under reduced motion, as `animateTo` takes a frame to arrive
    // whatever its duration. Not retried when the user's own scroll cuts the
    // animation short: where they scroll to is their choice.
    final duration = BgeMotion.durationOf(
      context,
      BgeTokens.of(context).motionMedium,
    );
    if (duration == Duration.zero) {
      position.jumpTo(target);
      return;
    }
    final reveal = _revealing = _Reveal(position);
    unawaited(
      position
          .animateTo(target, duration: duration, curve: BgeMotion.standard)
          .whenComplete(() {
            if (identical(_revealing, reveal)) _revealing = null;
          }),
    );
  }

  /// Stops the reveal on its way, if any, where it is.
  void _stopRevealing() {
    final reveal = _revealing;
    _revealing = null;
    reveal?.stop();
  }

  /// [_stopRevealing] once the frame is done, for a strip found gone while
  /// the tree is built: stopping a scroll sends its notifications, which
  /// mustn't run then.
  void _stopRevealingAfterFrame() {
    final reveal = _revealing;
    if (reveal == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Not when the reveal has ended since, or another has started.
      if (identical(_revealing, reveal)) _stopRevealing();
    });
  }

  @override
  Widget build(BuildContext context) => BgeUnfoldingCoverGrid<T>(
    items: widget.items,
    keyOf: widget.keyOf,
    unfolded: _unfoldedIndex,
    semanticIndexOffset: widget.semanticIndexOffset,
    stripKeyOf: (item) => ValueKey<Object>(widget.idOf(item)),
    stripBoxKey: _stripBoxKey,
    itemBuilder: (context, item) {
      final id = widget.idOf(item);
      final unfolded = _unfolded == id;
      // A context of the tile's own, kept each time the tile is built for a
      // reveal to find it by: the grid builds its tiles with its sliver's.
      return Builder(
        builder: (context) {
          _tiles[id] = context;
          return widget.itemBuilder(
            context,
            item,
            () => _toggle(id),
            unfolded: unfolded,
          );
        },
      );
    },
    stripBuilder: widget.stripBuilder,
  );
}

/// A reveal's scroll, while its animation runs (#818).
final class _Reveal {
  _Reveal(this.position);

  /// The position the reveal animates.
  final ScrollPosition position;

  /// Stops the animation where it is. A jump to where the page stands ends
  /// it without moving the page.
  ///
  /// Nothing once the scroll view has gone, and the position with it, or
  /// once nothing scrolls the page, as when a press has stopped the
  /// animation and holds the page itself.
  void stop() {
    if (position.context.notificationContext == null ||
        !position.isScrollingNotifier.value) {
      return;
    }
    position.jumpTo(position.pixels);
  }
}
