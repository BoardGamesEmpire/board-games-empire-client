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

      test('${entry.key}: installs BgeStatusColors derived from its own '
          'scheme', () {
        final status = theme.extension<BgeStatusColors>();
        expect(status, isNotNull);
        // Derived, not authored: each status must track the scheme it was
        // built from, or a palette swap silently desynchronizes them.
        expect(status!.pending, scheme.tertiary);
        expect(status.conflict, scheme.error);
        expect(status.offline, scheme.onSurfaceVariant);
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
    late TextTheme resolved;

    setUp(() => resolved = BgeTheme.light().textTheme);

    testWidgets('resolved text theme matches the BgeTypography scale', (
      tester,
    ) async {
      late TextTheme viaContext;
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          home: Builder(
            builder: (context) {
              viaContext = Theme.of(context).textTheme;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(viaContext.displayLarge!.fontSize, BgeTypography.displayLarge);
      expect(viaContext.headlineSmall!.fontSize, BgeTypography.headlineSmall);
      expect(viaContext.titleLarge!.fontSize, BgeTypography.titleLarge);
      expect(viaContext.bodyLarge!.fontSize, BgeTypography.bodyLarge);
      expect(viaContext.bodyMedium!.fontSize, BgeTypography.bodyMedium);
      expect(viaContext.labelSmall!.fontSize, BgeTypography.labelSmall);
    });

    // The two-family split is the whole typography decision, so it is pinned
    // rather than left to inspection. This REPLACES an earlier assertion that
    // the theme set no textTheme at all — that was correct while the app used
    // the system face for everything, and is deliberately no longer true.
    test('display, headline and title roles use the bundled display face', () {
      for (final style in [
        resolved.displayLarge,
        resolved.displayMedium,
        resolved.displaySmall,
        resolved.headlineLarge,
        resolved.headlineMedium,
        resolved.headlineSmall,
        resolved.titleLarge,
        resolved.titleMedium,
        resolved.titleSmall,
      ]) {
        // Fonts shipped from a package are namespaced by the framework.
        expect(
          style!.fontFamily,
          'packages/${BgeTypography.displayFamilyPackage}/'
          '${BgeTypography.displayFamily}',
        );
      }
    });

    test('body and label roles resolve to the platform face, not the '
        'bundled one', () {
      // Asserting `fontFamily == null` would be wrong: `ThemeData` merges the
      // supplied TextTheme onto `Typography` for the target platform, so these
      // arrive already resolved to Roboto / .SF UI Text / Segoe rather than
      // staying null. That resolution IS the intent — what must never happen
      // is body text picking up the display face.
      for (final style in [
        resolved.bodyLarge,
        resolved.bodyMedium,
        resolved.bodySmall,
        resolved.labelLarge,
        resolved.labelMedium,
        resolved.labelSmall,
      ]) {
        expect(
          style!.fontFamily,
          isNot(contains(BgeTypography.displayFamily)),
          reason:
              'Body and label must resolve to the platform typeface. Using the '
              'bundled display face here would take on legibility and language '
              'coverage for the text users actually read.',
        );
      }
    });

    test('every role carries a line height and tracking', () {
      // A size scale without vertical rhythm is half a scale; this catches a
      // role being added later with only a fontSize.
      for (final style in [
        resolved.displayLarge,
        resolved.headlineMedium,
        resolved.titleLarge,
        resolved.bodyMedium,
        resolved.labelSmall,
      ]) {
        expect(style!.height, isNotNull);
        expect(style.letterSpacing, isNotNull);
      }
    });

    test('display roles set every variable-font axis explicitly', () {
      // Unset axes fall back to the FONT's fvar defaults, which for Fraunces
      // are opsz=9, wght=900, WONK=1 — small-text letterforms, black weight,
      // wonky alternates on. None of those is what this app wants, and none
      // of them errors: an unset axis just silently renders wrong. So all
      // four are pinned.
      final axes = resolved.displayLarge!.fontVariations;
      expect(axes, isNotNull);
      final byAxis = {for (final a in axes!) a.axis: a.value};

      expect(byAxis['wght'], BgeTypography.weightDisplay);
      expect(byAxis['SOFT'], BgeTypography.softness);
      expect(byAxis['WONK'], BgeTypography.wonk);
      expect(
        byAxis['opsz'],
        isNotNull,
        reason:
            'opsz defaults to 9 — the SMALL-text optical size. Leaving it '
            'unset renders a 57px heading with letterforms drawn for 9pt '
            'body copy, which is the opposite of why a variable serif was '
            'bundled.',
      );
    });

    test('optical size tracks font size across the scale', () {
      // The whole point of the axis: one family drawing a title and a label
      // as different shapes, not one outline scaled.
      double opsz(TextStyle? s) =>
          {for (final a in s!.fontVariations!) a.axis: a.value}['opsz']!;

      expect(opsz(resolved.displayLarge), BgeTypography.displayLarge);
      expect(opsz(resolved.titleSmall), BgeTypography.titleSmall);
      expect(
        opsz(resolved.displayLarge),
        greaterThan(opsz(resolved.titleSmall)),
      );
    });

    test('optical size stays inside the axis range', () {
      // Fraunces' opsz range is 9..144. A value outside it is undefined
      // behaviour in the shaper, and titleSmall (14) sits close to the floor.
      for (final style in [
        resolved.displayLarge,
        resolved.headlineSmall,
        resolved.titleSmall,
      ]) {
        final value = {
          for (final a in style!.fontVariations!) a.axis: a.value,
        }['opsz']!;
        expect(value, greaterThanOrEqualTo(BgeTypography.opszMin));
        expect(value, lessThanOrEqualTo(BgeTypography.opszMax));
      }
    });
  });

  group('BgeTheme palette seam', () {
    test('the default themes come from BgePalette.storm', () {
      expect(BgeTheme.light().colorScheme, BgePalette.storm.light);
      expect(BgeTheme.dark().colorScheme, BgePalette.storm.dark);
    });

    test('the default theme set is cached, not rebuilt per call', () {
      // The shell resolves `widget.theme ?? BgeTheme.light()` on every build.
      // A fresh ThemeData each time would hand MaterialApp a new theme
      // identity and spuriously repropagate Theme to the whole subtree.
      expect(identical(BgeTheme.light(), BgeTheme.light()), isTrue);
      expect(identical(BgeTheme.dark(), BgeTheme.dark()), isTrue);
      expect(
        identical(BgeTheme.highContrastDark(), BgeTheme.highContrastDark()),
        isTrue,
      );
    });

    test('from() themes an arbitrary palette', () {
      // The seam that makes user-selectable themes an added palette rather
      // than a rewrite of this layer.
      const swapped = BgePalette(
        name: 'test',
        light: BgeColorSchemes.dark,
        dark: BgeColorSchemes.light,
        highContrastLight: BgeColorSchemes.highContrastDark,
        highContrastDark: BgeColorSchemes.highContrastLight,
      );

      final themes = BgeTheme.from(swapped);

      expect(themes.light.colorScheme, BgeColorSchemes.dark);
      expect(themes.dark.colorScheme, BgeColorSchemes.light);
      // The accessibility baseline is applied to every palette, not just the
      // default — a custom palette must not be able to opt out of it.
      expect(themes.light.materialTapTargetSize, MaterialTapTargetSize.padded);
      expect(themes.light.visualDensity, VisualDensity.standard);
      expect(themes.light.extension<BgeTokens>(), same(BgeTokens.standard));
    });
  });
}
