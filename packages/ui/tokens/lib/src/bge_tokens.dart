import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show lerpDuration;
import 'package:flutter/material.dart';

/// Dimensional design tokens (#32): spacing, radii, motion durations, and
/// the accessibility dimensions `ThemeData` has no native slot for.
///
/// Consumed via `Theme.of(context).extension<BgeTokens>()!` — installed by
/// every `BgeTheme` factory, so the non-null assertion is safe under any
/// shell-provided theme. This is the extension seam the future SDUI layer
/// (#19) references instead of literal values.
///
/// Dimensional tokens are theme-invariant (identical across light, dark,
/// and high-contrast), so a single [standard] instance backs all four
/// themes.
@immutable
class BgeTokens extends ThemeExtension<BgeTokens> {
  const BgeTokens({
    required this.spaceXs,
    required this.spaceSm,
    required this.spaceMd,
    required this.spaceLg,
    required this.spaceXl,
    required this.spaceXxl,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.minTapTarget,
    required this.focusOutlineWidth,
    required this.motionShort,
    required this.motionMedium,
    required this.motionLong,
  });

  /// The app-wide token values.
  static const BgeTokens standard = BgeTokens(
    spaceXs: 4,
    spaceSm: 8,
    spaceMd: 16,
    spaceLg: 24,
    spaceXl: 32,
    spaceXxl: 48,
    radiusSm: 4,
    radiusMd: 12,
    radiusLg: 16,
    minTapTarget: 48,
    focusOutlineWidth: 2,
    motionShort: Duration(milliseconds: 150),
    motionMedium: Duration(milliseconds: 300),
    motionLong: Duration(milliseconds: 500),
  );

  // ── Spacing scale (logical px) ─────────────────────────────────────
  final double spaceXs;
  final double spaceSm;
  final double spaceMd;
  final double spaceLg;
  final double spaceXl;
  final double spaceXxl;

  // ── Corner radii ───────────────────────────────────────────────────
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;

  // ── Accessibility dimensions ───────────────────────────────────────

  /// Minimum interactive tap-target edge (WCAG 2.5.5 / Material: 48dp).
  /// Enforced theme-wide via `MaterialTapTargetSize.padded`; exposed here
  /// for custom hit regions.
  final double minTapTarget;

  /// Visible-focus indicator stroke width (WCAG 2.4.7).
  final double focusOutlineWidth;

  // ── Motion durations ───────────────────────────────────────────────
  // Resolve through `BgeMotion.durationOf` so OS reduced-motion collapses
  // them to zero.
  final Duration motionShort;
  final Duration motionMedium;
  final Duration motionLong;

  @override
  BgeTokens copyWith({
    double? spaceXs,
    double? spaceSm,
    double? spaceMd,
    double? spaceLg,
    double? spaceXl,
    double? spaceXxl,
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
    double? minTapTarget,
    double? focusOutlineWidth,
    Duration? motionShort,
    Duration? motionMedium,
    Duration? motionLong,
  }) {
    return BgeTokens(
      spaceXs: spaceXs ?? this.spaceXs,
      spaceSm: spaceSm ?? this.spaceSm,
      spaceMd: spaceMd ?? this.spaceMd,
      spaceLg: spaceLg ?? this.spaceLg,
      spaceXl: spaceXl ?? this.spaceXl,
      spaceXxl: spaceXxl ?? this.spaceXxl,
      radiusSm: radiusSm ?? this.radiusSm,
      radiusMd: radiusMd ?? this.radiusMd,
      radiusLg: radiusLg ?? this.radiusLg,
      minTapTarget: minTapTarget ?? this.minTapTarget,
      focusOutlineWidth: focusOutlineWidth ?? this.focusOutlineWidth,
      motionShort: motionShort ?? this.motionShort,
      motionMedium: motionMedium ?? this.motionMedium,
      motionLong: motionLong ?? this.motionLong,
    );
  }

  @override
  BgeTokens lerp(ThemeExtension<BgeTokens>? other, double t) {
    if (other is! BgeTokens) return this;
    return BgeTokens(
      spaceXs: lerpDouble(spaceXs, other.spaceXs, t)!,
      spaceSm: lerpDouble(spaceSm, other.spaceSm, t)!,
      spaceMd: lerpDouble(spaceMd, other.spaceMd, t)!,
      spaceLg: lerpDouble(spaceLg, other.spaceLg, t)!,
      spaceXl: lerpDouble(spaceXl, other.spaceXl, t)!,
      spaceXxl: lerpDouble(spaceXxl, other.spaceXxl, t)!,
      radiusSm: lerpDouble(radiusSm, other.radiusSm, t)!,
      radiusMd: lerpDouble(radiusMd, other.radiusMd, t)!,
      radiusLg: lerpDouble(radiusLg, other.radiusLg, t)!,
      minTapTarget: lerpDouble(minTapTarget, other.minTapTarget, t)!,
      focusOutlineWidth: lerpDouble(
        focusOutlineWidth,
        other.focusOutlineWidth,
        t,
      )!,
      motionShort: lerpDuration(motionShort, other.motionShort, t),
      motionMedium: lerpDuration(motionMedium, other.motionMedium, t),
      motionLong: lerpDuration(motionLong, other.motionLong, t),
    );
  }
}
