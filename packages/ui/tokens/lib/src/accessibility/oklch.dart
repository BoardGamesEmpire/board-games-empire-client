import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:ui_tokens/src/accessibility/wcag_contrast.dart';

/// OKLCH hue extraction, for the checks contrast ratio cannot make (#32).
///
/// Contrast answers "can this be read?". It does not answer "can these two be
/// told apart?" — two colours can sit at identical luminance, pass every
/// contrast assertion, and still be indistinguishable from each other. In this
/// palette that matters for exactly one pair: `tertiary` (ember) and `error`
/// (crimson), which are both warm and both mid-luminance. See
/// `bge_color_schemes_test.dart`, which asserts [separation] between them.
///
/// OKLCH rather than HSL because it is perceptually uniform: a 50° hue step is
/// about as visible at one lightness as at another, which is what makes a
/// fixed [separation] threshold meaningful. HSL hue degrees are not comparable
/// that way — its yellows and blues occupy wildly different perceptual widths.
///
/// Exported alongside [Wcag] for the same reason: the customization seam
/// (`BgePalette`) will need to validate palettes it did not author.
abstract final class Oklch {
  /// The OKLCH hue of [color], in degrees `0..360`.
  ///
  /// Hue is meaningless for greys — chroma approaches zero and the angle
  /// becomes numerical noise. Callers comparing near-neutral colours should
  /// treat the result as unreliable; [separation] is only used here on
  /// saturated accent roles.
  static double hueOf(Color color) {
    final r = _toLinear(color.r);
    final g = _toLinear(color.g);
    final b = _toLinear(color.b);

    final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);

    final a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
    final bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;

    final degrees = math.atan2(bb, a) * 180 / math.pi;
    return degrees < 0 ? degrees + 360 : degrees;
  }

  /// The smaller angle between the hues of [a] and [b], in degrees `0..180`.
  ///
  /// Wraps correctly: 350° and 10° are 20° apart, not 340°.
  static double separation(Color a, Color b) {
    final delta = (hueOf(a) - hueOf(b)).abs();
    return delta > 180 ? 360 - delta : delta;
  }

  /// The floor the ember/crimson pair is held to.
  ///
  /// 45° is not a standards-derived number — no WCAG criterion covers
  /// hue distinctness. It is the empirical threshold this palette was tuned
  /// against: the first draft put ember and error 43° apart and they read as
  /// the same warm colour at a glance, so the authored pair sits at ~54° with
  /// this as the regression floor.
  static const double minAccentSeparation = 45;

  static double _toLinear(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

  static double _cbrt(double x) =>
      x < 0 ? -math.pow(-x, 1 / 3).toDouble() : math.pow(x, 1 / 3).toDouble();
}
