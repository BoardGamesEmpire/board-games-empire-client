import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

void main() {
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

  group('BgeTheme accessibility baseline (all four themes)', () {
    for (final entry in themes.entries) {
      final (theme, scheme) = entry.value;

      test('${entry.key}: 48dp tap targets via MaterialTapTargetSize.padded '
          'on every platform', () {
        expect(theme.materialTapTargetSize, MaterialTapTargetSize.padded);
      });

      test('${entry.key}: VisualDensity.standard '
          '(not adaptivePlatformDensity)', () {
        expect(theme.visualDensity, VisualDensity.standard);
      });

      test('${entry.key}: installs BgeTokens.standard as a ThemeExtension', () {
        expect(theme.extension<BgeTokens>(), same(BgeTokens.standard));
      });

      test('${entry.key}: uses the authored color scheme', () {
        expect(theme.colorScheme.primary, scheme.primary);
        expect(theme.colorScheme.surface, scheme.surface);
        expect(theme.colorScheme.brightness, scheme.brightness);
        expect(theme.brightness, scheme.brightness);
      });

      test('${entry.key}: visible focus on text inputs — '
          'focusOutlineWidth primary border', () {
        final border = theme.inputDecorationTheme.focusedBorder;
        expect(border, isA<OutlineInputBorder>());
        expect(border!.borderSide.width, BgeTokens.standard.focusOutlineWidth);
        expect(border.borderSide.color, scheme.primary);
      });
    }
  });

  group('BgeTheme typography', () {
    testWidgets('resolved text theme matches the BgeTypography scale '
        '(system typeface, M3 geometry)', (tester) async {
      late TextTheme resolved;
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          home: Builder(
            builder: (context) {
              resolved = Theme.of(context).textTheme;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(resolved.displayLarge!.fontSize, BgeTypography.displayLarge);
      expect(resolved.headlineSmall!.fontSize, BgeTypography.headlineSmall);
      expect(resolved.titleLarge!.fontSize, BgeTypography.titleLarge);
      expect(resolved.bodyLarge!.fontSize, BgeTypography.bodyLarge);
      expect(resolved.bodyMedium!.fontSize, BgeTypography.bodyMedium);
      expect(resolved.labelSmall!.fontSize, BgeTypography.labelSmall);
    });
  });
}
