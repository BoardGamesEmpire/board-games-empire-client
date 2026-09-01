import 'package:flutter/material.dart';

import 'package:ui_tokens/src/accessibility/bge_selection.dart';
import 'package:ui_tokens/src/bge_palette.dart';
import 'package:ui_tokens/src/bge_status_colors.dart';
import 'package:ui_tokens/src/bge_tokens.dart';
import 'package:ui_tokens/src/bge_typography.dart';

/// The four application themes (#32), built from a [BgePalette] with the
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
/// - **Two-family typography** — the bundled display face on
///   display/headline/title, the platform face on body/label. See
///   [BgeTypography] for why the split falls there.
/// - **Legible text selection** — an authored `textSelectionTheme`. Material's
///   default tint drops selected text below the floor in all four schemes:
///   under 3:1 in light and dark, and under the 4.5:1 the high-contrast pair
///   is held to. See [BgeSelection] for both floors and what they exclude.
/// - **Dimensional tokens** — [BgeTokens.standard] and [BgeStatusColors] are
///   installed as `ThemeExtension`s on every theme.
///
/// The high-contrast factories are wired by the shell to
/// `MaterialApp.highContrastTheme` / `highContrastDarkTheme`, so the OS
/// "increase contrast" setting selects them automatically.
abstract final class BgeTheme {
  /// The default light theme.
  static ThemeData light() => storm.light;

  /// The default dark theme.
  static ThemeData dark() => storm.dark;

  /// The high-contrast light theme, wired to `MaterialApp.highContrastTheme`.
  static ThemeData highContrastLight() => storm.highContrastLight;

  /// The high-contrast dark theme, wired to
  /// `MaterialApp.highContrastDarkTheme`.
  static ThemeData highContrastDark() => storm.highContrastDark;

  /// The themes for the default palette.
  ///
  /// Built once and cached: the schemes are const and `ThemeData` is
  /// immutable, so the four defaults are shared, stable-identity instances.
  /// The shell resolves these on every `BgeApp` rebuild
  /// (`widget.theme ?? BgeTheme.light()`); a fresh `ThemeData` per build would
  /// hand `MaterialApp` a new theme identity each time and spuriously
  /// repropagate `Theme` to the whole subtree.
  static final BgeThemeSet storm = from(BgePalette.storm);

  /// Builds the four themes for [palette].
  ///
  /// **Not cached.** Callers that rebuild frequently must hold the result
  /// rather than calling this in a `build` method — see [storm] for why theme
  /// identity stability matters. The default palette is already cached there;
  /// this entry point exists for the future customization feature, whose
  /// palette will arrive from persisted state that already has a natural home
  /// to hold the built themes.
  static BgeThemeSet from(BgePalette palette) => BgeThemeSet._(
    light: _build(palette.light),
    dark: _build(palette.dark),
    highContrastLight: _build(palette.highContrastLight),
    highContrastDark: _build(palette.highContrastDark),
  );

  static ThemeData _build(ColorScheme scheme) {
    const tokens = BgeTokens.standard;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: BgeTypography.textTheme(),
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      inputDecorationTheme: InputDecorationThemeData(
        // Outlined by default, theme-wide. Previously each feature decided
        // this for itself, so household's fields were outlined and
        // server-onboarding's were not — the same control looking like two
        // different controls depending on which screen you reached it from.
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSm),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSm),
          borderSide: BorderSide(
            color: scheme.primary,
            width: tokens.focusOutlineWidth,
          ),
        ),
      ),
      // #322: authored rather than inherited. Left unset, Material
      // substitutes `primary` at 40% opacity, which drops selected text
      // below the legibility floor in all four schemes — narrowly in light
      // and dark, and clearly in the high-contrast pair, which is held to
      // the AAA large-text bar. See [BgeSelection].
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: BgeSelection.colorFor(scheme),
      ),
      extensions: [tokens, BgeStatusColors.forScheme(scheme)],
    );
  }
}

/// The four [ThemeData]s built from one [BgePalette].
@immutable
class BgeThemeSet {
  const BgeThemeSet._({
    required this.light,
    required this.dark,
    required this.highContrastLight,
    required this.highContrastDark,
  });

  /// Standard-contrast light theme.
  final ThemeData light;

  /// Standard-contrast dark theme.
  final ThemeData dark;

  /// High-contrast light theme.
  final ThemeData highContrastLight;

  /// High-contrast dark theme.
  final ThemeData highContrastDark;
}
