import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_household_invite_remote.dart';
import '../support/invite_filter_menu_support.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

/// The household invites' filter on the smallest phone, in the face it is
/// drawn in (#475): its label and its choices wrap between words, never
/// inside one.
///
/// A file of its own because it loads Roboto, which then draws every label
/// in the file.
void main() {
  setUpAll(loadPlatformLabelFont);

  for (final scale in [1.0, BgeTextScale.maxScaleFactor]) {
    testWidgets('on a 320dp screen at text scale $scale, the filter keeps '
        'its words whole', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final remote = FakeHouseholdInviteRemote()..listing(const []);
      final repository = _MockHouseholdRepository();
      when(
        () => repository.getCurrentUserMember(any()),
      ).thenAnswer((_) async => null);
      when(
        () => repository.watchMembers(any()),
      ).thenAnswer((_) => const Stream.empty());

      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
          supportedLocales: HouseholdLocalizations.supportedLocales,
          home: HouseholdInviteListScreen(
            householdId: 'hh_1',
            remote: remote,
            repository: repository,
            initialFilter: HouseholdInviteFilter.awaitingApproval,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = find.byKey(HouseholdInviteListScreen.filterKey);
      final label = find.descendant(
        of: button,
        matching: find.text('Show: Awaiting approval'),
      );
      expect(
        MediaQuery.textScalerOf(tester.element(label)).scale(10),
        10 * scale,
        reason: 'the filter is drawn at the scale under test',
      );
      expectWholeWords(tester, label);

      await tester.tap(button);
      await tester.pumpAndSettle();
      for (final choice in ['Open', 'Awaiting approval', 'Declined']) {
        expectWholeWords(
          tester,
          find.descendant(
            of: find.widgetWithText(MenuItemButton, choice),
            matching: find.text(choice),
          ),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
