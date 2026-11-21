import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The focus fills of a navigation bar and rail (#644, #414), worked out
/// from each theme's scheme. The rendered bar and rail are measured in
/// `bge_button_focus_ring_test.dart` and the shell's own test.
void main() {
  final themes = {
    'light': BgeTheme.light,
    'dark': BgeTheme.dark,
    'highContrastLight': BgeTheme.highContrastLight,
    'highContrastDark': BgeTheme.highContrastDark,
  };

  for (final MapEntry(key: name, value: build) in themes.entries) {
    group(name, () {
      final scheme = build().colorScheme;

      test("a rail's fill stands the ratio clear of the surface it sits on, "
          'and the icon 3:1 clear of the fill', () {
        final fill = BgeNavigationFocus.railFill(scheme);

        expect(
          Wcag.contrastRatio(fill, scheme.surface),
          greaterThanOrEqualTo(BgeNavigationFocus.ratio),
        );
        expect(
          Wcag.contrastRatio(BgeNavigationFocus.iconColor(scheme), fill),
          greaterThanOrEqualTo(3.0),
        );
      });

      test("a bar's fill does the same on surfaceContainer", () {
        final fill = BgeNavigationFocus.barFill(scheme);

        expect(
          Wcag.contrastRatio(fill, scheme.surfaceContainer),
          greaterThanOrEqualTo(BgeNavigationFocus.ratio),
        );
        expect(
          Wcag.contrastRatio(BgeNavigationFocus.iconColor(scheme), fill),
          greaterThanOrEqualTo(3.0),
        );
      });
    });
  }

  // The fills the four themes shipped with before the fill was solved with
  // its icon (#909). The icon's floor doesn't move them.
  final shipped = {
    'light': (bar: 0xFF7F766F, rail: 0xFF8E8882),
    'dark': (bar: 0xFF7A726B, rail: 0xFF746C65),
    'highContrastLight': (bar: 0xFF85807B, rail: 0xFF8C8C8C),
    'highContrastDark': (bar: 0xFF6F6B68, rail: 0xFF666666),
  };

  group('barFocus and railFocus meet every floor in all four themes', () {
    for (final MapEntry(key: name, value: build) in themes.entries) {
      test(name, () {
        final scheme = build().colorScheme;
        final icon = BgeNavigationFocus.iconColor(scheme);
        final parts = {
          'bar': (
            focus: BgeNavigationFocus.barFocus(scheme),
            fill: BgeNavigationFocus.barFill(scheme),
            background: scheme.surfaceContainer,
            shipped: shipped[name]!.bar,
          ),
          'rail': (
            focus: BgeNavigationFocus.railFocus(scheme),
            fill: BgeNavigationFocus.railFill(scheme),
            background: scheme.surface,
            shipped: shipped[name]!.rail,
          ),
        };

        for (final MapEntry(key: part, value: p) in parts.entries) {
          expect(p.focus.meetsFloors, isTrue, reason: part);
          expect(p.fill, p.focus.color, reason: part);
          expect(
            Wcag.contrastRatio(p.focus.color, p.background),
            greaterThanOrEqualTo(BgeFocusFill.ratio),
            reason: '$part: the fill',
          );
          expect(
            Wcag.contrastRatio(icon, p.focus.color),
            greaterThanOrEqualTo(3.0),
            reason: '$part: the icon',
          );
          expect(
            p.focus.color.toARGB32(),
            p.shipped,
            reason: '$part: the fill it shipped with',
          );
        }
      });
    }
  });

  // A user palette (#644) can put onSurface too close to the surface for any
  // fill to stand 3.2:1 from the bar and carry the icon at 3:1. Before #909
  // the fill ignored the icon: it stood 3.42:1 from the bar and left the icon
  // on it at 1.32:1.
  test('a palette with onSurface 5:1 from surface reaches the no-pass branch, '
      'and its icon stays above 1:1', () {
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.teal,
    ).copyWith(onSurface: const Color(0xFF6C6C6C));
    expect(
      Wcag.contrastRatio(scheme.onSurface, scheme.surface),
      closeTo(5.0, 0.05),
    );
    final icon = BgeNavigationFocus.iconColor(scheme);

    final bar = BgeNavigationFocus.barFocus(scheme);
    final rail = BgeNavigationFocus.railFocus(scheme);

    expect(bar.meetsFloors, isFalse);
    expect(rail.meetsFloors, isFalse);
    expect(Wcag.contrastRatio(icon, bar.color), greaterThan(2.0));
    expect(Wcag.contrastRatio(icon, rail.color), greaterThan(2.0));
    expect(BgeNavigationFocus.barFill(scheme), bar.color);
    expect(BgeNavigationFocus.railFill(scheme), rail.color);
  });
}
