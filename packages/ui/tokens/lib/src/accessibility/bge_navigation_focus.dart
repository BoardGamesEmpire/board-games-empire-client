import 'package:flutter/material.dart';

import 'package:ui_tokens/src/accessibility/bge_focus_fill.dart';

/// The fill a focused navigation bar or rail destination shows (#644, #414).
///
/// A destination shows keyboard focus as a fill alone, and Flutter's own
/// focus tint stands about 1.3:1 from the bar behind it in all four themes,
/// short of the 3:1 a focus cue needs. The fill here is [BgeFocusFill]'s
/// weakest that stands [ratio] clear of the bar's surface and carries an
/// unselected icon at 3:1: `onSurface` laid over the surface, then
/// `primary`.
///
/// The bar takes it from `BgeTheme`'s `navigationBarTheme`. A rail has no
/// overlay of its own and reads the nearest `ThemeData.focusColor`, which
/// would reach every ink well in the app if the theme set it; so the shell
/// sets it around the rail alone, to [railFill].
///
/// The fill takes an unselected icon below 3:1 (`onSurfaceVariant` on it
/// measures 1.6 to 3.2), so the theme also gives a bar's or rail's unselected
/// icon [iconColor], which stands 3.9:1 or more from it.
///
/// A selected destination isn't solved for. The fill paints over its
/// indicator, and no colour stands 3:1 from the indicator while carrying
/// both icons at 3:1, in any of the four themes (#909).
abstract final class BgeNavigationFocus {
  /// How far the fill stands from the surface behind it.
  static const double ratio = BgeFocusFill.ratio;

  /// The fill over a navigation bar, which sits on `surfaceContainer`.
  static Color barFill(ColorScheme scheme) => barFocus(scheme).color;

  /// The fill over a navigation rail, which sits on `surface`.
  static Color railFill(ColorScheme scheme) => railFocus(scheme).color;

  /// [barFill], with whether it meets its floors.
  static BgeFocusFill barFocus(ColorScheme scheme) =>
      _solve(scheme, scheme.surfaceContainer);

  /// [railFill], with whether it meets its floors.
  static BgeFocusFill railFocus(ColorScheme scheme) =>
      _solve(scheme, scheme.surface);

  /// The colour of an unselected destination's icon, which has to stand 3:1
  /// from the fill while the destination is focused.
  static Color iconColor(ColorScheme scheme) => scheme.onSurface;

  /// The fill over [background]. Where none meets its floors, the closest,
  /// so the icon is never left on a fill of its own colour (#909).
  static BgeFocusFill _solve(ColorScheme scheme, Color background) =>
      BgeFocusFill.solve(
        background: background,
        inks: [scheme.onSurface, scheme.primary],
        carries: {iconColor(scheme): 3},
      );
}
