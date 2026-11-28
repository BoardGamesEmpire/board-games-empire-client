import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:notifications/notifications.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_notification_remote.dart';

/// The Notifications title on the smallest phone, beside everything else its
/// app bar carries: the back button, and the refresh button (#475).
///
/// A file of its own because it loads the display typeface, which then draws
/// every title in the file: measured in the test font, whose letters are each
/// an em wide, a title that fits a phone reads as cut.
void main() {
  setUpAll(loadDisplayFont);

  for (final scale in [1.0, 2.0]) {
    testWidgets('title fits at 320dp at $scale text, pushed', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final remote = FakeNotificationRemote()
        ..scriptPages([const NotificationPage(items: [])]);

      // Pushed, as the app reaches it, so the app bar has a back button.
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates:
              NotificationsLocalizations.localizationsDelegates,
          supportedLocales: NotificationsLocalizations.supportedLocales,
          home: const Scaffold(body: Text('home')),
        ),
      );
      Navigator.of(tester.element(find.text('home'))).push(
        MaterialPageRoute<void>(
          builder: (_) => NotificationsScreen(
            remote: remote,
            onOpen: (_, _) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byKey(NotificationsScreen.refreshKey), findsOneWidget);

      final title = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Notifications'),
        ),
      );
      expect(
        title.getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(title.size.width + 0.5),
        reason: 'the title has ${title.size.width}dp',
      );
    });
  }
}
