import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_filters/game_filters.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Every part the sheet can offer, on.
const everyOption = GameFilterOptions(
  medium: true,
  missingBaseGame: true,
  exclusion: true,
);

/// [home] inside an app carrying this package's localizations and the
/// design system's theme, light unless [theme] says otherwise.
Widget gameFiltersApp(Widget home, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? BgeTheme.light(),
  localizationsDelegates: GameFiltersLocalizations.localizationsDelegates,
  supportedLocales: GameFiltersLocalizations.supportedLocales,
  home: home,
);

/// The button the test opens the sheet from.
const openSheetKey = Key('test.open_filter_sheet');

/// Pumps a page whose one button opens the filter sheet on [initial] with
/// [options], presses it, and waits for the sheet to finish opening.
///
/// With [nested], the page is on a navigator nested in the root one, as a
/// page under the navigation shell is (#414), inside a [ScaffoldMessenger]
/// of its own: a SnackBar sent to the root's messenger has no Scaffold to
/// show in.
///
/// Returns the list each filter the sheet sends is added to, in order.
Future<List<CollectionFilter>> openFilterSheet(
  WidgetTester tester, {
  CollectionFilter initial = const CollectionFilter(),
  GameFilterOptions options = const GameFilterOptions(),
  ThemeData? theme,
  bool nested = false,
}) async {
  final sent = <CollectionFilter>[];
  final page = Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        key: openSheetKey,
        onPressed: () => showGameFilterSheet(
          context,
          initial: initial,
          options: options,
          onChanged: sent.add,
        ),
        child: const Text('Open'),
      ),
    ),
  );
  await tester.pumpWidget(
    gameFiltersApp(
      theme: theme,
      nested
          ? ScaffoldMessenger(
              child: Navigator(
                onGenerateRoute: (_) =>
                    MaterialPageRoute<void>(builder: (_) => page),
              ),
            )
          : page,
    ),
  );
  await tester.tap(find.byKey(openSheetKey));
  await tester.pumpAndSettle();
  return sent;
}

/// Brings [finder], in the open sheet, on screen, taps it, and waits for
/// what the tap set off.
Future<void> tapInSheet(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// A window 320dp wide and 640dp tall, with text at twice its size: where a
/// layout breaks first (docs/design/STYLE_GUIDE.md).
void useNarrowWindowAndLargeText(WidgetTester tester) {
  useViewSize(tester, const Size(320, 640));
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}
