import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../focus/bge_focus_ring.dart';
import '../focus/bge_pointer_focus.dart';
import 'bge_cover_expansions.dart';
import 'bge_stack_marker.dart';
import 'bge_thumbnail.dart';

/// A game's cover alone, as one tappable tile (#707).
///
/// No title is drawn: the cover is the tile, and [label] is its whole
/// accessible name, so a screen reader hears the game and a sighted user sees
/// the picture. The tile is [shelfExtent] square on a shelf, at any text
/// scale: only an expansions badge's count grows with the text, inside the
/// tile. With a null [extent] it fills the width it is given as a square, for
/// a grid's cells.
///
/// ## Feedback over the cover
///
/// Hover, press and focus are drawn over the whole tile. An ink effect paints
/// on the `Material` it sits on, beneath everything drawn above that, and the
/// cover is opaque, so an ink under the content would never show. The ink is a
/// layer above the content instead.
///
/// A tile focused from the keyboard also gets a [BgeFocusRing], because the
/// focus tint alone is faint over a picture.
///
/// ## Focus
///
/// A tap gives the tile focus before it calls [onTap], so that a pop-up or a
/// page opened from it hands focus back to this tile when it closes, as it
/// does after a keyboard activation.
///
/// Neither the ring nor the ink's focus tint shows for focus a pointer gave,
/// as with a browser's `:focus-visible` ([BgePointerFocus]). A touch turns
/// the highlight mode to touch, which hides both anyway. A mouse or a
/// trackpad leaves the mode at the keyboard's on a desktop, so from the press
/// until the next key press the tile hides them itself, including on the
/// focus handed back when a pop-up or a page the click opened closes. That
/// key press brings the ring back at once, so a user who goes to the keyboard
/// finds the tile. The faint tint comes back with the tile's next focus: an
/// ink highlight keeps the strength it was first drawn with (#707).
///
/// Without [onTap] a tile is inert content, not a focus stop, as the list's
/// rows are (#269).
///
/// ## Expansions
///
/// With [expansions], a badge at the bottom end of the picture counts a base
/// game's expansions and shows or hides them (#711). It is a button of its
/// own, a node and a focus stop after the cover's, not part of the cover's
/// merged node: a press on the cover opens the game, and a press on the
/// badge toggles. The cover's node offers the same toggle as a custom action,
/// so a screen reader on the cover doesn't have to find the badge.
///
/// Without a badge the tile's widget is the cover's node, as before. With one
/// it holds the two nodes and has none of its own, so a test finds the
/// cover's from inside it, such as from its [BgeThumbnail]. The cover keeps
/// its element, its focus and its node as the badge comes and goes, as a base
/// game's expansions arrive on a later page or after a sync.
///
/// A badge that goes while it holds focus gives it to the cover, so the user
/// keeps their place on the game. The cover and the badge share one
/// [BgePointerFocus] state, so focus a click gave the badge stays undrawn on
/// the cover until the next key press, and focus the keyboard gave it stays
/// drawn.
///
/// ## A missing part
///
/// [marked] outlines the picture in the tertiary colour and puts a broken
/// link at its top start, for an expansion shown without its base game
/// (#711). It is drawn only, and adds nothing to the semantics: [label] says
/// it.
class BgeCoverTile extends StatefulWidget {
  const BgeCoverTile({
    required this.label,
    this.imageUrl,
    this.onTap,
    this.stackCount,
    this.extent = shelfExtent,
    this.placeholderIcon = Icons.casino_outlined,
    this.expansions,
    this.marked = false,
    super.key,
  });

  /// The side of the tile on a shelf.
  static const double shelfExtent = 120;

  /// Finds the expansions badge.
  static const Key expansionsBadgeKey = Key('bge_cover_tile.expansions');

  /// Finds the missing-part mark: the outline and its icon.
  static const Key markKey = Key('bge_cover_tile.mark');

  /// The game's name: the tile's whole accessible name.
  final String label;

  /// The cover's address. Null draws a placeholder.
  final String? imageUrl;

  final VoidCallback? onTap;

  /// How many entries the cover stands for, when more than one (#709).
  ///
  /// Draws a [BgeStackMarker] around the picture alone: the tile stays one
  /// tap target with the ink and ring over the whole of it, and [label] is
  /// where the count is spoken.
  final int? stackCount;

  /// The side of the tile, or null to fill the incoming width, which must
  /// then be bounded.
  ///
  /// Never below the 48dp minimum target.
  final double? extent;

  /// Drawn on the placeholder.
  final IconData placeholderIcon;

  /// A base game's expansions, which a badge on the cover counts and toggles
  /// (#711). Null draws no badge.
  final BgeCoverExpansions? expansions;

  /// Whether the cover is of an expansion shown without its base game, which
  /// draws the missing-part mark (#711). The caller puts the words in
  /// [label].
  final bool marked;

  @override
  State<BgeCoverTile> createState() => _BgeCoverTileState();
}

