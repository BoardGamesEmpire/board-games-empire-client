import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../focus/bge_focus_ring.dart';
import '../focus/bge_pointer_focus.dart';
import 'bge_stack_marker.dart';
import 'bge_thumbnail.dart';

/// A game's cover alone, as one tappable tile (#707).
///
/// No title is drawn: the cover is the tile, and [label] is its whole
/// accessible name, so a screen reader hears the game and a sighted user sees
/// the picture. The tile is [shelfExtent] square on a shelf, at any text
/// scale, as nothing in it grows with the text. With a null [extent] it fills
/// the width it is given as a square, for a grid's cells.
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
class BgeCoverTile extends StatefulWidget {
  const BgeCoverTile({
    required this.label,
    this.imageUrl,
    this.onTap,
    this.stackCount,
    this.extent = shelfExtent,
    this.placeholderIcon = Icons.casino_outlined,
    super.key,
  });

  /// The side of the tile on a shelf.
  static const double shelfExtent = 120;

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

  @override
  State<BgeCoverTile> createState() => _BgeCoverTileState();
}

class _BgeCoverTileState extends State<BgeCoverTile>
    with BgePointerFocus<BgeCoverTile> {
  final _focusNode = FocusNode(debugLabel: 'BgeCoverTile');

  @override
  void dispose() {
    _focusNode.dispose();
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
    BgeThumbnail thumbnail(double extent) => BgeThumbnail(
      url: widget.imageUrl,
      extent: extent,
      placeholderIcon: widget.placeholderIcon,
    );
    final radius = BorderRadius.circular(BgeTokens.of(context).radiusSm);

    // MergeSemantics so that the label and the ink's tap and focus are one
    // node: a container alone would leave the ink as a child node. Outside the
    // LayoutBuilder, which has no semantics of its own to be found by.
    return MergeSemantics(
      child: Semantics(
        label: widget.label,
        button: onTap != null,
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
                          ? thumbnail(side)
                          : BgeStackMarker(
                              count: stackCount,
                              // The marker adds its offsets to the picture.
                              child: thumbnail(
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
  }
}
