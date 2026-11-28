import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_household_invite_remote.dart';
import '../support/invite_filter_menu_support.dart';

/// The sent invites' filter on the smallest phone, in the face it is drawn
/// in (#475): its label and its choices wrap between words, never inside
/// one.
///
/// A file of its own because it loads Roboto, which then draws every label
/// in the file.
void main() {
  setUpAll(loadPlatformLabelFont);

  const choices = [
    'Open and expired',
    'Pending',
    'Awaiting approval',
    'Expired',
    'Accepted',
    'Declined',
    'Withdrawn',
    'Revoked',
  ];

  for (final scale in [1.0, BgeTextScale.maxScaleFactor]) {
    testWidgets('on a 320dp screen at text scale $scale, the filter keeps '
        'its words whole', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final remote = FakeHouseholdInviteRemote()
        ..onFetchSent = (_, _, _) async => pageOf(const []);

      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
          supportedLocales: HouseholdLocalizations.supportedLocales,
          home: SentInvitesScreen(remote: remote),
        ),
      );
      await tester.pumpAndSettle();

      final button = find.byKey(SentInvitesScreen.filterKey);
      final label = find.descendant(
        of: button,
        matching: find.text('Show: Open and expired'),
      );
      expect(
        MediaQuery.textScalerOf(tester.element(label)).scale(10),
        10 * scale,
        reason: 'the filter is drawn at the scale under test',
      );
      expectWholeWords(tester, label);

      await tester.tap(button);
      await tester.pumpAndSettle();
      for (final choice in choices) {
        final item = find.widgetWithText(MenuItemButton, choice);
        await tester.ensureVisible(item);
        await tester.pumpAndSettle();
        expectWholeWords(
          tester,
          find.descendant(of: item, matching: find.text(choice)),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