class _BgeCoverTileState extends State<BgeCoverTile>
    with BgePointerFocus<BgeCoverTile> {
  final _focusNode = FocusNode(debugLabel: 'BgeCoverTile');

  /// Carries the cover across as a badge comes or goes, when it moves into a
  /// stack with the badge or out of one (#711).
  ///
  /// Keyboard focus would stay without it, as [_focusNode] is this state's,
  /// but the cover would be built again under a new semantics node, and a
  /// screen reader on it would lose its place. With it the cover keeps its
  /// elements, its ink and its node.
  final _coverKey = GlobalKey(debugLabel: 'BgeCoverTile.cover');

  /// The expansions badge's focus, held here so that the tile can tell when
  /// the badge goes while it holds focus (#711).
  final _badgeFocusNode = FocusNode(debugLabel: 'BgeCoverExpansionsBadge');

  @override
  void didUpdateWidget(BgeCoverTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A badge that goes while it holds focus gives it to the cover, so the
    // user keeps their place on the game, rather than focus going wherever it
    // was before the badge (#711). Requested before the badge's own node is
    // detached in this frame, which then hands its focus on to this request.
    if (oldWidget.expansions != null &&
        widget.expansions == null &&
        _badgeFocusNode.hasFocus) {
      _focusNode.requestFocus();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _badgeFocusNode.dispose();
    super.dispose();
  }

  /// A pointer's press, which a keyboard's activation never sends.
  ///
  /// Outside a scrolling shelf a mouse's comes as the button goes down, so the
  /// ink is built without its focus tint before the release's focus reaches
  /// it. Inside one it can come late: `BgeShelf` opts every pointer kind,
  /// mouse included, into its row's drag, so a click shorter than the tap
  /// slop delay delivers tap-down and tap together. The focus highlight is
  /// then made at full tint for the moment focus moves into the pop-up; the
  /// focus handed back is clean.
  void _onTapDown(TapDownDetails details) => notePointerPress(details.kind);

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    final stackCount = widget.stackCount;
    final expansions = widget.expansions;
    Widget picture(double extent) => _MissingPartMark(
      marked: widget.marked,
      child: BgeThumbnail(
        url: widget.imageUrl,
        extent: extent,
        placeholderIcon: widget.placeholderIcon,
      ),
    );
    final radius = BorderRadius.circular(BgeTokens.of(context).radiusSm);

    // MergeSemantics so that the label and the ink's tap and focus are one
    // node: a container alone would leave the ink as a child node. Outside the
    // LayoutBuilder, which has no semantics of its own to be found by.
    final cover = MergeSemantics(
      key: _coverKey,
      child: Semantics(
        label: widget.label,
        button: onTap != null,
        customSemanticsActions: expansions == null
            ? null
            : {
                CustomSemanticsAction(
                  label: expansions.expanded
                      ? expansions.hideLabel
                      : expansions.showLabel,
                ): expansions.onToggle,
              },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = math.max(
              kMinInteractiveDimension,
              widget.extent ?? constraints.maxWidth,
            );
            return BgeFocusRing(
              borderRadius: radius,
              suppressed: pointerFocus,
              builder: (context, onFocusChange) => SizedBox.square(
                dimension: side,
                child: Stack(
                  children: [
                    ExcludeSemantics(
                      child: stackCount == null
                          ? picture(side)
                          : BgeStackMarker(
                              count: stackCount,
                              // The marker adds its offsets to the picture.
                              child: picture(
                                side - BgeStackMarker.reachOf(context),
                              ),
                            ),
                    ),
                    Positioned.fill(
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          focusNode: _focusNode,
                          onTapDown: onTap == null ? null : _onTapDown,
                          onTap: onTap == null
                              ? null
                              : () {
                                  _focusNode.requestFocus();
                                  onTap();
                                },
                          onFocusChange: onFocusChange,
                          // The theme's tint, with no strength while the
                          // focus is a pointer's.
                          focusColor: pointerFocusColor,
                          borderRadius: radius,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    if (expansions == null) {
      return cover;
    }

    // Beside the cover's node rather than in it, and after it, so that it is
    // read and reached after the cover. At the picture's corner, which a
    // stack's cards leave clear. With the cover's pointer state, so a click
    // on either hides the feedback of both, as focus can pass between them.
    return Stack(
      children: [
        cover,
        PositionedDirectional(
          bottom: 0,
          end: stackCount == null ? 0 : BgeStackMarker.reachOf(context),
          child: sharePointerFocus(
            BgeCoverExpansionsBadge(
              key: BgeCoverTile.expansionsBadgeKey,
              expansions: expansions,
              focusNode: _badgeFocusNode,
            ),
          ),
        ),
      ],
    );
  }
}

/// The picture, outlined in the tertiary colour with a broken link at its
/// top start while [marked] (#711).
///
/// The picture is the same child either way, so it keeps its image as the
/// mark comes and goes. A stack's badge draws over the mark, as the marker
/// draws it over its child.
class _MissingPartMark extends StatelessWidget {
  const _MissingPartMark({required this.marked, required this.child});

  final bool marked;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final corner = Radius.circular(tokens.radiusSm);
    return Stack(
      children: [
        child,
        if (marked)
          Positioned.fill(
            key: BgeCoverTile.markKey,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: Border.all(
                  color: scheme.tertiary,
                  width: tokens.accentBarWidth,
                ),
                borderRadius: BorderRadius.all(corner),
              ),
              child: Align(
                alignment: AlignmentDirectional.topStart,
                // A tab in the outline's corner.
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.tertiary,
                    borderRadius: BorderRadiusDirectional.only(
                      topStart: corner,
                      bottomEnd: corner,
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(tokens.spaceXs),
                    child: Icon(
                      Icons.link_off,
                      size: tokens.spaceMd,
                      color: scheme.onTertiary,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
