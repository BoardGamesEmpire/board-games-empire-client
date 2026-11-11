import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

void main() {
  /// Hosts the region where `BgeApp` does: in `MaterialApp.builder`, above
  /// the Navigator. Under `home:` the Navigator's own Overlay would be an
  /// ancestor, so a region without its `Overlay.wrap` would still mount
  /// cleanly, and the no-throw case could not fail. Returns the child the
  /// builder handed the region.
  Future<Widget> pumpRegion(
    WidgetTester tester,
    TargetPlatform platform,
  ) async {
    late Widget hosted;
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light().copyWith(platform: platform),
        builder: (context, child) {
          hosted = child!;
          return BgeSelectionRegion(child: hosted);
        },
        home: const Text('Selectable prose here'),
      ),
    );
    return hosted;
  }

  group('BgeSelectionRegion (#322)', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      testWidgets('$platform mounts a selectable region under its own '
          'Overlay', (tester) async {
        await pumpRegion(tester, platform);

        expect(find.byType(SelectableRegion), findsOneWidget);
        // The region's own Overlay, not one that happens to sit above it:
        // `SelectableRegion` asserts an Overlay ancestor, and above the
        // Navigator nothing else supplies one.
        expect(
          find.ancestor(
            of: find.byType(SelectableRegion),
            matching: find.descendant(
              of: find.byType(BgeSelectionRegion),
              matching: find.byType(Overlay),
            ),
          ),
          findsOneWidget,
        );
      });
    }

    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    ]) {
      testWidgets('$platform renders the child directly', (tester) async {
        final hosted = await pumpRegion(tester, platform);

        expect(find.byType(SelectableRegion), findsNothing);
        final children = <Element>[];
        tester
            .element(find.byType(BgeSelectionRegion))
            .visitChildren(children.add);
        expect(
          children.single.widget,
          same(hosted),
          reason: 'a touch platform gets no region, and no Overlay either',
        );
      });
    }

    testWidgets('mounting on macOS throws nothing', (tester) async {
      // The regression the `Overlay.wrap` guards: a bare `SelectionArea`
      // above the Navigator fails `debugCheckHasOverlay` on its first build.
      await pumpRegion(tester, TargetPlatform.macOS);

      expect(tester.takeException(), isNull);
    });
  });
}
