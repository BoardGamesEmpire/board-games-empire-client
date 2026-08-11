import 'package:flutter/material.dart';

import 'package:ui_tokens/src/bge_color_schemes.dart';

/// A complete, named set of the four [ColorScheme]s the app themes from (#32).
///
/// This is the **customization seam**. `BgeTheme` builds its themes from a
/// palette rather than from hardcoded constants, so shipping user-selectable
/// themes later means supplying a different [BgePalette] — not rewriting the
/// theme layer. Nothing user-facing consumes that yet; [storm] is the only
/// palette, and it is the default everywhere.
///
/// The seam exists now rather than later because the roadmap's rule is to
/// build what is hard to retrofit. Threading a palette through
/// `BgeTheme`/`BgeApp` after feature code has spread `BgeTheme.light()` calls
/// around is precisely the kind of change that gets deferred forever.
///
/// ## Authoring a new palette
///
/// All four schemes are required — a palette that omits the high-contrast
/// variants would silently drop the OS "increase contrast" support the app
/// guarantees. Any new palette must clear the same bar the default does:
///
/// - every authored on-role/role pair ≥ 4.5:1 in [light]/[dark] and ≥ 7.0:1
///   in [highContrastLight]/[highContrastDark];
/// - `tertiary` and `error` separated by at least
///   `Oklch.minAccentSeparation`;
/// - `onSurface`/`onSurfaceVariant` legible against every member of the
///   surface family, not just against `surface`.
///
/// `tool/derive_palette.dart` generates a palette meeting all three, and
/// `bge_color_schemes_test.dart` enforces them. Run both.
@immutable
class BgePalette {
  /// Creates a palette. Prefer [storm]; this is public for tests and for the
  /// future customization feature.
  const BgePalette({
    required this.name,
    required this.light,
    required this.dark,
    required this.highContrastLight,
    required this.highContrastDark,
  });

  /// The default palette: "storm over walnut".
  ///
  /// Dark warm-earth surfaces carry the wood; electric blue, storm violet and
  /// a rare ember accent carry the weather. **Dark is the reference** the
  /// identity was authored against and light is derived to match it — the
  /// reverse of how the placeholder palette this replaced was built.
  static const BgePalette storm = BgePalette(
    name: 'storm',
    light: BgeColorSchemes.light,
    dark: BgeColorSchemes.dark,
    highContrastLight: BgeColorSchemes.highContrastLight,
    highContrastDark: BgeColorSchemes.highContrastDark,
  );

  /// Stable identifier, used for persistence once themes become selectable.
  /// Not user-facing — a display name would need to be localized.
  final String name;

  /// Scheme for [Brightness.light] at standard contrast.
  final ColorScheme light;

  /// Scheme for [Brightness.dark] at standard contrast.
  final ColorScheme dark;

  /// Scheme selected by `MaterialApp.highContrastTheme` when the OS asks for
  /// increased contrast in a light context.
  final ColorScheme highContrastLight;

  /// Scheme selected by `MaterialApp.highContrastDarkTheme`.
  final ColorScheme highContrastDark;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BgePalette &&
          other.name == name &&
          other.light == light &&
          other.dark == dark &&
          other.highContrastLight == highContrastLight &&
          other.highContrastDark == highContrastDark;

  @override
  int get hashCode =>
      Object.hash(name, light, dark, highContrastLight, highContrastDark);
}
