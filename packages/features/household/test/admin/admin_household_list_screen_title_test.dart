import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_admin_household_remote.dart';

/// The Households title on the smallest phone, beside everything its app bar
/// carries (#685).
///
/// A file of its own because it loads the display typeface, which then draws
/// every title in the file: measured in the test font, whose letters are each
/// an em wide, a title that fits a phone reads as cut.
void main() {
  setUpAll(loadDisplayFont);

  for (final scale in [1.0, 2.0]) {
    testWidgets('pushed on a 320dp screen at text scale $scale, the title is '
        'whole', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final remote = FakeAdminHouseholdRemote()..listing([adminRow('h_1')]);

      // Pushed, as the dashboard reaches it, so the app bar has a back
      // button.
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
          supportedLocales: HouseholdLocalizations.supportedLocales,
          home: const Scaffold(body: Text('dashboard')),
        ),
      );
      unawaited(
        Navigator.of(tester.element(find.text('dashboard'))).push(
          MaterialPageRoute<void>(
            builder: (_) => AdminHouseholdListScreen(remote: remote),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);

      final title = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Households'),
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
