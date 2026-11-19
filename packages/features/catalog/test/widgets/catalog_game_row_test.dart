import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
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
}
