import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/src/widgets/catalog_game_row.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/catalog_app.dart';

void main() {
  for (final scale in [1.0, 1.3]) {
    testWidgets('a row with a title alone holds its thumbnail inside its '
        'outline at text scale $scale (#647)', (tester) async {
      useViewSize(tester, const Size(390, 640));
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(
        catalogApp(const Scaffold(body: CatalogGameRow(title: 'Wingspan'))),
      );

      final row = find.byType(CatalogGameRow);
      // The outline's own box: the padding around it holds the gap below.
      final outline = tester.getRect(
        find
            .descendant(
              of: find.byType(BgeOutlinedRow),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final thumbnail = tester.getRect(
        find.descendant(of: row, matching: find.byType(BgeThumbnail)),
      );

      expect(thumbnail.top, greaterThan(outline.top), reason: '$thumbnail');
      expect(thumbnail.bottom, lessThan(outline.bottom), reason: '$thumbnail');
      expect(
        outline.height,
        BgeThumbnail.listExtent + 2 * BgeTokens.standard.spaceSm,
      );
    });
  }

  testWidgets('a focused row is ringed (#758)', (tester) async {
    await tester.pumpWidget(
      catalogApp(
        Scaffold(
          body: CatalogGameRow(title: 'Wingspan', onTap: () {}),
        ),
      ),
    );

    expect(
      await keyboardFocusShowsRing(tester, find.text('Wingspan')),
      isTrue,
    );
  });

  group('focus from a tap (#1038)', () {
    /// The row's tile node: the nearest focus above its title.
    FocusNode tileNode(WidgetTester tester) =>
        Focus.of(tester.element(find.text('Wingspan')));

    /// Whether the ring around the row is drawn.
    bool ringDrawn(WidgetTester tester) {
      final ring = find.ancestor(
        of: find.text('Wingspan'),
        matching: find.byType(BgeFocusRing),
      );
      final drawn = tester.widget<DecoratedBox>(
        find.descendant(of: ring, matching: find.byType(DecoratedBox)).first,
      );
      return (drawn.decoration as BoxDecoration).border != null;
    }

    testWidgets("a screen reader's tap focuses the row before its onTap runs", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      FocusNode? focusedWhenTapped;
      await tester.pumpWidget(
        catalogApp(
          Scaffold(
            body: CatalogGameRow(
              title: 'Wingspan',
              onTap: () =>
                  focusedWhenTapped = FocusManager.instance.primaryFocus,
            ),
          ),
        ),
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      tester.semantics.tap(find.semantics.byLabel('Wingspan'));
      await tester.pump();

      expect(focusedWhenTapped, isNotNull);
      expect(focusedWhenTapped, same(tileNode(tester)));
      expect(tileNode(tester).hasPrimaryFocus, isTrue);
      handle.dispose();
    });

    testWidgets(
      'a mouse click on macOS focuses the row with no ring, and the next key '
      'press shows it',
      (tester) async {
        await tester.pumpWidget(
          catalogApp(
            Scaffold(
              body: CatalogGameRow(title: 'Wingspan', onTap: () {}),
            ),
          ),
        );
        final row = tester.getCenter(find.byType(CatalogGameRow));
        const away = Offset(4, 590);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: away);
        addTearDown(mouse.removePointer);

        await mouse.moveTo(row);
        await mouse.down(row);
        await tester.pump(const Duration(milliseconds: 50));
        await mouse.up();
        await mouse.moveTo(away);
        await tester.pumpAndSettle();

        expect(tileNode(tester).hasPrimaryFocus, isTrue);
        expect(
          FocusManager.instance.highlightMode,
          FocusHighlightMode.traditional,
        );
        expect(ringDrawn(tester), isFalse, reason: 'clicked');

        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(ringDrawn(tester), isTrue, reason: 'a key press');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets('a row with no onTap takes no focus from Tab or a tap', (
      tester,
    ) async {
      await tester.pumpWidget(
        catalogApp(
          const Scaffold(body: CatalogGameRow(title: 'Wingspan')),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(tileNode(tester).hasFocus, isFalse, reason: 'Tab');

      await tester.tap(find.text('Wingspan'));
      await tester.pump();
      expect(tileNode(tester).hasFocus, isFalse, reason: 'a tap');
    });
  });
}
