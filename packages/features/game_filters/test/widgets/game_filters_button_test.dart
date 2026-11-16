import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_filters/game_filters.dart';

import '../support/game_filters_app.dart';

// The Filters button by itself: the name a screen reader gives it (#919).

void main() {
  Future<void> pumpButton(
    WidgetTester tester, {
    String? semanticsLabel,
  }) => tester.pumpWidget(
    gameFiltersApp(
      Scaffold(
        body: GameFiltersButton(
          count: 2,
          onPressed: () {},
          semanticsLabel: semanticsLabel,
        ),
      ),
    ),
  );

  testWidgets('with no semanticsLabel it is named by its text', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpButton(tester);

    expect(
      tester.getSemantics(find.byType(GameFiltersButton)),
      matchesSemantics(
        label: 'Filters (2)',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a semanticsLabel names it, and its text stays', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpButton(tester, semanticsLabel: 'Filters (2) for games');

    expect(
      tester.getSemantics(find.byType(GameFiltersButton)).label,
      'Filters (2) for games',
    );
    expect(find.text('Filters (2)'), findsOneWidget);
    handle.dispose();
  });
}
