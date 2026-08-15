import 'dart:ui' show Color;

import 'package:ui_tokens/palette_math.dart' as palette;
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
///
/// The arithmetic itself lives in `palette_math.dart`, which is Flutter-free
/// so `tool/derive_palette.dart` can check the palette against the same
/// numbers this does (#172). This class is the `Color` end of that: the app
/// holds colours, the generator holds packed ints, and neither should own a
/// second copy of the transform. Read that file for what the values mean and
/// where they came from.
abstract final class Oklch {
  /// The OKLCH hue of [color], in degrees `0..360`.
  ///
  /// Unreliable for near-neutral colours — see [palette.oklchHue].
  static double hueOf(Color color) =>
      palette.oklchHue(color.r, color.g, color.b);

  /// The smaller angle between the hues of [a] and [b], in degrees `0..180`.
  static double separation(Color a, Color b) =>
      palette.hueSeparation(hueOf(a), hueOf(b));

  /// The floor the ember/crimson pair is held to; see
  /// [palette.minAccentSeparation].
  static const double minAccentSeparation = palette.minAccentSeparation;
}
