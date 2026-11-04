import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The offline strip paints on `surfaceContainerHigh` (#49). Its text, in both
/// states, is `BgeStatusColors.offline` (`onSurfaceVariant`). "Back online"
/// would read as `BgeStatusColors.synced` (`secondary`), but that falls short
/// of 7:1 as text in both high-contrast schemes, so only the icon takes
/// `synced` and the text stays put. Pinned here so a palette change that
/// breaks either half fails loudly.
void main() {
  final schemes = <String, (ColorScheme, double)>{
    'light': (BgeColorSchemes.light, Wcag.aaNormalText),
    'dark': (BgeColorSchemes.dark, Wcag.aaNormalText),
    'highContrastLight': (
      BgeColorSchemes.highContrastLight,
      Wcag.aaaNormalText,
    ),
    'highContrastDark': (BgeColorSchemes.highContrastDark, Wcag.aaaNormalText),
  };

  group('offline strip on surfaceContainerHigh', () {
    for (final entry in schemes.entries) {
      final (scheme, minimum) = entry.value;
      final colors = BgeStatusColors.forScheme(scheme);
      final ground = scheme.surfaceContainerHigh;

      test('${entry.key}: the offline text is at least $minimum:1', () {
        expect(
          Wcag.contrastRatio(colors.offline, ground),
          greaterThanOrEqualTo(minimum),
        );
      });

      test('${entry.key}: the synced icon is at least 3:1 (non-text)', () {
        expect(
          Wcag.contrastRatio(colors.synced, ground),
          greaterThanOrEqualTo(Wcag.aaLargeText),
        );
      });
    }
  });
}
