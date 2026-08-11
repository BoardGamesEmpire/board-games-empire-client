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
  /// Creates a token set. Prefer [standard]; this exists for tests and the
  /// future SDUI layer (#19).
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
    required this.contentMaxWidth,
    required this.breakpointMedium,
    required this.breakpointExpanded,
    required this.motionShort,
    required this.motionMedium,
    required this.motionLong,
  });

  // ── Scale primitives ───────────────────────────────────────────────
  // The spacing scale as bare `const double`s, so it can be referenced from
  // const initializers. Dart forbids reading an instance field of a const
  // object inside a constant expression, so `BgeTokens.standard.spaceMd` is
  // not available to one — which `BgeGap`'s const constructors need. These are
  // the single source of truth; [standard] is built from them.

  /// Extra-small spacing step: 4dp.
  static const double spaceXsValue = 4;

  /// Small spacing step: 8dp. The intra-control gap.
  static const double spaceSmValue = 8;

  /// Medium spacing step: 16dp. The inter-control rhythm.
  static const double spaceMdValue = 16;

  /// Large spacing step: 24dp. The section break.
  static const double spaceLgValue = 24;

  /// Extra-large spacing step: 32dp.
  static const double spaceXlValue = 32;

  /// Double-extra-large spacing step: 48dp.
  static const double spaceXxlValue = 48;

  /// The app-wide token values.
  static const BgeTokens standard = BgeTokens(
    spaceXs: spaceXsValue,
    spaceSm: spaceSmValue,
    spaceMd: spaceMdValue,
    spaceLg: spaceLgValue,
    spaceXl: spaceXlValue,
    spaceXxl: spaceXxlValue,
    radiusSm: 4,
    radiusMd: 12,
    radiusLg: 16,
    minTapTarget: 48,
    focusOutlineWidth: 2,
    contentMaxWidth: 480,
    breakpointMedium: 600,
    breakpointExpanded: 840,
    motionShort: Duration(milliseconds: 150),
    motionMedium: Duration(milliseconds: 300),
    motionLong: Duration(milliseconds: 500),
  );

  /// The ambient token set, or [standard] when no theme provides one.
  ///
  /// **Prefer this over `Theme.of(context).extension<BgeTokens>()!`.** Two
  /// reasons, and the second is the important one:
  ///
  /// 1. Ergonomics. The extension lookup is long enough at a call site that
  ///    people quietly keep typing `16` instead — which is how this token set
  ///    ended up with zero consumers repo-wide before #165.
  /// 2. The fallback. Widget tests across the feature packages pump a bare
  ///    `MaterialApp`, where the extension resolves to `null` and the
  ///    bang-operator form throws. Falling back to [standard] means tokenizing
  ///    a widget does not drag its whole test file along with it — and since
  ///    [standard] is exactly what every `BgeTheme` installs, the fallback
  ///    renders identically to the themed path rather than approximating it.
  ///
  /// Mirrors the shape `BgeMotion.durationOf` and `BgeTextScale.clampedOf`
  /// already use, so the token layer presents one consistent accessor idiom.
  static BgeTokens of(BuildContext context) =>
      Theme.of(context).extension<BgeTokens>() ?? standard;

  // ── Spacing scale (logical px) ─────────────────────────────────────

  /// Extra-small spacing step (logical px).
  final double spaceXs;

  /// Small spacing step (logical px).
  final double spaceSm;

  /// Medium spacing step (logical px).
  final double spaceMd;

  /// Large spacing step (logical px).
  final double spaceLg;

  /// Extra-large spacing step (logical px).
  final double spaceXl;

  /// Double-extra-large spacing step (logical px).
  final double spaceXxl;

  // ── Corner radii ───────────────────────────────────────────────────

  /// Small corner radius (logical px).
  final double radiusSm;

  /// Medium corner radius (logical px).
  final double radiusMd;

  /// Large corner radius (logical px).
  final double radiusLg;

  // ── Accessibility dimensions ───────────────────────────────────────

  /// Minimum interactive tap-target edge (WCAG 2.5.5 / Material: 48dp).
  /// Enforced theme-wide via `MaterialTapTargetSize.padded`; exposed here
  /// for custom hit regions.
  final double minTapTarget;

  /// Visible-focus indicator stroke width (WCAG 2.4.7).
  final double focusOutlineWidth;

  // ── Layout ─────────────────────────────────────────────────────────

  /// Maximum width of a page's primary content column (logical px).
  ///
  /// Keeps forms and prose at a comfortable measure on desktop and web
  /// instead of stretching them across a 2560px monitor. Applied by `BgePage`;
  /// this literal was previously copy-pasted into eleven screens.
  final double contentMaxWidth;

  /// Width at or above which a layout may use its medium form (logical px).
  final double breakpointMedium;

  /// Width at or above which a layout may use its expanded form (logical px).
  ///
  /// Breakpoints exist because desktop and browser are first-class targets
  /// here, not an afterthought — a phone-shaped layout stretched to a desktop
  /// window is the most common way a cross-platform Flutter app looks wrong.
  final double breakpointExpanded;

  // ── Motion durations ───────────────────────────────────────────────
  // Resolve through `BgeMotion.durationOf` so OS reduced-motion collapses
  // them to zero.

  /// Short motion duration (e.g. small state changes).
  final Duration motionShort;

  /// Medium motion duration (e.g. transitions).
  final Duration motionMedium;

  /// Long motion duration (e.g. large or emphasized transitions).
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
    double? contentMaxWidth,
    double? breakpointMedium,
    double? breakpointExpanded,
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
      contentMaxWidth: contentMaxWidth ?? this.contentMaxWidth,
      breakpointMedium: breakpointMedium ?? this.breakpointMedium,
      breakpointExpanded: breakpointExpanded ?? this.breakpointExpanded,
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
      contentMaxWidth: lerpDouble(contentMaxWidth, other.contentMaxWidth, t)!,
      breakpointMedium: lerpDouble(
        breakpointMedium,
        other.breakpointMedium,
        t,
      )!,
      breakpointExpanded: lerpDouble(
        breakpointExpanded,
        other.breakpointExpanded,
        t,
      )!,
      motionShort: lerpDuration(motionShort, other.motionShort, t),
      motionMedium: lerpDuration(motionMedium, other.motionMedium, t),
      motionLong: lerpDuration(motionLong, other.motionLong, t),
    );
  }
}
