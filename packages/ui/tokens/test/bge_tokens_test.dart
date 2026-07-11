import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

void main() {
  group('BgeTokens.standard', () {
    test('carries the documented values', () {
      const t = BgeTokens.standard;
      expect(t.spaceXs, 4);
      expect(t.spaceSm, 8);
      expect(t.spaceMd, 16);
      expect(t.spaceLg, 24);
      expect(t.spaceXl, 32);
      expect(t.spaceXxl, 48);
      expect(t.radiusSm, 4);
      expect(t.radiusMd, 12);
      expect(t.radiusLg, 16);
      expect(t.minTapTarget, 48);
      expect(t.focusOutlineWidth, 2);
      expect(t.motionShort, const Duration(milliseconds: 150));
      expect(t.motionMedium, const Duration(milliseconds: 300));
      expect(t.motionLong, const Duration(milliseconds: 500));
    });
  });

  group('BgeTokens.copyWith', () {
    test('replaces only the named field', () {
      final copy = BgeTokens.standard.copyWith(spaceMd: 20);
      expect(copy.spaceMd, 20);
      expect(copy.spaceSm, BgeTokens.standard.spaceSm);
      expect(copy.minTapTarget, BgeTokens.standard.minTapTarget);
      expect(copy.motionLong, BgeTokens.standard.motionLong);
    });
  });

  group('BgeTokens.lerp', () {
    test('interpolates doubles and durations at the midpoint', () {
      final other = BgeTokens.standard.copyWith(
        spaceMd: 32,
        motionShort: const Duration(milliseconds: 250),
      );

      final mid = BgeTokens.standard.lerp(other, 0.5);

      expect(mid.spaceMd, 24);
      expect(mid.motionShort, const Duration(milliseconds: 200));
      // Unchanged fields interpolate to themselves.
      expect(mid.radiusMd, BgeTokens.standard.radiusMd);
    });

    test('returns this when other is null', () {
      expect(BgeTokens.standard.lerp(null, 0.5), same(BgeTokens.standard));
    });
  });
}
