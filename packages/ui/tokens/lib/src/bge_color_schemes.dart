import 'package:flutter/material.dart';

/// The four authored [ColorScheme]s (#32).
///
/// Hand-authored rather than `ColorScheme.fromSeed`: seed generation does
/// not guarantee WCAG contrast, and the project target (2.1 AA) is
/// test-enforced — every authored on-role/role pair holds ≥ 4.5:1 in
/// [light]/[dark] and ≥ 7.0:1 in the high-contrast variants (see
/// `bge_color_schemes_test.dart`). Unset M3 roles derive from these; only
/// the authored pairs below carry the contrast guarantee, so widgets
/// should pair on-roles with their own role (`onPrimary` on `primary`,
/// never `onPrimary` on `surface`).
///
/// The high-contrast variants are selected automatically by
/// `MaterialApp.highContrastTheme` / `highContrastDarkTheme` when the OS
/// "increase contrast" accessibility setting is on
/// (`MediaQuery.highContrast`).
abstract final class BgeColorSchemes {
  /// Light scheme; authored pairs ≥ 4.5:1 (WCAG 2.1 AA, normal text).
  static const ColorScheme light = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF2E5AAC),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFD6E2FF),
    onPrimaryContainer: Color(0xFF001A41),
    secondary: Color(0xFF575E71),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFDBE2F9),
    onSecondaryContainer: Color(0xFF141B2C),
    tertiary: Color(0xFF715573),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFFBD7FB),
    onTertiaryContainer: Color(0xFF29132D),
    error: Color(0xFFBA1A1A),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFDAD6),
    onErrorContainer: Color(0xFF410002),
    surface: Color(0xFFFAF9FD),
    onSurface: Color(0xFF1A1C1E),
    onSurfaceVariant: Color(0xFF44474F),
    outline: Color(0xFF74777F),
    inverseSurface: Color(0xFF2F3033),
    onInverseSurface: Color(0xFFF1F0F4),
    inversePrimary: Color(0xFFABC7FF),
  );

  /// Dark scheme; authored pairs ≥ 4.5:1 (WCAG 2.1 AA, normal text).
  static const ColorScheme dark = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFABC7FF),
    onPrimary: Color(0xFF002E6A),
    primaryContainer: Color(0xFF123F80),
    onPrimaryContainer: Color(0xFFD6E2FF),
    secondary: Color(0xFFBFC6DC),
    onSecondary: Color(0xFF293041),
    secondaryContainer: Color(0xFF3F4759),
    onSecondaryContainer: Color(0xFFDBE2F9),
    tertiary: Color(0xFFDFBBDE),
    onTertiary: Color(0xFF402843),
    tertiaryContainer: Color(0xFF58405B),
    onTertiaryContainer: Color(0xFFFBD7FB),
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: Color(0xFF111318),
    onSurface: Color(0xFFE2E2E9),
    onSurfaceVariant: Color(0xFFC4C6D0),
    outline: Color(0xFF8E9099),
    inverseSurface: Color(0xFFE2E2E9),
    onInverseSurface: Color(0xFF2F3033),
    inversePrimary: Color(0xFF2E5AAC),
  );

  /// High-contrast light scheme; authored pairs ≥ 7.0:1.
  static const ColorScheme highContrastLight = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF17417E),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFF002E6A),
    onPrimaryContainer: Color(0xFFFFFFFF),
    secondary: Color(0xFF363D4E),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFF1A2233),
    onSecondaryContainer: Color(0xFFFFFFFF),
    tertiary: Color(0xFF4E3550),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFF331C36),
    onTertiaryContainer: Color(0xFFFFFFFF),
    error: Color(0xFF8C0009),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFF5C0004),
    onErrorContainer: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF000000),
    onSurfaceVariant: Color(0xFF21242B),
    outline: Color(0xFF40434B),
    inverseSurface: Color(0xFF2F3033),
    onInverseSurface: Color(0xFFFFFFFF),
    inversePrimary: Color(0xFFABC7FF),
  );

  /// High-contrast dark scheme; authored pairs ≥ 7.0:1.
  static const ColorScheme highContrastDark = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFD6E2FF),
    onPrimary: Color(0xFF002250),
    primaryContainer: Color(0xFFABC7FF),
    onPrimaryContainer: Color(0xFF002250),
    secondary: Color(0xFFDBE2F9),
    onSecondary: Color(0xFF10182A),
    secondaryContainer: Color(0xFFBFC6DC),
    onSecondaryContainer: Color(0xFF0B1220),
    tertiary: Color(0xFFFBD7FB),
    onTertiary: Color(0xFF24102A),
    tertiaryContainer: Color(0xFFDFBBDE),
    onTertiaryContainer: Color(0xFF24102A),
    error: Color(0xFFFFDAD6),
    onError: Color(0xFF400001),
    errorContainer: Color(0xFFFFB4AB),
    onErrorContainer: Color(0xFF400001),
    surface: Color(0xFF000000),
    onSurface: Color(0xFFFFFFFF),
    onSurfaceVariant: Color(0xFFC9CBD6),
    outline: Color(0xFFC9CBD6),
    inverseSurface: Color(0xFFE2E2E9),
    onInverseSurface: Color(0xFF000000),
    inversePrimary: Color(0xFF17417E),
  );
}
