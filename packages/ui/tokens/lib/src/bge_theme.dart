import 'package:flutter/material.dart';

import 'bge_color_schemes.dart';
import 'bge_tokens.dart';

/// The four application themes (#32), built on [BgeColorSchemes] with the
/// theme-level accessibility baseline applied uniformly.
///
/// Baseline decisions (all test-enforced in `bge_theme_test.dart`):
///
/// - **Tap targets ≥ 48dp** — `MaterialTapTargetSize.padded` on every
///   platform. Deliberately *not* `.shrinkWrap`-on-desktop: pointer
///   precision does not remove the motor-accessibility need.
/// - **`VisualDensity.standard`** — deliberately *not*
///   `adaptivePlatformDensity`, which compacts desktop layouts and erodes
///   the tap-target baseline there.
/// - **Visible focus** — text inputs get an explicit
///   `focusOutlineWidth`-stroke primary border; Material 3 supplies the
///   focus overlay for buttons and list items. (The full keyboard-focus
///   pass across real screens is #50/#70.)
/// - **System typeface** — no `fontFamily`/`textTheme` override; the M3
///   defaults supply the `BgeTypography` scale (see that class).
/// - **Dimensional tokens** — [BgeTokens.standard] installed as a
///   `ThemeExtension` on every theme.
///
/// The high-contrast factories are wired by the shell to
/// `MaterialApp.highContrastTheme` / `highContrastDarkTheme`, so the OS
/// "increase contrast" setting selects them automatically.
abstract final class BgeTheme {
  // Built once and cached: the schemes are const and ThemeData is
  // immutable, so the four defaults are shared, stable-identity
  // instances. The shell resolves these on every BgeApp rebuild
  // (`widget.theme ?? BgeTheme.light()`); a fresh ThemeData per build
  // would hand MaterialApp a new theme identity each time and spuriously
  // repropagate Theme to the whole subtree.
  static ThemeData light() => _light;

  static ThemeData dark() => _dark;

  static ThemeData highContrastLight() => _highContrastLight;

  static ThemeData highContrastDark() => _highContrastDark;

  static final ThemeData _light = _build(BgeColorSchemes.light);
  static final ThemeData _dark = _build(BgeColorSchemes.dark);
  static final ThemeData _highContrastLight = _build(
    BgeColorSchemes.highContrastLight,
  );
  static final ThemeData _highContrastDark = _build(
    BgeColorSchemes.highContrastDark,
  );

  static ThemeData _build(ColorScheme scheme) {
    const tokens = BgeTokens.standard;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      inputDecorationTheme: InputDecorationThemeData(
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSm),
          borderSide: BorderSide(
            color: scheme.primary,
            width: tokens.focusOutlineWidth,
          ),
        ),
      ),
      extensions: const [tokens],
    );
  }
}
