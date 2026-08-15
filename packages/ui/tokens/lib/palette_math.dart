/// The OKLCH hue math the palette is authored against, in plain Dart (#172).
///
/// A second entry point on purpose. `tool/derive_palette.dart` generates
/// `bge_color_schemes.dart` and re-checks it, and it runs under `dart run` —
/// so it cannot import anything that reaches `dart:ui`. Everything here is
/// therefore expressed in plain doubles, and `Oklch` is the `Color`-shaped
/// wrapper the app uses.
///
/// Before this file the transform matrices and [minAccentSeparation] were
/// copied into the tool, with a comment on each side asking the next person to
/// keep them in step. Nothing enforced it, and the direction that drifts
/// quietly is the dangerous one: loosen the tool's copy and it emits a palette
/// the token test then rejects (noisy, caught), but loosen the token copy and
/// the tool keeps passing while the runtime guarantee weakens.
///
/// Deliberately outside `lib/src/` and outside the `ui_tokens.dart` barrel.
/// Outside `src/` because a second entry point is the only way an importer
/// beyond this package can reach it without an implementation import; outside
/// the barrel because app code should reach this through `Oklch`, not find a
/// bare `minAccentSeparation` in its namespace.
library;

import 'dart:math' as math;

/// The floor the ember/crimson pair is held to, in degrees.
///
/// Not standards-derived — no WCAG criterion covers hue distinctness. It is
/// the empirical threshold this palette was tuned against: the first draft put
/// ember and error 43° apart and they read as the same warm colour at a
/// glance, so the authored pair sits at ~54° with this as the regression
/// floor.
const double minAccentSeparation = 45;

/// The OKLCH hue of an sRGB colour, in degrees `0..360`.
///
/// [r], [g] and [b] are gamma-encoded sRGB components in `0..1` — the
/// representation `Color.r` and friends already hand back.
///
/// Hue is meaningless for greys: chroma approaches zero and the angle becomes
/// numerical noise. Callers comparing near-neutral colours should treat the
/// result as unreliable; it is only ever asked of saturated accent roles here.
double oklchHue(double r, double g, double b) {
  final lr = srgbToLinear(r);
  final lg = srgbToLinear(g);
  final lb = srgbToLinear(b);

  final l = _cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
  final m = _cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
  final s = _cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);

  final a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
  final bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;

  final degrees = math.atan2(bb, a) * 180 / math.pi;
  return degrees < 0 ? degrees + 360 : degrees;
}

/// The smaller angle between hues [a] and [b], in degrees `0..180`.
///
/// Wraps correctly: 350° and 10° are 20° apart, not 340°.
double hueSeparation(double a, double b) {
  final delta = (a - b).abs();
  return delta > 180 ? 360 - delta : delta;
}

/// Undoes the sRGB transfer function on a single component in `0..1`.
///
/// Public because the generator needs it too: its WCAG luminance is a copy of
/// `Color.computeLuminance`, which is the one piece of that arithmetic it
/// cannot reach from plain Dart. `Wcag` has no counterpart to share — it
/// delegates the whole luminance step to Flutter — so this curve is the entire
/// overlap between the two sides.
double srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _cbrt(double x) =>
    x < 0 ? -math.pow(-x, 1 / 3).toDouble() : math.pow(x, 1 / 3).toDouble();
