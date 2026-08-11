import 'package:flutter/material.dart';

/// The typography tokens (#32): the type scale, and the split between the
/// bundled display face and the platform's own text face.
///
/// ## The two-family split
///
/// **Display, headline and title roles** render in [displayFamily] — a
/// bundled variable serif. **Body and label roles** render in the platform
/// typeface (San Francisco, Roboto, Segoe), which `BgeTheme` leaves unset so
/// Flutter resolves it per platform.
///
/// The split is deliberate, and each half is chosen for a different reason:
///
/// - The display face carries the identity. A UI built entirely from the
///   system face reads as competent and anonymous, and looks subtly different
///   on each of the three targets.
/// - The system face carries the *reading*. It is hinted for the platform's
///   own rasterizer, ships glyphs for every locale the OS supports, and is
///   what users have already configured their accessibility settings around.
///   Swapping it for a bundled face would mean owning legibility and language
///   coverage for text the user actually has to read — a much larger promise
///   than "make the headings feel like something".
///
/// This **amends** the original #32 decision of "zero font assets", which was
/// reasoned from offline/privacy grounds. Those grounds are untouched: the
/// font is bundled in the binary, so there is no network fetch and no third
/// party — the cost is ~360KB of binary size, not privacy. The "never fetch a
/// font at runtime" half of that decision still holds absolutely.
///
/// ## Sizes, heights and tracking
///
/// All sizes are logical pixels at a 1.0 text scale; OS font scaling
/// multiplies them, clamped by `BgeTextScale` to 200% (WCAG 1.4.4).
///
/// Line heights are unitless multipliers, tighter as the type gets larger —
/// display text needs proportionally less leading than body copy, and Material
/// 3's defaults are tuned for a sans-serif and run loose under a serif.
///
/// Tracking (letter spacing) is in logical pixels and goes *negative* at
/// display sizes: large serif text set at default tracking reads as gappy.
abstract final class BgeTypography {
  /// The bundled display family. Declared in this package's `pubspec.yaml`.
  ///
  /// Referenced with [displayFamilyPackage] because the asset lives in
  /// `ui_tokens` rather than in the consuming app.
  static const String displayFamily = 'Fraunces';

  /// The package owning [displayFamily]'s asset — required by [TextStyle]
  /// when a font ships from a package rather than the app.
  static const String displayFamilyPackage = 'ui_tokens';

  /// The platform's monospace face, for content whose **alignment carries
  /// information**: stack traces, diagnostic dumps, IDs meant to be compared
  /// character by character.
  ///
  /// Not bundled, and deliberately not a third role in the scale. `'monospace'`
  /// is a generic family every platform resolves to its own default (Menlo,
  /// Roboto Mono, Consolas), which is the right trade here — a diagnostic
  /// surface needs fixed advance widths, not brand character.
  ///
  /// Use it as an override on a scale role, never as a whole style:
  ///
  /// ```dart
  /// Theme.of(context).textTheme.bodySmall?.copyWith(
  ///   fontFamily: BgeTypography.monospaceFamily,
  /// )
  /// ```
  ///
  /// That keeps size, height and color on the scale and changes only the one
  /// thing that has to change.
  static const String monospaceFamily = 'monospace';

  // ── Variable-font axes ─────────────────────────────────────────────
  // Fraunces is variable. Weight comes from the `wght` axis rather than
  // `TextStyle.fontWeight`: synthetic bolding of a variable font is
  // inconsistent across platforms, whereas an explicit axis value renders
  // identically everywhere. `fontWeight` is set alongside anyway so that
  // anything reading the style back (accessibility tooling, tests) still sees
  // a sensible weight.

  /// `wght` axis value for emphasized display text.
  static const double weightDisplay = 600;

  /// `wght` axis value for titles — lighter than display, still above body.
  static const double weightTitle = 500;

  /// `WONK` axis. Zero: Fraunces' "wonky" alternate letterforms are charming
  /// in isolation and distracting in a UI that repeats the same headings on
  /// every screen.
  ///
  /// Must be set explicitly — the font's own default for this axis is `1`
  /// (wonky ON), so leaving it unspecified opts *in* rather than out.
  static const double wonk = 0;

  /// Lower bound of Fraunces' `opsz` (optical size) axis.
  static const double opszMin = 9;

  /// Upper bound of Fraunces' `opsz` axis.
  static const double opszMax = 144;

  /// The `opsz` value for text rendered at [fontSize].
  ///
  /// **This must be set explicitly at every call site.** Fraunces' `opsz`
  /// default is [opszMin] — the *small text* optical size — so an unspecified
  /// axis renders a 57px display heading with letterforms drawn for 9pt body
  /// copy: sturdier strokes, looser spacing, and none of the refinement the
  /// face was chosen for. Unset axes fall back to the font's `fvar` defaults,
  /// not to anything Flutter infers from `fontSize`.
  ///
  /// Optical sizing is the reason a variable serif is worth bundling at all:
  /// the same family draws a 57px title and a 14px label as genuinely
  /// different shapes rather than one outline scaled up and down.
  static double opticalSizeFor(double fontSize) =>
      fontSize.clamp(opszMin, opszMax);

