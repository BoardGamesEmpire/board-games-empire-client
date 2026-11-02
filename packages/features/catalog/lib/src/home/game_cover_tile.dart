import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One game on a home page row (#615): its cover over its title, as one
/// semantics node.
///
/// The tile and its cover are [coverExtent] at normal text size and grow with
/// the text scale, so that a title that wraps onto more lines at 200% has the
/// width to do it in. The title has no line cap: the row is as tall as its
/// tallest tile, and a long title is shown whole.
///
/// ## Feedback over the cover
///
/// Hover, press and focus are drawn over the whole tile, cover included. An
/// ink effect paints on the `Material` it sits on, beneath everything drawn
/// above that, so one under the content would show only on the title: the cover
/// is opaque and hides it. The ink is a layer above the content instead.
///
/// A tile focused from the keyboard also gets a ring in the theme's
/// [BgeTokens.focusOutlineWidth] stroke, because the focus tint alone is faint
/// over a picture. The ring shows as an ink's focus does, for a keyboard and
/// not for a pointer, which is why this is stateful.
///
/// Without [onTap] a tile is inert content, not a focus stop, as the list's
/// rows are (#269).
class GameCoverTile extends StatefulWidget {
  const GameCoverTile({
    required this.title,
    this.thumbnailUrl,
    this.onTap,
    super.key,
  });

  /// The side of the cover, and the width of the tile, at normal text size.
  static const double coverExtent = 120;

  final String title;

  /// The cover's address. Null draws a placeholder.
  final String? thumbnailUrl;

  final VoidCallback? onTap;

  @override
  State<GameCoverTile> createState() => _GameCoverTileState();
}

class _GameCoverTileState extends State<GameCoverTile> {
  bool _hasFocus = false;

  /// Whether the ring shows: the tile has focus, and by keyboard.
  bool _showFocus = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_syncFocus);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_syncFocus);
    super.dispose();
  }

  void _onFocusChange(bool hasFocus) {
    _hasFocus = hasFocus;
    _syncFocus();
  }

  void _syncFocus([FocusHighlightMode? _]) {
    final show =
        _hasFocus &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (mounted && show != _showFocus) setState(() => _showFocus = show);
  }

  @override
  Widget build(BuildContext context) {
    final extent = MediaQuery.textScalerOf(context)
        .scale(GameCoverTile.coverExtent);
    final tokens = BgeTokens.of(context);
    final radius = BorderRadius.circular(tokens.radiusSm);

    // MergeSemantics so that the cover, which is decorative, the title and the
    // ink's tap are one node, as a list row's are.
    return MergeSemantics(
      child: Stack(
        children: [
          SizedBox(
            width: extent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BgeThumbnail(
                  url: widget.thumbnailUrl,
                  extent: extent,
                  placeholderIcon: Icons.casino_outlined,
                ),
                // Inset, so that the ring doesn't run through the title's
                // first letter or its last line.
                Padding(
                  padding: EdgeInsets.all(tokens.spaceXs),
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
          Positioned.fill(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: widget.onTap,
                onFocusChange: _onFocusChange,
                borderRadius: radius,
              ),
            ),
          ),
          if (_showFocus)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: tokens.focusOutlineWidth,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
