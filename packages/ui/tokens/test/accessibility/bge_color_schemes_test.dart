import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

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

void main() {
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
