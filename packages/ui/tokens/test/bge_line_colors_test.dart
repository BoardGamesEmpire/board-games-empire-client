import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'support/declared_fields.dart';

void main() {
  group('BgeLineColors derivation', () {
    const scheme = BgeColorSchemes.light;

    test('forScheme maps separator to outline, and rowOutline to '
        'outlineVariant, or outline in high contrast', () {
      final normal = BgeLineColors.forScheme(scheme, highContrast: false);
      expect(normal.separator, scheme.outline);
      expect(normal.rowOutline, scheme.outlineVariant);

      final high = BgeLineColors.forScheme(scheme, highContrast: true);
      expect(high.separator, scheme.outline);
      expect(high.rowOutline, scheme.outline);
    });
  });

  group('BgeLineColors equality', () {
    final base = BgeLineColors.forScheme(
      BgeColorSchemes.light,
      highContrast: false,
    );

    test('a set derived again from the same scheme is equal, with an equal '
        'hashCode', () {
      final again = BgeLineColors.forScheme(
        BgeColorSchemes.light,
        highContrast: false,
      );

      expect(again, isNot(same(base)));
      expect(again, base);
      expect(again.hashCode, base.hashCode);
    });

    Color shifted(Color c) => c.withValues(alpha: c.a / 2);
    final changes = <String, BgeLineColors Function(BgeLineColors)>{
      'separator': (s) => s.copyWith(separator: shifted(s.separator)),
      'rowOutline': (s) => s.copyWith(rowOutline: shifted(s.rowOutline)),
    };

    for (final MapEntry(key: field, value: change) in changes.entries) {
      test('a copy with a different $field is unequal', () {
        expect(change(base), isNot(base));
      });
    }

    test('has a case for every field BgeLineColors declares', () {
      expect(changes.keys.toSet(), declaredFields('bge_line_colors.dart'));
    });
  });
}
