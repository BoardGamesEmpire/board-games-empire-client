import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A game's cover beside its [titles], or above them where the titles would
/// have too little room beside it.
///
/// The quick look (#707) and the detail page (#735) head a game the same
/// way, so both share this rather than keeping two copies of the rule.
///
/// Where the [titles] go is decided from the room the parent gives, and
/// from the text size: see [minTitleWidthEms].
///
/// The caller keeps the title a semantic header inside [titles]. The cover
/// comes first in the children either way, so reading order stays cover,
/// then titles.
///
/// Its `LayoutBuilder` throws under intrinsic sizing, so host it where the
/// width is bounded, as a page's or a pop-up's content is.
class CoverBesideTitle extends StatelessWidget {
  const CoverBesideTitle({
    required this.cover,
    required this.coverExtent,
    required this.titles,
    required this.titleFontSize,
    super.key,
  });

  /// The narrowest the title may be beside the cover, in ems of its own
  /// scaled size. Narrower, the cover goes above the title instead.
  ///
  /// Rendered for #707 at 320dp and 2.0 text, the title beside the cover had
  /// 176dp, and "Wingspan" broke in the middle of the word. Eight ems is
  /// about a dozen letters of the title's face, so a long word in a title
  /// fits. In ems, as `BgeInlineBanner.minMessageWidthEms` is, so it follows
  /// the text size: at 1.0 the title stays beside the cover from 320dp up
  /// at the quick look's size, and at 2.0 it goes under it on a phone.
  /// The detail page's larger cover and title put its title under the cover
  /// on a phone at 1.0 too (#735).
  static const double minTitleWidthEms = 8;

  /// The cover, drawn [coverExtent] square.
  final Widget cover;

  /// The cover's width, which the room beside it is measured from.
  final double coverExtent;

  /// The title, and what goes under it.
  final Widget titles;

  /// The title's size before text scaling, which [minTitleWidthEms] counts
  /// in.
  final double titleFontSize;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = BgeTokens.of(context).spaceMd;
        final minTitleWidth =
            minTitleWidthEms *
            MediaQuery.textScalerOf(context).scale(titleFontSize);
        final direction =
            constraints.maxWidth - coverExtent - gap >= minTitleWidth
            ? Axis.horizontal
            : Axis.vertical;
        // One Flex either way, so the cover keeps its element, and its
        // image, when the text size or the width moves it.
        return Flex(
          direction: direction,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cover,
            BgeGap.md(axis: direction),
            if (direction == Axis.horizontal)
              Expanded(child: titles)
            else
              titles,
          ],
        );
      },
    );
  }
}
