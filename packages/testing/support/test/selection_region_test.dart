import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

void main() {
  const prose = 'Selectable prose here';

  group('hostUnderSelectionRegion (#338)', () {
    testWidgets('hosts the screen under the region, above the Navigator, as '
        'BgeApp does', (tester) async {
      await tester.pumpWidget(
        hostUnderSelectionRegion(tester, const Center(child: Text(prose))),
      );

      expect(find.byType(SelectableRegion), findsOneWidget);
      // In the builder slot, not under `home:`. Below the Navigator its
      // Overlay would hide a region that had lost its own.
      expect(
        find.ancestor(
          of: find.byType(Navigator),
          matching: find.byType(BgeSelectionRegion),
        ),
        findsOneWidget,
      );
      expect(
        Theme.of(tester.element(find.text(prose))).platform,
        TargetPlatform.macOS,
      );
      expect(tester.view.physicalSize, const Size(1280, 800));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a mouse drag selects, and the copy shortcut lifts the text', (
      tester,
    ) async {
      final copies = captureClipboardCopies();
      await tester.pumpWidget(
        hostUnderSelectionRegion(tester, const Center(child: Text(prose))),
      );

      final box = tester.getRect(find.text(prose));
      await mouseDrag(
        tester,
        Offset(box.left + 1, box.center.dy),
        Offset(box.right - 1, box.center.dy),
      );
      await sendCopyShortcut(tester);

      expect(copies, hasLength(1));
      expect(copies.single, isNotEmpty);
      expect(
        prose,
        contains(copies.single),
        reason:
            'the clipboard should hold part of the text that was dragged '
            'across, but held "${copies.single}"',
      );
    });
  });

  group('mouseDrag (#338)', () {
    testWidgets('scrolls a mouse-draggable scroller under the region', (
      tester,
    ) async {
      // The scroller has to win the gesture arena against the region's own
      // drag recognizer, and the move that decides it only starts the drag.
      // A drag that jumps in one move scrolls nothing here, though it is
      // enough to select text.
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        hostUnderSelectionRegion(
          tester,
          ScrollConfiguration(
            behavior: const MaterialScrollBehavior().copyWith(
              dragDevices: {PointerDeviceKind.mouse, PointerDeviceKind.touch},
            ),
            child: SingleChildScrollView(
              controller: controller,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < 12; i++)
                    SizedBox(width: 200, child: Text('Tile $i')),
                ],
              ),
            ),
          ),
        ),
      );

      final centre = tester.getCenter(find.byType(SingleChildScrollView));
      await mouseDrag(tester, centre, centre - const Offset(300, 0));

      expect(controller.position.pixels, greaterThan(0));
    });
  });

  group('pointerPlatformTheme (#338)', () {
    test('is the design system theme, on macOS unless told otherwise', () {
      expect(pointerPlatformTheme().platform, TargetPlatform.macOS);
      expect(pointerPlatformTheme().extension<BgeTokens>(), isNotNull);
      expect(
        pointerPlatformTheme(platform: TargetPlatform.windows).platform,
        TargetPlatform.windows,
      );
    });
  });
}
