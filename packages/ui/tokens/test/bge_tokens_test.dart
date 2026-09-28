import 'dart:io';

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
      expect(t.paneMaxWidth, 840);
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

    testWidgets('named constructors track the AMBIENT tokens, not constants', (
      tester,
    ) async {
      // The regression this guards: `BgeGap` used to store the value from
      // `BgeTokens.spaceMdValue` at construction, so a theme supplying
      // `copyWith(spaceMd: 20)` moved every EdgeInsets to 20 while every gap
      // stayed at 16. Two readers of one token must not be able to disagree.
      const customised = BgeTokens.standard;
      final widened = customised.copyWith(spaceMd: 20);

      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light().copyWith(extensions: [widened]),
          home: const Column(children: [BgeGap.md()]),
        ),
      );

      expect(tester.getSize(find.byType(BgeGap)).height, 20);
    });

    testWidgets('each step resolves its own token', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          home: const Column(
            children: [
              BgeGap.xs(),
              BgeGap.sm(),
              BgeGap.md(),
              BgeGap.lg(),
              BgeGap.xl(),
              BgeGap.xxl(),
            ],
          ),
        ),
      );

      const expected = [
        BgeTokens.spaceXsValue,
        BgeTokens.spaceSmValue,
        BgeTokens.spaceMdValue,
        BgeTokens.spaceLgValue,
        BgeTokens.spaceXlValue,
        BgeTokens.spaceXxlValue,
      ];
      final gaps = find.byType(BgeGap);
      for (var i = 0; i < expected.length; i++) {
        expect(tester.getSize(gaps.at(i)).height, expected[i]);
      }
    });
  });

  group('BgePageWidth.resolve', () {
    test('reads each measure from the tokens it is given', () {
      // Retuned away from `standard`, so a mapping hard-wired to
      // `BgeTokens.standard`, or one that swapped the two measures, fails.
      final tokens = BgeTokens.standard.copyWith(
        contentMaxWidth: 500,
        paneMaxWidth: 900,
      );

      expect(BgePageWidth.form.resolve(tokens), 500);
      expect(BgePageWidth.pane.resolve(tokens), 900);
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

  group('BgeTokens equality', () {
    test('an unchanged copy is equal, with an equal hashCode', () {
      final copy = BgeTokens.standard.copyWith();

      // A distinct instance, so what follows is structural equality and not
      // the identity a const `standard` would give for free.
      expect(copy, isNot(same(BgeTokens.standard)));
      expect(copy, BgeTokens.standard);
      expect(copy.hashCode, BgeTokens.standard.hashCode);
    });

    // One case per field (#212). A field left out of the equality comparison
    // fails its own case. A new field on `BgeTokens` needs a case here too,
    // and the test after the loop fails until it has one.
    const ms = Duration(milliseconds: 1);
    final changes = <String, BgeTokens Function(BgeTokens)>{
      'spaceXs': (t) => t.copyWith(spaceXs: t.spaceXs + 1),
      'spaceSm': (t) => t.copyWith(spaceSm: t.spaceSm + 1),
      'spaceMd': (t) => t.copyWith(spaceMd: t.spaceMd + 1),
      'spaceLg': (t) => t.copyWith(spaceLg: t.spaceLg + 1),
      'spaceXl': (t) => t.copyWith(spaceXl: t.spaceXl + 1),
      'spaceXxl': (t) => t.copyWith(spaceXxl: t.spaceXxl + 1),
      'radiusSm': (t) => t.copyWith(radiusSm: t.radiusSm + 1),
      'radiusMd': (t) => t.copyWith(radiusMd: t.radiusMd + 1),
      'radiusLg': (t) => t.copyWith(radiusLg: t.radiusLg + 1),
      'minTapTarget': (t) => t.copyWith(minTapTarget: t.minTapTarget + 1),
      'focusOutlineWidth': (t) =>
          t.copyWith(focusOutlineWidth: t.focusOutlineWidth + 1),
      'contentMaxWidth': (t) =>
          t.copyWith(contentMaxWidth: t.contentMaxWidth + 1),
      'paneMaxWidth': (t) => t.copyWith(paneMaxWidth: t.paneMaxWidth + 1),
      'breakpointMedium': (t) =>
          t.copyWith(breakpointMedium: t.breakpointMedium + 1),
      'breakpointExpanded': (t) =>
          t.copyWith(breakpointExpanded: t.breakpointExpanded + 1),
      'motionShort': (t) => t.copyWith(motionShort: t.motionShort + ms),
      'motionMedium': (t) => t.copyWith(motionMedium: t.motionMedium + ms),
      'motionLong': (t) => t.copyWith(motionLong: t.motionLong + ms),
    };

    for (final MapEntry(key: field, value: change) in changes.entries) {
      test('a copy with a different $field is unequal', () {
        expect(change(BgeTokens.standard), isNot(BgeTokens.standard));
      });
    }

    test('has a case for every field BgeTokens declares', () {
      // Read from the source rather than from another hand-kept list, so a
      // field missing from both `_fields` and the map above still fails.
      final source = File(
        '${Directory.current.path}/lib/src/bge_tokens.dart',
      ).readAsStringSync();
      final declared = RegExp(
        r'^  final \S+ (\w+)(?:;| =)',
        multiLine: true,
      ).allMatches(source).map((m) => m[1]!).toSet();

      expect(changes.keys.toSet(), declared);
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
