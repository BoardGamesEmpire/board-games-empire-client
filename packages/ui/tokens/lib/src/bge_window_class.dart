import 'package:flutter/widgets.dart';
import 'package:ui_tokens/src/bge_tokens.dart';

/// Which form a layout takes at the window's width, resolved against a
/// [BgeTokens] instance.
///
/// A *threshold*, not a measure: it says "change form here", never "grow to
/// this wide". Page widths are `BgePageWidth`'s job, which is why
/// [BgeTokens.paneMaxWidth] and [BgeTokens.breakpointExpanded] stay two
/// tokens though both are 840 today (#414).
///
/// Lives here for the reason `BgePageWidth` does: the mapping from a name to a
/// token belongs next to the tokens it maps (#212). Read the class through
/// [of], which reads the window ([MediaQuery.sizeOf]), never a
/// `LayoutBuilder`'s constraints: the window decides the form, and a pane or a
/// padded column inside it would flip a layout at the wrong width.
enum BgeWindowClass {
  /// Below [BgeTokens.breakpointMedium]: a phone, or a narrow window.
  compact,

  /// From [BgeTokens.breakpointMedium] up to [BgeTokens.breakpointExpanded].
  medium,

  /// From [BgeTokens.breakpointExpanded] up.
  expanded;

  /// The narrowest window width, in [tokens], that is this class.
  double minWidth(BgeTokens tokens) => switch (this) {
    BgeWindowClass.compact => 0,
    BgeWindowClass.medium => tokens.breakpointMedium,
    BgeWindowClass.expanded => tokens.breakpointExpanded,
  };

  /// The class a window [width] falls in, against [tokens]. Each threshold
  /// belongs to the wider class.
  static BgeWindowClass fromWidth(double width, BgeTokens tokens) {
    if (width >= tokens.breakpointExpanded) {
      return BgeWindowClass.expanded;
    }
    if (width >= tokens.breakpointMedium) {
      return BgeWindowClass.medium;
    }
    return BgeWindowClass.compact;
  }

  /// The class of the window [context] is in, against the nearest
  /// [BgeTokens]. Rebuilds when the window's width changes.
  static BgeWindowClass of(BuildContext context) =>
      fromWidth(MediaQuery.sizeOf(context).width, BgeTokens.of(context));
}
