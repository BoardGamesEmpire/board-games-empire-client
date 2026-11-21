import 'package:flutter/material.dart';

import 'package:ui_tokens/src/accessibility/bge_focus_lease.dart';
import 'package:ui_tokens/src/accessibility/bge_pointer_pressed.dart';
import 'package:ui_tokens/src/accessibility/wcag_contrast.dart';

/// The keyboard focus ring `BgeTheme` gives every chip, through
/// `ChipThemeData.side` (#761).
///
/// A chip marks focus with Material's faint tint alone, about 1.3:1 from
/// rest. It updates `WidgetState.focused` as it gains and loses focus, and
/// resolves its side with it, so the theme's side draws a
/// `focusOutlineWidth` ring with no wrapper round the chip.
///
/// The ring follows STYLE_GUIDE §5, as every ring does: it shows while the
/// chip has focus, the highlight mode is the keyboard's, and no mouse or
/// trackpad press came after the last key press ([BgePointerPressed]).
///
/// A side has no lifecycle, so it can neither keep the pointer flag
/// watching nor rebuild its chip when the flag or the highlight mode
/// changes. The app's root holds that for the app's lifetime
/// ([BgeFocusLease]): the flag then records a press even on a page with no
/// ring built, and the focused chip rebuilds to show or hide its ring.
abstract final class BgeChipFocus {
  /// The ring's colour on a chip in [theme], [selected] or not.
  ///
  /// `primary`, which stands 3:1 on an unselected chip's own `surface`
  /// fill, whatever the chip sits on, under its focus tint. A selected chip
  /// has its own `secondaryContainer` fill, and there `primary` stands 3:1 in
  /// some palettes only, so a selected chip takes `primary` where it does
  /// and `onSecondaryContainer`, the selected label's colour, where it
  /// doesn't.
  ///
  /// It is measured on [selectedFill], the fill as painted under the
  /// darkest tints a ringed chip shows: a mouse can rest on a chip the
  /// keyboard focused.
  static Color ringColor(ThemeData theme, {required bool selected}) {
    final scheme = theme.colorScheme;
    if (!selected) return scheme.primary;
    return Wcag.contrastRatio(scheme.primary, selectedFill(theme)) >=
            Wcag.aaNonText
        ? scheme.primary
        : scheme.onSecondaryContainer;
  }

  /// A selected chip's `secondaryContainer` under its focus tint
  /// ([ThemeData.focusColor]) and, over that, its hover tint
  /// ([ThemeData.hoverColor]), as the chip's ink well paints them under
  /// the ring.
  static Color selectedFill(ThemeData theme) => Color.alphaBlend(
    theme.hoverColor,
    Color.alphaBlend(theme.focusColor, theme.colorScheme.secondaryContainer),
  );

  /// Whether a chip in [states] shows its ring.
  ///
  /// `WidgetState.focused` holds whenever the chip has focus, by any means,
  /// so the highlight mode and the pointer flag are asked here.
  static bool showsRing(Set<WidgetState> states) =>
      states.contains(WidgetState.focused) &&
      !states.contains(WidgetState.disabled) &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional &&
      !BgePointerPressed.value;
}
