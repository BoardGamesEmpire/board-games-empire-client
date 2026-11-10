import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The detail page's platform chips (#708): an owned chip is filled in
/// `primary` with its check and label in `onPrimary`, and one not owned is
/// outlined in `primary` on the page's surface, its label in `primary` too.
/// The screen tests pin that the chips draw from those roles; this pins that
/// the roles stand out in every scheme, at the 3:1 a non-text mark needs and
/// the bar body text is held to, so a palette change that breaks any of it
/// fails here.
void main() {
  final schemes = <String, ColorScheme>{
    'light': BgeColorSchemes.light,
    'dark': BgeColorSchemes.dark,
    'highContrastLight': BgeColorSchemes.highContrastLight,
    'highContrastDark': BgeColorSchemes.highContrastDark,
  };

  // The bar body text is held to in each scheme, as bge_color_schemes_test
  // holds the authored pairs: AA, and AAA in high contrast.
  final textMinimum = <String, double>{
    'light': Wcag.aaNormalText,
    'dark': Wcag.aaNormalText,
    'highContrastLight': Wcag.aaaNormalText,
    'highContrastDark': Wcag.aaaNormalText,
  };

  test('chip colours meet 3:1 in all four schemes', () {
    for (final MapEntry(key: name, value: scheme) in schemes.entries) {
      expect(
        Wcag.contrastRatio(scheme.primary, scheme.surface),
        greaterThanOrEqualTo(Wcag.aaLargeText),
        reason: '$name: a chip, filled or outlined, against the surface',
      );
      expect(
        Wcag.contrastRatio(scheme.onPrimary, scheme.primary),
        greaterThanOrEqualTo(Wcag.aaLargeText),
        reason: '$name: the check against its owned chip',
      );
    }
  });

  test("an outlined chip's label reads as body text in all four schemes", () {
    // Its label is the chip's 14 sp text, in `primary` on the surface.
    for (final MapEntry(key: name, value: scheme) in schemes.entries) {
      expect(
        Wcag.contrastRatio(scheme.primary, scheme.surface),
        greaterThanOrEqualTo(textMinimum[name]!),
        reason: "$name: the outlined chip's label against the surface",
      );
    }
  });
}
