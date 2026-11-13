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
}
