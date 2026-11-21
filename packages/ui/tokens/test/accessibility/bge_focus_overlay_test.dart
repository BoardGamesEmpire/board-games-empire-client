import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// [BgeFocusOverlay.solve], the translucent overlay solved over several
/// backgrounds at once, on the search [BgeFocusFill.solve] uses (#759).
void main() {
  const white = Color(0xFFFFFFFF);
  const grey = Color(0xFFCCCCCC);
  const black = Color(0xFF000000);

  test('the first step that passes over every background wins', () {
    final overlay = BgeFocusOverlay.solve(
      backgrounds: const [white, grey],
      inks: const [black],
    );

    expect(overlay.meetsFloors, isTrue);
    for (final background in [white, grey]) {
      expect(
        Wcag.contrastRatio(
          Color.alphaBlend(overlay.color, background),
          background,
        ),
        greaterThanOrEqualTo(BgeFocusFill.ratio),
      );
    }
    // Over the lighter background alone, a weaker step passes: the darker
    // one holds the overlay back.
    final whiteOnly = BgeFocusOverlay.solve(
      backgrounds: const [white],
      inks: const [black],
    );
    expect(overlay.color.a, greaterThan(whiteOnly.color.a));
  });

  test('over one background, the overlay laid there is the fill '
      'BgeFocusFill.solve gives', () {
    final overlay = BgeFocusOverlay.solve(
      backgrounds: const [white],
      inks: const [black],
      carries: {white: 4.5},
    );
    final fill = BgeFocusFill.solve(
      background: white,
      inks: const [black],
      carries: {white: 4.5},
    );

    expect(Color.alphaBlend(overlay.color, white), fill.color);
    expect(overlay.meetsFloors, fill.meetsFloors);
  });

  test('a carried colour holds its floor under each tint too', () {
    // White on a black overlay over white, with a white tint laid over the
    // fill, as a hover lightens it: the tint takes white's contrast down.
    final tint = white.withValues(alpha: 0.2);
    final plain = BgeFocusOverlay.solve(
      backgrounds: const [white],
      inks: const [black],
      carries: {white: 4.5},
    );
    final tinted = BgeFocusOverlay.solve(
      backgrounds: const [white],
      inks: const [black],
      carries: {white: 4.5},
      tints: [tint],
    );
    Color underTint(BgeFocusOverlay overlay) =>
        Color.alphaBlend(tint, Color.alphaBlend(overlay.color, white));

    expect(plain.meetsFloors, isTrue);
    expect(Wcag.contrastRatio(white, underTint(plain)), lessThan(4.5));
    expect(tinted.meetsFloors, isTrue);
    expect(
      Wcag.contrastRatio(white, underTint(tinted)),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('with no inks, there is no overlay to give', () {
    expect(
      () => BgeFocusOverlay.solve(backgrounds: const [white], inks: const []),
      throwsArgumentError,
    );
  });

  test('with no backgrounds, there is nothing to stand clear of', () {
    expect(
      () => BgeFocusOverlay.solve(backgrounds: const [], inks: const [black]),
      throwsArgumentError,
    );
  });

  test('two solves of the same constraints are equal', () {
    final a = BgeFocusOverlay.solve(
      backgrounds: const [white],
      inks: const [black],
    );
    final b = BgeFocusOverlay.solve(
      backgrounds: const [white],
      inks: const [black],
    );

    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
