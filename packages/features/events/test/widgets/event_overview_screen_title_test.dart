import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

class _MockEventRepository extends Mock implements EventRepository {}

/// The Events title on the smallest phone, beside the menu button and the
/// control the app adds at the end of the header (#475).
///
/// A file of its own because it loads the display typeface, which then draws
/// every title in the file: measured in the test font, whose letters are each
/// an em wide, a title that fits a phone reads as cut.
void main() {
  setUpAll(loadDisplayFont);

  for (final scale in [1.0, 2.0]) {
    testWidgets('on a 320dp screen at text scale $scale, the title is whole '
        'beside the header action', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      const action = Key('header_action');
      final repository = _MockEventRepository();
      when(repository.watchAttendingEventListItems)
          .thenAnswer((_) => Stream.value(const []));

      // Under the shell's menu hook, as the app has it, so the app bar has
      // the menu button at the start.
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates: EventsLocalizations.localizationsDelegates,
          supportedLocales: EventsLocalizations.supportedLocales,
          home: BgeNavigationMenu(
            onOpen: () {},
            child: EventOverviewScreen(
              repository: repository,
              headerAction: const SizedBox(key: action, width: 48, height: 48),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(BgePage.menuButtonKey), findsOneWidget);
      expect(find.byKey(action), findsOneWidget);

      final title = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.byType(AppBar), matching: find.text('Events')),
      );
      expect(
        title.getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(title.size.width + 0.5),
        reason: 'the title has ${title.size.width}dp',
      );
    });
  }
}
