import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/src/banners/refresh_spinner.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const ValueKey<String> _key = ValueKey('refresh');

Widget _host({required bool refreshing, required VoidCallback onPressed}) =>
    MaterialApp(
      theme: BgeTheme.light(),
      home: Scaffold(
        appBar: AppBar(
          actions: [
            BgeRefreshButton(
              label: 'Refresh',
              inProgressLabel: 'Refreshing…',
              refreshing: refreshing,
              onPressed: onPressed,
              buttonKey: _key,
            ),
          ],
        ),
      ),
    );

FocusNode _focus(WidgetTester tester) =>
    tester.widget<IconButton>(find.byKey(_key)).focusNode!;

void main() {
  testWidgets('at rest it is a refresh icon named by label', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(refreshing: false, onPressed: () {}));

    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(BgeRefreshButton)),
      matchesSemantics(
        label: 'Refresh',
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('refreshing swaps the icon for the spinner and the label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(refreshing: true, onPressed: () {}));

    expect(find.byType(RefreshSpinner), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(
      tester.getSemantics(find.byType(BgeRefreshButton)),
      matchesSemantics(
        label: 'Refreshing…',
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a press while refreshing does nothing', (tester) async {
    var presses = 0;
    await tester.pumpWidget(
      _host(refreshing: true, onPressed: () => presses++),
    );

    await tester.tap(find.byKey(_key));
    _focus(tester).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(presses, 0);

    await tester.pumpWidget(
      _host(refreshing: false, onPressed: () => presses++),
    );
    await tester.tap(find.byKey(_key));
    expect(presses, 1);
  });

  testWidgets('the button keeps focus when refreshing flips', (tester) async {
    await tester.pumpWidget(_host(refreshing: false, onPressed: () {}));
    _focus(tester).requestFocus();
    await tester.pump();
    final node = FocusManager.instance.primaryFocus;
    expect(node, same(_focus(tester)));

    await tester.pumpWidget(_host(refreshing: true, onPressed: () {}));
    expect(FocusManager.instance.primaryFocus, same(node));
    expect(_focus(tester), same(node));

    await tester.pumpWidget(_host(refreshing: false, onPressed: () {}));
    expect(FocusManager.instance.primaryFocus, same(node));
    expect(_focus(tester), same(node));
  });

  testWidgets('the tooltip follows the label', (tester) async {
    await tester.pumpWidget(_host(refreshing: false, onPressed: () {}));
    expect(find.byTooltip('Refresh'), findsOneWidget);

    await tester.pumpWidget(_host(refreshing: true, onPressed: () {}));
    expect(find.byTooltip('Refreshing…'), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsNothing);
  });

  // The spinner fills the icon's slot, so the button keeps its footprint and
  // the app bar title doesn't move while a pass runs.
  for (final scale in [1.0, 2.0]) {
    testWidgets('the spinner takes the icon slot at text scale $scale', (
      tester,
    ) async {
      Widget scaled({required bool refreshing}) => MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: _host(refreshing: refreshing, onPressed: () {}),
      );

      await tester.pumpWidget(scaled(refreshing: false));
      final button = tester.getSize(find.byKey(_key));
      final icon = tester.getSize(find.byIcon(Icons.refresh));

      await tester.pumpWidget(scaled(refreshing: true));
      expect(tester.getSize(find.byType(RefreshSpinner)), icon);
      expect(tester.getSize(find.byKey(_key)), button);
    });
  }
}
