import 'dart:math' as math;
import 'dart:ui' show Color;

/// WCAG 2.1 contrast thresholds and the ratio computation (#32).
///
/// Pure Dart on top of [Color.computeLuminance] (which implements the
/// WCAG relative-luminance formula) — deliberately dependency-free. The
/// scheme tests use it to *enforce* the authored contrast guarantees; it
/// is exported so future dynamic-color surfaces (user-picked colors,
/// server-supplied branding) can validate at runtime.
abstract final class Wcag {
  /// SC 1.4.3 — minimum for normal text (AA).
  static const double aaNormalText = 4.5;

  /// SC 1.4.3 — minimum for large text and SC 1.4.11 non-text (AA).
  static const double aaLargeText = 3;

  /// SC 1.4.6 — minimum for normal text (AAA); the bar the
  /// high-contrast schemes are held to.
  static const double aaaNormalText = 7;

  /// The WCAG contrast ratio between [a] and [b], in `1.0..21.0`.
  /// Symmetric — argument order does not matter.
  static double contrastRatio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final lighter = math.max(la, lb);
    final darker = math.min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
  }
}
