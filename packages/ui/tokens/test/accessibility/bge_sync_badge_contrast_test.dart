import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// `BgeSyncBadge` draws its words in `BgeStatusColors.pending` (waiting) and
/// `BgeStatusColors.conflict` (couldn't sync), on rows that sit on `surface`:
/// list tiles on the page, and `EventCard`'s `Card.outlined`, whose default
/// colour is `surface` too (#47). In high contrast both clear 7:1 there by a
/// thin margin, and fall short on any `surfaceContainer*` ground, which is
/// why the drawer's status line keeps its words neutral. Pinned here so a
/// palette change that breaks it fails loudly.
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

  group('sync badge words on surface', () {
    for (final entry in schemes.entries) {
      final (scheme, minimum) = entry.value;
      final colors = BgeStatusColors.forScheme(scheme);
      final ground = scheme.surface;

      test('${entry.key}: waiting is at least $minimum:1', () {
        expect(
          Wcag.contrastRatio(colors.pending, ground),
          greaterThanOrEqualTo(minimum),
        );
      });

      test("${entry.key}: couldn't sync is at least $minimum:1", () {
        expect(
          Wcag.contrastRatio(colors.conflict, ground),
          greaterThanOrEqualTo(minimum),
        );
      });
    }
  });
}
