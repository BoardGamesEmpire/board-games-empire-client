import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/scheme_surfaces.dart';

/// The authored on-role/role pairs the contrast guarantee covers.
Map<String, (Color foreground, Color background)> _authoredPairs(
  ColorScheme s,
) => {
  'onPrimary/primary': (s.onPrimary, s.primary),
  'onPrimaryContainer/primaryContainer': (
    s.onPrimaryContainer,
    s.primaryContainer,
  ),
  'onSecondary/secondary': (s.onSecondary, s.secondary),
  'onSecondaryContainer/secondaryContainer': (
    s.onSecondaryContainer,
    s.secondaryContainer,
  ),
  'onTertiary/tertiary': (s.onTertiary, s.tertiary),
  'onTertiaryContainer/tertiaryContainer': (
    s.onTertiaryContainer,
    s.tertiaryContainer,
  ),
  'onError/error': (s.onError, s.error),
  'onErrorContainer/errorContainer': (s.onErrorContainer, s.errorContainer),
  'onSurface/surface': (s.onSurface, s.surface),
  'onSurfaceVariant/surface': (s.onSurfaceVariant, s.surface),
  'onInverseSurface/inverseSurface': (s.onInverseSurface, s.inverseSurface),
};

void _expectContrast(ColorScheme scheme, {required double minimum}) {
  for (final entry in _authoredPairs(scheme).entries) {
    final (foreground, background) = entry.value;
    final ratio = Wcag.contrastRatio(foreground, background);
    expect(
      ratio,
      greaterThanOrEqualTo(minimum),
      reason:
          '${entry.key} contrast is ${ratio.toStringAsFixed(2)}:1, '
          'below the required $minimum:1',
    );
  }
}

void _expectSurfaceFamilyContrast(
  ColorScheme scheme, {
  required double minimum,
}) {
  for (final (name, background) in surfaceFamily(scheme)) {
    for (final (fgName, foreground) in bodyTextRoles(scheme)) {
      final ratio = Wcag.contrastRatio(foreground, background);
      expect(
        ratio,
        greaterThanOrEqualTo(minimum),
        reason:
            '$fgName on $name is ${ratio.toStringAsFixed(2)}:1, '
            'below the required $minimum:1',
      );
    }
  }
}

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

  group('BgeColorSchemes contrast (WCAG 2.1)', () {
    test('light: every authored pair ≥ ${Wcag.aaNormalText}:1 (AA)', () {
      _expectContrast(BgeColorSchemes.light, minimum: Wcag.aaNormalText);
    });

    test('dark: every authored pair ≥ ${Wcag.aaNormalText}:1 (AA)', () {
      _expectContrast(BgeColorSchemes.dark, minimum: Wcag.aaNormalText);
    });

    test(
      'highContrastLight: every authored pair ≥ ${Wcag.aaaNormalText}:1',
      () {
        _expectContrast(
          BgeColorSchemes.highContrastLight,
          minimum: Wcag.aaaNormalText,
        );
      },
    );

    test('highContrastDark: every authored pair ≥ ${Wcag.aaaNormalText}:1', () {
      _expectContrast(
        BgeColorSchemes.highContrastDark,
        minimum: Wcag.aaaNormalText,
      );
    });
  });

  group('BgeColorSchemes surface family', () {
    for (final entry in schemes.entries) {
      final (scheme, minimum) = entry.value;
      test('${entry.key}: body text is legible on every surface role', () {
        _expectSurfaceFamilyContrast(scheme, minimum: minimum);
      });
    }
  });

  group('BgeColorSchemes hue separation', () {
    // Contrast answers "can this be read?", never "can these be told apart?".
    // Ember and crimson can sit at the same luminance, pass every assertion
    // above, and still be indistinguishable — which is exactly what the first
    // draft of this palette did at 43° apart.
    for (final entry in schemes.entries) {
      final (scheme, _) = entry.value;
      test('${entry.key}: tertiary (ember) is distinguishable from error', () {
        final degrees = Oklch.separation(scheme.tertiary, scheme.error);
        expect(
          degrees,
          greaterThanOrEqualTo(Oklch.minAccentSeparation),
          reason:
              'tertiary and error are only ${degrees.toStringAsFixed(1)}° '
              'apart in OKLCH hue; both are warm and mid-luminance, so below '
              '${Oklch.minAccentSeparation}° they read as the same colour and '
              'an ember "pending" badge starts looking like an error.',
        );
      });
    }
  });

  group('BgeColorSchemes brightness', () {
    test('light variants report Brightness.light', () {
      expect(BgeColorSchemes.light.brightness, Brightness.light);
      expect(BgeColorSchemes.highContrastLight.brightness, Brightness.light);
    });

    test('dark variants report Brightness.dark', () {
      expect(BgeColorSchemes.dark.brightness, Brightness.dark);
      expect(BgeColorSchemes.highContrastDark.brightness, Brightness.dark);
    });
  });
}
