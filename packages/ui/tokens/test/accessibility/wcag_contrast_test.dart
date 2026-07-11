import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

void main() {
  group('Wcag.contrastRatio', () {
    const white = Color(0xFFFFFFFF);
    const black = Color(0xFF000000);

    test('black on white is the maximum ratio, 21:1', () {
      expect(Wcag.contrastRatio(black, white), closeTo(21.0, 0.01));
    });

    test('identical colors are the minimum ratio, 1:1', () {
      expect(Wcag.contrastRatio(white, white), closeTo(1.0, 0.001));
      expect(Wcag.contrastRatio(black, black), closeTo(1.0, 0.001));
    });

    test('is symmetric in its arguments', () {
      const a = Color(0xFF2E5AAC);
      expect(
        Wcag.contrastRatio(a, white),
        equals(Wcag.contrastRatio(white, a)),
      );
    });

    test('matches a known reference value (white on #767676 ≈ 4.54:1)', () {
      // #767676 is the canonical "lightest AA-passing gray on white".
      const gray = Color(0xFF767676);
      expect(Wcag.contrastRatio(white, gray), closeTo(4.54, 0.02));
    });

    test('thresholds carry the WCAG 2.1 values', () {
      expect(Wcag.aaNormalText, 4.5);
      expect(Wcag.aaLargeText, 3.0);
      expect(Wcag.aaaNormalText, 7.0);
    });
  });
}
