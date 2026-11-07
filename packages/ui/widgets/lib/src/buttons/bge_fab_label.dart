import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The label of a [FloatingActionButton.extended] that has an icon, shrunk
/// to fit the window rather than pushing the button off it (#50).
///
/// An extended button lays out its icon and label with no width limit. With a
/// large text size on a narrow window, a long label makes the button wider
/// than the space between Scaffold's margins. Scaffold keeps the button's end
/// edge in place, so its start edge runs past the window's. In SF Pro, the
/// iOS and macOS font, "Add data gateway" at 320dp × 2.0 started 12dp off
/// screen.
///
/// So this label is held to the width the window leaves it: the window's
/// width, less the button's margins, its padding, its icon and the gap after
/// the icon. A label wider than that is scaled down just enough to fit, and
/// every other label keeps its size. The label is one line, because an
/// extended button has a fixed height and can't wrap it.
///
/// The width is the window's, not the page's, and the safe area's side
/// insets aren't taken off: Scaffold strips them before the button sees
/// them. Neither matters where a label comes near the limit. A narrow
/// window is a portrait phone, as wide as its page and with no side insets,
/// and the landscape phones and wide windows that differ leave any label
/// room to spare.
class BgeFabLabel extends StatelessWidget {
  /// A label reading [text].
  const BgeFabLabel(this.text, {super.key});

  /// What the button says.
  final String text;

  // Material 3's extended button, used where the theme sets nothing.
  static const double _iconSize = 24;
  static const double _iconLabelSpacing = 8;
  static const double _paddingStart = 16;
  static const double _paddingEnd = 20;

  @override
  Widget build(BuildContext context) {
    final fab = FloatingActionButtonTheme.of(context);
    final taken =
        2 * kFloatingActionButtonMargin +
        (fab.extendedPadding?.horizontal ?? _paddingStart + _paddingEnd) +
        (fab.iconSize ?? _iconSize) +
        (fab.extendedIconLabelSpacing ?? _iconLabelSpacing);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: math.max(0, MediaQuery.sizeOf(context).width - taken),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: Text(text),
      ),
    );
  }
}
