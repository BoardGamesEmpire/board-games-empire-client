import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'support/declared_fields.dart';

void main() {
  group('BgeStatusColors equality', () {
    final base = BgeStatusColors.forScheme(BgeColorSchemes.light);

    test('a set derived again from the same scheme is equal, with an equal '
        'hashCode', () {
      final again = BgeStatusColors.forScheme(BgeColorSchemes.light);

      // A distinct instance, so what follows is structural equality and not
      // identity.
      expect(again, isNot(same(base)));
      expect(again, base);
      expect(again.hashCode, base.hashCode);
    });

    // One case per field, as for `BgeTokens` (#212). A field left out of the
    // equality comparison fails its own case, and a new field with no case
    // fails the test after the loop.
    Color shifted(Color c) => c.withValues(alpha: c.a / 2);
    final changes = <String, BgeStatusColors Function(BgeStatusColors)>{
      'synced': (s) => s.copyWith(synced: shifted(s.synced)),
      'pending': (s) => s.copyWith(pending: shifted(s.pending)),
      'offline': (s) => s.copyWith(offline: shifted(s.offline)),
      'conflict': (s) => s.copyWith(conflict: shifted(s.conflict)),
      'onStatus': (s) => s.copyWith(onStatus: shifted(s.onStatus)),
    };

    for (final MapEntry(key: field, value: change) in changes.entries) {
      test('a copy with a different $field is unequal', () {
        expect(change(base), isNot(base));
      });
    }

    test('has a case for every field BgeStatusColors declares', () {
      expect(changes.keys.toSet(), declaredFields('bge_status_colors.dart'));
    });
  });
}
