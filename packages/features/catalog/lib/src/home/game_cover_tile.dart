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
/// A tile focused from the keyboard also gets a [BgeFocusRing], because the
/// focus tint alone is faint over a picture.
///
/// Without [onTap] a tile is inert content, not a focus stop, as the list's
/// rows are (#269).
class GameCoverTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final extent = MediaQuery.textScalerOf(context).scale(coverExtent);
    final tokens = BgeTokens.of(context);
    final radius = BorderRadius.circular(tokens.radiusSm);

    // MergeSemantics so that the cover, which is decorative, the title and the
    // ink's tap are one node, as a list row's are.
    return MergeSemantics(
      child: BgeFocusRing(
        borderRadius: radius,
        builder: (context, onFocusChange) => Stack(
          children: [
            SizedBox(
              width: extent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  BgeThumbnail(
                    url: thumbnailUrl,
                    extent: extent,
                    placeholderIcon: Icons.casino_outlined,
                  ),
                  // Inset, so that the ring doesn't run through the title's
                  // first letter or its last line.
                  Padding(
                    padding: EdgeInsets.all(tokens.spaceXs),
                    child: Text(
                      title,
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
                  onTap: onTap,
                  onFocusChange: onFocusChange,
                  borderRadius: radius,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
