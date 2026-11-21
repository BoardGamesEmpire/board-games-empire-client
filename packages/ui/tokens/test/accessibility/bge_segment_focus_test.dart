import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A segment's focus fill and label (#759), worked out from each theme's
/// scheme. The rendered segment is measured in
/// `bge_button_focus_ring_test.dart`.
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
      final parts = {
        'selected': (
          focus: BgeSegmentFocus.selected(scheme),
          backgrounds: [scheme.secondaryContainer],
          hover: scheme.onSecondaryContainer,
        ),
        'unselected': (
          focus: BgeSegmentFocus.unselected(scheme),
          backgrounds: BgeSegmentFocus.unselectedBackgrounds(scheme),
          hover: scheme.onSurface,
        ),
      };

      for (final MapEntry(key: part, value: p) in parts.entries) {
        test('$part: the fill stands the ratio clear of every background, '
            'and the label 4.5:1 on it, hovered or not', () {
          expect(p.focus.meetsFloors, isTrue);

          for (final background in p.backgrounds) {
            final fill = Color.alphaBlend(p.focus.background, background);
            final hovered = Color.alphaBlend(
              BgeSegmentFocus.hoverTint(p.hover),
              fill,
            );
            final twice = Color.alphaBlend(
              BgeSegmentFocus.hoverTint(p.hover),
              hovered,
            );
            expect(
              Wcag.contrastRatio(fill, background),
              greaterThanOrEqualTo(BgeSegmentFocus.ratio),
              reason: '$background',
            );
            expect(
              Wcag.contrastRatio(p.focus.label, fill),
              greaterThanOrEqualTo(4.5),
              reason: '$background',
            );
            expect(
              Wcag.contrastRatio(p.focus.label, hovered),
              greaterThanOrEqualTo(4.5),
              reason: '$background, hovered',
            );
            expect(
              Wcag.contrastRatio(p.focus.label, twice),
              greaterThanOrEqualTo(4.5),
              reason: '$background, two hover tints',
            );
          }
        });
      }
    });
  }

  test("a selected segment's fill is opaque, in place of its own; an "
      "unselected one's is translucent, over what the segment sits on", () {
    for (final build in themes.values) {
      final scheme = build().colorScheme;
      expect(BgeSegmentFocus.selected(scheme).background.a, 1);
      expect(BgeSegmentFocus.unselected(scheme).background.a, lessThan(1));
    }
  });

  test('a selected segment takes a label other than its own at rest, which '
      'no fill can carry', () {
    for (final build in themes.values) {
      final scheme = build().colorScheme;
      expect(
        BgeSegmentFocus.selected(scheme).label,
        isNot(scheme.onSecondaryContainer),
      );
    }
  });

  // STYLE_GUIDE §5 says so: the look is an inverse chip in every theme.
  test('the focused label is onInverseSurface in all four themes, selected '
      'and unselected', () {
    for (final MapEntry(key: name, value: build) in themes.entries) {
      final scheme = build().colorScheme;
      expect(
        BgeSegmentFocus.selected(scheme).label,
        scheme.onInverseSurface,
        reason: '$name, selected',
      );
      expect(
        BgeSegmentFocus.unselected(scheme).label,
        scheme.onInverseSurface,
        reason: '$name, unselected',
      );
    }
  });

  test('the same scheme gives equal results', () {
    final scheme = BgeTheme.light().colorScheme;
    expect(
      BgeSegmentFocus.selected(scheme),
      BgeSegmentFocus.selected(scheme),
    );
    expect(
      BgeSegmentFocus.selected(scheme).hashCode,
      BgeSegmentFocus.selected(scheme).hashCode,
    );
  });
}
