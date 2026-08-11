import 'package:flutter/material.dart';
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
      expect(t.contentMaxWidth, 480);
      expect(t.breakpointMedium, 600);
      expect(t.breakpointExpanded, 840);
      expect(t.motionShort, const Duration(milliseconds: 150));
      expect(t.motionMedium, const Duration(milliseconds: 300));
      expect(t.motionLong, const Duration(milliseconds: 500));
    });

    test('is built from the const scale primitives', () {
      // The primitives exist so `BgeGap`'s const constructors can reference
      // the scale (Dart forbids reading an instance field of a const object
      // in a constant expression). If these ever drift from `standard`, a gap
      // widget and a padding sourced from the same token would disagree.
      expect(BgeTokens.standard.spaceXs, BgeTokens.spaceXsValue);
      expect(BgeTokens.standard.spaceSm, BgeTokens.spaceSmValue);
      expect(BgeTokens.standard.spaceMd, BgeTokens.spaceMdValue);
      expect(BgeTokens.standard.spaceLg, BgeTokens.spaceLgValue);
      expect(BgeTokens.standard.spaceXl, BgeTokens.spaceXlValue);
      expect(BgeTokens.standard.spaceXxl, BgeTokens.spaceXxlValue);
    });
  });

  group('BgeTokens.of', () {
    testWidgets('returns the installed extension under a BgeTheme', (
      tester,
    ) async {
      late BgeTokens resolved;
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          home: Builder(
            builder: (context) {
              resolved = BgeTokens.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(resolved, same(BgeTokens.standard));
    });

    testWidgets('falls back to standard under a bare MaterialApp', (
      tester,
    ) async {
      // This is the property that lets a widget be tokenized without dragging
      // its whole test file along: feature widget tests pump a bare
      // MaterialApp, where the extension resolves to null.
      late BgeTokens resolved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              resolved = BgeTokens.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(resolved, same(BgeTokens.standard));
    });
  });

  group('BgeGap', () {
    testWidgets('constrains only its own axis', (tester) async {
      // A gap that sized both axes would force the cross-axis extent of its
      // parent — a square gap in a Column widens the Column to the gap.
      await tester.pumpWidget(
        const MaterialApp(
          home: Column(
            children: [
              BgeGap.md(),
              BgeGap.sm(axis: Axis.horizontal),
            ],
          ),
        ),
      );

      final vertical = tester.getSize(find.byType(BgeGap).first);
      expect(vertical.height, BgeTokens.spaceMdValue);
      expect(vertical.width, 0);

      final horizontal = tester.getSize(find.byType(BgeGap).last);
      expect(horizontal.width, BgeTokens.spaceSmValue);
      expect(horizontal.height, 0);
    });

    test('named constructors match the spacing scale', () {
      expect(const BgeGap.xs().extent, BgeTokens.spaceXsValue);
      expect(const BgeGap.sm().extent, BgeTokens.spaceSmValue);
      expect(const BgeGap.md().extent, BgeTokens.spaceMdValue);
      expect(const BgeGap.lg().extent, BgeTokens.spaceLgValue);
      expect(const BgeGap.xl().extent, BgeTokens.spaceXlValue);
      expect(const BgeGap.xxl().extent, BgeTokens.spaceXxlValue);
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
