import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The shared calculation that chooses a focus fill with its foreground
/// (#758, #909).
void main() {
  const white = Color(0xFFFFFFFF);
  const black = Color(0xFF000000);

  /// [ink] over [background] at [step] twentieths.
  Color blend(Color ink, int step, Color background) =>
      Color.alphaBlend(ink.withValues(alpha: step / 20), background);

  group('solve', () {
    test('the first passing step wins', () {
      // Black at 8/20 stands 2.85:1 from white, at 9/20 3.37:1.
      expect(
        Wcag.contrastRatio(blend(black, 8, white), white),
        lessThan(BgeFocusFill.ratio),
      );
      expect(
        Wcag.contrastRatio(blend(black, 9, white), white),
        greaterThanOrEqualTo(BgeFocusFill.ratio),
      );

      final focus = BgeFocusFill.solve(background: white, inks: const [black]);

      expect(focus.meetsFloors, isTrue);
      expect(focus.color, blend(black, 9, white));
    });

    test('a later ink is tried when the first fails', () {
      // Light grey at full strength stands only 1.6:1 from white.
      const grey = Color(0xFFCCCCCC);
      expect(
        Wcag.contrastRatio(grey, white),
        lessThan(BgeFocusFill.ratio),
      );

      final focus = BgeFocusFill.solve(
        background: white,
        inks: const [grey, black],
      );

      expect(focus.meetsFloors, isTrue);
      expect(focus.color, blend(black, 9, white));
    });

    test('an earlier ink that passes wins over a later one that passes at a '
        'lower step', () {
      // Mid grey first stands 3.2:1 from white at 17/20, black at 9/20.
      const grey = Color(0xFF767676);
      expect(
        Wcag.contrastRatio(blend(grey, 16, white), white),
        lessThan(BgeFocusFill.ratio),
      );
      expect(
        Wcag.contrastRatio(blend(grey, 17, white), white),
        greaterThanOrEqualTo(BgeFocusFill.ratio),
      );

      final focus = BgeFocusFill.solve(
        background: white,
        inks: const [grey, black],
      );

      expect(focus.meetsFloors, isTrue);
      expect(focus.color, blend(grey, 17, white));
    });

    test('a step that stands clear of the background still fails a colour '
        'it must stand from, or one it carries', () {
      // At 9/20 black stands 3.37:1 from white, but only 1.17:1 from a grey
      // it must also stand from, and it carries a light grey at 2.1:1.
      const light = Color(0xFFCCCCCC);
      final standsFrom = BgeFocusFill.solve(
        background: white,
        inks: const [black],
        standsFrom: [blend(black, 10, white)],
      );
      final carries = BgeFocusFill.solve(
        background: white,
        inks: const [black],
        carries: {light: 3},
      );

      // Each passes further up, where it is darker.
      for (final focus in [standsFrom, carries]) {
        expect(focus.meetsFloors, isTrue);
        expect(
          focus.color.computeLuminance(),
          lessThan(blend(black, 9, white).computeLuminance()),
        );
      }
      expect(
        Wcag.contrastRatio(standsFrom.color, blend(black, 10, white)),
        greaterThanOrEqualTo(BgeFocusFill.ratio),
      );
      expect(
        Wcag.contrastRatio(light, carries.color),
        greaterThanOrEqualTo(3.0),
      );
    });

    test('no pass reports meetsFloors false and never leaves a carried '
        'colour at 1:1', () {
      // A mid grey carried on a fill of itself: a fill dark enough to stand
      // 3.2:1 from white is too close to the grey to carry it at 3:1. At
      // full strength the grey sits on itself, 1:1.
      const grey = Color(0xFF6C6C6C);

      final focus = BgeFocusFill.solve(
        background: white,
        inks: const [grey],
        carries: {grey: 3},
      );

      expect(focus.meetsFloors, isFalse);
      expect(Wcag.contrastRatio(grey, focus.color), greaterThan(2.0));

      // The step whose worst constraint, as a share of its floor, is highest.
      double worst(Color fill) => [
        Wcag.contrastRatio(fill, white) / BgeFocusFill.ratio,
        Wcag.contrastRatio(grey, fill) / 3,
      ].reduce((a, b) => a < b ? a : b);
      for (var step = 1; step <= 20; step++) {
        expect(
          worst(focus.color),
          greaterThanOrEqualTo(worst(blend(grey, step, white))),
          reason: 'step $step',
        );
      }
    });

    test('with no pass over two inks, the step with the best worst share '
        'across both wins', () {
      // A mid grey carried at 3:1. The grey's own steps come nearest at about
      // 0.73 of a floor; a dark grey's full strength carries it at 2.55:1,
      // 0.85 of its floor, and still fails.
      const grey = Color(0xFF6C6C6C);
      const dark = Color(0xFF303030);
      final inks = [grey, dark];

      final focus = BgeFocusFill.solve(
        background: white,
        inks: inks,
        carries: {grey: 3},
      );

      expect(focus.meetsFloors, isFalse);
      double worst(Color fill) => [
        Wcag.contrastRatio(fill, white) / BgeFocusFill.ratio,
        Wcag.contrastRatio(grey, fill) / 3,
      ].reduce((a, b) => a < b ? a : b);
      for (final ink in inks) {
        for (var step = 1; step <= 20; step++) {
          expect(
            worst(focus.color),
            greaterThanOrEqualTo(worst(blend(ink, step, white))),
            reason: '$ink at step $step',
          );
        }
      }
      // From the later ink, which the first ink's best falls short of.
      expect(focus.color, blend(dark, 20, white));
    });

    test('two solves of the same constraints are equal', () {
      // A value class: equal inputs give equal results.
      final a = BgeFocusFill.solve(background: white, inks: const [black]);
      final b = BgeFocusFill.solve(background: white, inks: const [black]);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(
          BgeFocusFill.solve(
            background: white,
            inks: const [black],
            carries: {const Color(0xFFCCCCCC): 3},
          ),
        ),
      );
    });
  });
}
