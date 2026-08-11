import 'package:flutter/material.dart';

/// The four authored [ColorScheme]s of the "storm over walnut"
/// identity (#32) — the default `BgePalette`.
///
/// Hand-authored rather than `ColorScheme.fromSeed`: seed generation
/// does not guarantee WCAG contrast, and the project target (2.1 AA)
/// is test-enforced. Every authored on-role/role pair holds ≥ 4.5:1 in
/// [light]/[dark] and ≥ 7.0:1 in the high-contrast variants (see
/// `bge_color_schemes_test.dart`).
///
/// ## How these values were produced
///
/// Not picked by eye. Each role has a fixed OKLCH **hue** and **chroma**
/// — those carry the identity — and its **lightness** was solved
/// numerically for an exact contrast target. Consequences worth knowing
/// before editing any value here:
///
/// - Accents target only slightly above the 4.5:1 floor **on purpose**.
///   Pushing them lighter to "improve" contrast desaturates them, and
///   the electric blue stops reading as electric.
/// - `onSurface`/`onSurfaceVariant`/`outline` are solved against the
///   HARDEST member of the surface family (the lightest surface in a
///   dark scheme, the darkest in a light one) — not against
///   [ColorScheme.surface]. Text sits on the containers too, and
///   solving against the bare surface leaves the top containers failing
///   while the authored-pair test still reports green.
/// - [ColorScheme.surfaceDim]/[ColorScheme.surfaceBright] are ABSOLUTE
///   (dimmest/brightest in both brightnesses), not elevation steps.
/// - `tertiary` (ember) and `error` (crimson) are held ~54° apart in
///   OKLCH hue. That separation is load-bearing and is asserted by
///   `bge_color_schemes_test.dart`; it is the one pair in this palette
///   that can otherwise collapse into "some warm colour".
///
/// Only the authored pairs carry the contrast guarantee, so widgets
/// should pair on-roles with their own role (`onPrimary` on `primary`,
/// never `onPrimary` on `surface`).
abstract final class BgeColorSchemes {
  /// Light scheme; authored pairs ≥ 4.5:1 (WCAG 2.1 AA, normal text).
  static const ColorScheme light = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF0065B8),
    onPrimary: Color(0xFFF1F8FF),
    primaryContainer: Color(0xFFB8D9FF),
    onPrimaryContainer: Color(0xFF0F4274),
    secondary: Color(0xFF7B4EAF),
    onSecondary: Color(0xFFF9F5FF),
    secondaryContainer: Color(0xFFE1CEFF),
    onSecondaryContainer: Color(0xFF4E366B),
    tertiary: Color(0xFF905700),
    onTertiary: Color(0xFFFFF6EC),
    tertiaryContainer: Color(0xFFFFCD99),
    onTertiaryContainer: Color(0xFF603800),
    error: Color(0xFFBB2A4A),
    onError: Color(0xFFFFF4F4),
    errorContainer: Color(0xFFFFC9CC),
    onErrorContainer: Color(0xFF702934),
    surface: Color(0xFFFBF6F1),
    onSurface: Color(0xFF211913),
    onSurfaceVariant: Color(0xFF60554D),
    outline: Color(0xFF655B53),
    outlineVariant: Color(0xFFC8BEB6),
    surfaceDim: Color(0xFFDFD6CE),
    surfaceBright: Color(0xFFFFFFFF),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF7EEE6),
    surfaceContainer: Color(0xFFF1E8E0),
    surfaceContainerHigh: Color(0xFFE9E0D9),
    surfaceContainerHighest: Color(0xFFE1D9D1),
    inverseSurface: Color(0xFF342D28),
    onInverseSurface: Color(0xFFFEF5ED),
    inversePrimary: Color(0xFF258AEA),
    scrim: Color(0xFF010000),
    surfaceTint: Color(0xFF0065B8),
  );

  /// Dark scheme — the **reference** the identity was authored against;
  /// authored pairs ≥ 4.5:1 (WCAG 2.1 AA, normal text).
  static const ColorScheme dark = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF2B8FF0),
    onPrimary: Color(0xFF001331),
    primaryContainer: Color(0xFF07457C),
    onPrimaryContainer: Color(0xFFC0DEFF),
    secondary: Color(0xFFA477DB),
    onSecondary: Color(0xFF21023A),
    secondaryContainer: Color(0xFF523773),
    onSecondaryContainer: Color(0xFFE5D4FF),
    tertiary: Color(0xFFC67C0B),
    onTertiary: Color(0xFF240F00),
    tertiaryContainer: Color(0xFF633B00),
    onTertiaryContainer: Color(0xFFFFD3A4),
    error: Color(0xFFEB5A71),
    onError: Color(0xFF300008),
    errorContainer: Color(0xFF7B2534),
    onErrorContainer: Color(0xFFFFCFD2),
    surface: Color(0xFF18120D),
    onSurface: Color(0xFFFDF3EA),
    onSurfaceVariant: Color(0xFFAA9E94),
    outline: Color(0xFFA2978E),
    outlineVariant: Color(0xFF443C35),
    surfaceDim: Color(0xFF120C07),
    surfaceBright: Color(0xFF362F29),
    surfaceContainerLowest: Color(0xFF120C07),
    surfaceContainerLow: Color(0xFF1E1712),
    surfaceContainer: Color(0xFF221C16),
    surfaceContainerHigh: Color(0xFF27211B),
    surfaceContainerHighest: Color(0xFF2D2621),
    inverseSurface: Color(0xFFDCD3CB),
    onInverseSurface: Color(0xFF18120D),
    inversePrimary: Color(0xFF0068BD),
    scrim: Color(0xFF010000),
    surfaceTint: Color(0xFF2B8FF0),
  );

  /// High-contrast light scheme; authored pairs ≥ 7.0:1.
  static const ColorScheme highContrastLight = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF0058A1),
    onPrimary: Color(0xFFFEFFFF),
    primaryContainer: Color(0xFFBEDCFF),
    onPrimaryContainer: Color(0xFF013768),
    secondary: Color(0xFF7338AE),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFE4D2FF),
    onSecondaryContainer: Color(0xFF432B5F),
    tertiary: Color(0xFF7D4C00),
    onTertiary: Color(0xFFFFFFFE),
    tertiaryContainer: Color(0xFFFFD2A3),
    onTertiaryContainer: Color(0xFF512E00),
    error: Color(0xFFB0003B),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFCDD0),
    onErrorContainer: Color(0xFF631E2A),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF000000),
    onSurfaceVariant: Color(0xFF463C34),
    outline: Color(0xFF473E37),
    outlineVariant: Color(0xFFAFA59D),
    surfaceDim: Color(0xFFDFD6CE),
    surfaceBright: Color(0xFFFFFFFF),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF7EEE6),
    surfaceContainer: Color(0xFFF1E8E0),
    surfaceContainerHigh: Color(0xFFE9E0D9),
    surfaceContainerHighest: Color(0xFFE1D9D1),
    inverseSurface: Color(0xFF39322D),
    onInverseSurface: Color(0xFFFFFFFE),
    inversePrimary: Color(0xFF258AEA),
    scrim: Color(0xFF010000),
    surfaceTint: Color(0xFF0058A1),
  );

  /// High-contrast dark scheme; authored pairs ≥ 7.0:1.
  static const ColorScheme highContrastDark = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF339AFF),
    onPrimary: Color(0xFF000000),
    primaryContainer: Color(0xFF05447B),
    onPrimaryContainer: Color(0xFFE2EFFF),
    secondary: Color(0xFFB47DF8),
    onSecondary: Color(0xFF010006),
    secondaryContainer: Color(0xFF503671),
    onSecondaryContainer: Color(0xFFF2EAFF),
    tertiary: Color(0xFFD68500),
    onTertiary: Color(0xFF010000),
    tertiaryContainer: Color(0xFF623900),
    onTertiaryContainer: Color(0xFFFFEAD4),
    error: Color(0xFFFF6079),
    onError: Color(0xFF000000),
    errorContainer: Color(0xFF7A2332),
    onErrorContainer: Color(0xFFFFE8E9),
    surface: Color(0xFF000000),
    onSurface: Color(0xFFFFFFFF),
    onSurfaceVariant: Color(0xFFCDC0B6),
    outline: Color(0xFFC9BEB4),
    outlineVariant: Color(0xFF524A43),
    surfaceDim: Color(0xFF120C07),
    surfaceBright: Color(0xFF362F29),
    surfaceContainerLowest: Color(0xFF120C07),
    surfaceContainerLow: Color(0xFF1E1712),
    surfaceContainer: Color(0xFF221C16),
    surfaceContainerHigh: Color(0xFF27211B),
    surfaceContainerHighest: Color(0xFF2D2621),
    inverseSurface: Color(0xFFD0C7C0),
    onInverseSurface: Color(0xFF030100),
    inversePrimary: Color(0xFF0068BD),
    scrim: Color(0xFF010000),
    surfaceTint: Color(0xFF339AFF),
  );
}