  /// `SOFT` axis. A little softness suits the warm side of the identity
  /// without rounding the serifs into mush.
  static const double softness = 20;

  // ── Size scale (logical px at 1.0 scale) ───────────────────────────

  /// `displayLarge` role size.
  static const double displayLarge = 57;

  /// `displayMedium` role size.
  static const double displayMedium = 45;

  /// `displaySmall` role size.
  static const double displaySmall = 36;

  /// `headlineLarge` role size.
  static const double headlineLarge = 32;

  /// `headlineMedium` role size.
  static const double headlineMedium = 28;

  /// `headlineSmall` role size.
  static const double headlineSmall = 24;

  /// `titleLarge` role size.
  static const double titleLarge = 22;

  /// `titleMedium` role size.
  static const double titleMedium = 16;

  /// `titleSmall` role size.
  static const double titleSmall = 14;

  /// `bodyLarge` role size.
  static const double bodyLarge = 16;

  /// `bodyMedium` role size.
  static const double bodyMedium = 14;

  /// `bodySmall` role size.
  static const double bodySmall = 12;

  /// `labelLarge` role size.
  static const double labelLarge = 14;

  /// `labelMedium` role size.
  static const double labelMedium = 12;

  /// `labelSmall` role size.
  static const double labelSmall = 11;

  // ── Line height (unitless multiplier of font size) ─────────────────

  /// Leading for display roles — tightest; the type is already huge.
  static const double heightDisplay = 1.12;

  /// Leading for headline roles.
  static const double heightHeadline = 1.20;

  /// Leading for title roles.
  static const double heightTitle = 1.28;

  /// Leading for body roles — loosest, because this is the text people
  /// actually read in multi-line runs.
  static const double heightBody = 1.50;

  /// Leading for label roles; labels are short and usually single-line.
  static const double heightLabel = 1.35;

  // ── Tracking (logical px) ──────────────────────────────────────────

  /// Tracking for display roles. Negative: large serif text set at default
  /// tracking reads as gappy.
  static const double trackingDisplay = -0.5;

  /// Tracking for headline roles.
  static const double trackingHeadline = -0.25;

  /// Tracking for title roles.
  static const double trackingTitle = 0;

  /// Tracking for body roles.
  static const double trackingBody = 0.15;

  /// Tracking for label roles — positive; small text benefits from air.
  static const double trackingLabel = 0.4;

  /// The [TextTheme] the app themes with.
  ///
  /// Body and label roles deliberately carry **no** `fontFamily`, so Flutter
  /// resolves the platform typeface for them. Only the display/headline/title
  /// roles name [displayFamily].
  static TextTheme textTheme() {
    TextStyle display(double size, double height, double tracking) => TextStyle(
      fontFamily: displayFamily,
      package: displayFamilyPackage,
      fontSize: size,
      height: height,
      letterSpacing: tracking,
      fontWeight: FontWeight.w600,
      fontVariations: [
        const FontVariation('wght', weightDisplay),
        FontVariation('opsz', opticalSizeFor(size)),
        const FontVariation('SOFT', softness),
        const FontVariation('WONK', wonk),
      ],
    );

    // Titles use the same face a notch lighter, so a card title does not
    // shout at the same volume as a page heading.
    TextStyle title(double size, double height, double tracking) => TextStyle(
      fontFamily: displayFamily,
      package: displayFamilyPackage,
      fontSize: size,
      height: height,
      letterSpacing: tracking,
      fontWeight: FontWeight.w500,
      fontVariations: [
        const FontVariation('wght', weightTitle),
        FontVariation('opsz', opticalSizeFor(size)),
        const FontVariation('SOFT', softness),
        const FontVariation('WONK', wonk),
      ],
    );

    // No fontFamily: the platform typeface.
    TextStyle system(double size, double height, double tracking) => TextStyle(
      fontSize: size,
      height: height,
      letterSpacing: tracking,
    );

    return TextTheme(
      displayLarge: display(displayLarge, heightDisplay, trackingDisplay),
      displayMedium: display(displayMedium, heightDisplay, trackingDisplay),
      displaySmall: display(displaySmall, heightDisplay, trackingDisplay),
      headlineLarge: display(headlineLarge, heightHeadline, trackingHeadline),
      headlineMedium: display(headlineMedium, heightHeadline, trackingHeadline),
      headlineSmall: display(headlineSmall, heightHeadline, trackingHeadline),
      titleLarge: title(titleLarge, heightTitle, trackingTitle),
      titleMedium: title(titleMedium, heightTitle, trackingTitle),
      titleSmall: title(titleSmall, heightTitle, trackingTitle),
      bodyLarge: system(bodyLarge, heightBody, trackingBody),
      bodyMedium: system(bodyMedium, heightBody, trackingBody),
      bodySmall: system(bodySmall, heightBody, trackingBody),
      labelLarge: system(labelLarge, heightLabel, trackingLabel),
      labelMedium: system(labelMedium, heightLabel, trackingLabel),
      labelSmall: system(labelSmall, heightLabel, trackingLabel),
    );
  }
}
