import 'package:flutter/material.dart';

import 'package:ui_tokens/src/accessibility/wcag_contrast.dart';

/// The fill a focused navigation bar or rail destination shows (#644, #414).
///
/// A destination shows keyboard focus as a fill alone, and Flutter's own
/// focus tint stands about 1.3:1 from the bar behind it in all four themes,
/// short of the 3:1 a focus cue needs. The fill here is `onSurface` laid over
/// the bar's surface at the least strength that stands 3.2:1 clear of it,
/// the margin covering a blend that lands between two steps.
///
/// The bar takes it from `BgeTheme`'s `navigationBarTheme`. A rail has no
/// overlay of its own and reads the nearest `ThemeData.focusColor`, which
/// would reach every ink well in the app if the theme set it; so the shell
/// sets it around the rail alone, to [railFill].
///
/// The fill takes an unselected icon below 3:1 (`onSurfaceVariant` on it
/// measures 1.6 to 3.2), so the theme also gives a bar's or rail's unselected
/// icon [iconColor], which stands 3.9:1 or more from it.
abstract final class BgeNavigationFocus {
  /// How far the fill stands from the surface behind it.
  static const double ratio = 3.2;

  /// The fill over a navigation bar, which sits on `surfaceContainer`.
  static Color barFill(ColorScheme scheme) =>
      _fill(scheme, scheme.surfaceContainer);

  /// The fill over a navigation rail, which sits on `surface`.
  static Color railFill(ColorScheme scheme) => _fill(scheme, scheme.surface);

  /// The colour of an unselected destination's icon, which has to stand 3:1
  /// from the fill while the destination is focused.
  static Color iconColor(ColorScheme scheme) => scheme.onSurface;

  /// How many steps the fill's strength climbs in, the last one full.
  static const _steps = 20;

  /// `onSurface` over [background] at the first step that stands [ratio]
  /// clear of it, or at full strength, the most there is, where none does.
  static Color _fill(ColorScheme scheme, Color background) {
    var fill = background;
    // Counted in whole steps: a sum of 0.05s overshoots 1 on the last.
    for (var step = 1; step <= _steps; step++) {
      fill = Color.alphaBlend(
        scheme.onSurface.withValues(alpha: step / _steps),
        background,
      );
      if (Wcag.contrastRatio(fill, background) >= ratio) break;
    }
    return fill;
  }
}
