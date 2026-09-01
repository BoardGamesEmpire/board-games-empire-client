import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/scheme_surfaces.dart';

void main() {
  // Scheme to selected-text floor, mirroring `bge_color_schemes_test.dart`'s
  // AA/AAA split. The high-contrast pair is held higher on purpose: at 3:1
  // Material's own 0.40 default would pass there (4.10 and 4.06) and the case
  // for authoring a colour at all would rest on light and dark alone.
  final schemes = <String, (ColorScheme, double)>{
    'light': (
      BgeColorSchemes.light,
      BgeSelection.minSelectedTextContrast,
    ),
    'dark': (BgeColorSchemes.dark, BgeSelection.minSelectedTextContrast),
    'highContrastLight': (
      BgeColorSchemes.highContrastLight,
      BgeSelection.minSelectedTextContrastHighContrast,
    ),
    'highContrastDark': (
      BgeColorSchemes.highContrastDark,
      BgeSelection.minSelectedTextContrastHighContrast,
    ),
  };

  group('BgeSelection legibility', () {
    for (final entry in schemes.entries) {
      test('${entry.key}: selected text stays readable on every surface', () {
        final (scheme, floor) = entry.value;
        final tint = BgeSelection.colorFor(scheme);
        for (final (bgName, background) in surfaceFamily(scheme)) {
          final highlighted = Color.alphaBlend(tint, background);
          for (final (fgName, foreground) in bodyTextRoles(scheme)) {
            final ratio = Wcag.contrastRatio(foreground, highlighted);
            expect(
              ratio,
              greaterThanOrEqualTo(floor),
              reason:
                  '$fgName on selected $bgName is '
                  '${ratio.toStringAsFixed(2)}:1, below the required '
                  '$floor:1',
            );
          }
        }
      });
    }
  });

  group('BgeSelection visibility', () {
    for (final entry in schemes.entries) {
      test('${entry.key}: the highlight is distinguishable from every '
          'surface-family background', () {
        // Scoped to the surface family, and that scope is the guarantee —
        // not an oversight. One `selectionColor` cannot be visible on every
        // background: on `primary` it measures exactly 1.00:1, so a
        // FilledButton label selects with no highlight. See BgeSelection's
        // "What this does not guarantee".
        final (scheme, _) = entry.value;
        final tint = BgeSelection.colorFor(scheme);
        for (final (bgName, background) in surfaceFamily(scheme)) {
          final highlighted = Color.alphaBlend(tint, background);
          final ratio = Wcag.contrastRatio(highlighted, background);
          expect(
            ratio,
            greaterThanOrEqualTo(BgeSelection.minVisibility),
            reason:
                'the highlight over $bgName is only '
                '${ratio.toStringAsFixed(2)}:1 against the unselected '
                'surface — at that point the user cannot see what they have '
                'selected. Raising ${BgeSelection.tintAlpha} fixes this but '
                'costs selected-text contrast; the two floors bracket the '
                'usable range.',
          );
        }
      });
    }
  });

  group('BgeSelection platform gate', () {
    test('pointer platforms get the region', () {
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(
          BgeSelection.isEnabledOn(platform),
          isTrue,
          reason: '$platform is a pointer platform',
        );
      }
    });

    test('touch platforms do not', () {
      // Not a preference: a long-press over a control on touch summons the
      // magnifier and selects the control's label. The copy affordances on
      // the error surfaces serve these platforms instead.
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          BgeSelection.isEnabledOn(platform),
          isFalse,
          reason: '$platform is a touch platform',
        );
      }
    });

    test('the two sets partition every TargetPlatform', () {
      // The switch is exhaustive, so a platform Flutter adds breaks the
      // build rather than silently defaulting. What this adds is that the
      // two lists above are not merely *a* partition but *the* partition —
      // a platform in neither list would go unnoticed by both tests.
      const pointer = {
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      };
      const touch = {
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      };
      expect({...pointer, ...touch}, TargetPlatform.values.toSet());
      for (final platform in TargetPlatform.values) {
        expect(
          BgeSelection.isEnabledOn(platform),
          pointer.contains(platform),
          reason: '$platform is classified inconsistently',
        );
      }
    });
  });

  group('BgeSelection wiring', () {
    final themes = <String, (ThemeData, ColorScheme)>{
      'light': (BgeTheme.light(), BgeColorSchemes.light),
      'dark': (BgeTheme.dark(), BgeColorSchemes.dark),
      'highContrastLight': (
        BgeTheme.highContrastLight(),
        BgeColorSchemes.highContrastLight,
      ),
      'highContrastDark': (
        BgeTheme.highContrastDark(),
        BgeColorSchemes.highContrastDark,
      ),
    };

    for (final entry in themes.entries) {
      final (theme, scheme) = entry.value;
      test('${entry.key}: the theme installs the authored selection '
          'colour', () {
        // Without this the framework silently substitutes
        // `primary.withOpacity(0.40)` (material/app.dart), which fails the
        // legibility floor above in every scheme.
        expect(
          theme.textSelectionTheme.selectionColor,
          BgeSelection.colorFor(scheme),
        );
      });
    }
  });
}
