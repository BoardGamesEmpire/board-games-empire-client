import 'package:flutter/material.dart';
import 'package:ui/src/buttons/bge_fab_label.dart';
import 'package:ui/src/focus/bge_focus_ring.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// An extended floating action button with an icon and a label, ringed inside
/// its own edge while it has focus from the keyboard (#760).
///
/// A [FloatingActionButton] is no `ButtonStyleButton`, so the theme's button
/// ring doesn't reach it, and its focus overlay on its fill stands about
/// 1.17:1 from the rest. This wraps it in a [BgeFocusRing], which hides after
/// a mouse press as every ring does.
///
/// The ring is inside the edge because a floating button sits over whatever
/// the page scrolls under it, which can be any colour. An outside ring has no
/// fixed colour to stand 3:1 against, and the fill is the one thing the ring
/// can count on.
///
/// The label is a [BgeFabLabel], so it stays on screen at a large text size.
class BgeExtendedFab extends StatelessWidget {
  /// A button showing [icon] and [label], doing [onPressed] when pressed, or
  /// nothing and taking no focus while that is null.
  const BgeExtendedFab({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.focusNode,
    super.key,
  });

  /// The ring's colour on [scheme]'s floating button: `primary` where it
  /// stands 3:1 from the fill, which is `primaryContainer`, and otherwise
  /// `onPrimaryContainer`, the fill's foreground, as a banner's buttons take
  /// theirs.
  static Color ringColorOf(ColorScheme scheme) =>
      Wcag.contrastRatio(scheme.primary, scheme.primaryContainer) >= 3
      ? scheme.primary
      : scheme.onPrimaryContainer;

  /// The button's icon.
  final Widget icon;

  /// What the button says.
  final String label;

  /// What a press does, or null to disable the button, which then takes no
  /// focus.
  final VoidCallback? onPressed;

  /// The button's focus node, for a screen that moves focus to it or from it.
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(BgeTokens.of(context).radiusLg);
    return BgeFocusRing(
      borderRadius: radius,
      color: ringColorOf(Theme.of(context).colorScheme),
      builder: (context, onFocusChange) => Focus(
        // The ring only listens: it is no stop of its own, and the button
        // inside it stays the one. Nor is it a node for a screen reader: left
        // to add one, it wraps the button's in an empty node of its own.
        canRequestFocus: false,
        includeSemantics: false,
        skipTraversal: true,
        onFocusChange: onFocusChange,
        child: FloatingActionButton.extended(
          shape: RoundedRectangleBorder(borderRadius: radius),
          focusNode: focusNode,
          onPressed: onPressed,
          icon: icon,
          label: BgeFabLabel(label),
        ),
      ),
    );
  }
}
