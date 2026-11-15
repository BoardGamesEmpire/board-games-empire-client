import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:server_settings/src/widgets/contributions_settings_form.dart';
import 'package:server_settings/src/widgets/settings_group_binding.dart';
import 'package:ui/ui.dart';

import 'support/fake_system_settings_remote.dart';
import 'support/harness.dart';

const _invalidCopy = 'Enter a whole number of days from 1 to 36500.';

void main() {
  late List<SystemSettingsPatch> saves;

  setUp(() => saves = []);

  Future<void> pumpForm(WidgetTester tester, {bool maySave = true}) async {
    await pumpOnPage(
      tester,
      ContributionsSettingsForm(
        binding: SettingsGroupBinding(
          settings: settingsFixture(),
          revision: 1,
          maySave: maySave,
          saving: false,
          otherGroupSaving: false,
          onSave: saves.add,
          onEdited: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder reclaim() => find.byKey(ContributionsSettingsForm.reclaimFieldKey);

  EditableText reclaimField(WidgetTester tester) => tester.widget<EditableText>(
    find.descendant(of: reclaim(), matching: find.byType(EditableText)),
  );

  Future<void> tapKey(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  Future<void> enterReclaim(WidgetTester tester, String text) async {
    await tester.enterText(reclaim(), text);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) =>
      tapKey(tester, ContributionsSettingsForm.saveKey);

  testWidgets('shows the approval switch and the reclaim days', (tester) async {
    await pumpForm(tester);

    expect(
      find.text('Hold media contributions for staff approval'),
      findsOneWidget,
    );
    expect(
      find.text('A contribution is published only once staff approve it.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(ContributionsSettingsForm.approvalSwitchKey),
          )
          .value,
      isFalse,
    );
    expect(reclaimField(tester).controller.text, '14');
    expect(find.text('From 1 to 36500 days.'), findsOneWidget);
  });

  testWidgets('the approval switch is saved alone', (tester) async {
    await pumpForm(tester);
    await tapKey(tester, ContributionsSettingsForm.approvalSwitchKey);

    await save(tester);

    expect(saves, [
      const SystemSettingsPatch(requireContributionApproval: true),
    ]);
  });

  testWidgets('a changed reclaim count is saved', (tester) async {
    await pumpForm(tester);
    await enterReclaim(tester, '30');

    await save(tester);

    expect(saves, [const SystemSettingsPatch(contributionReclaimDays: 30)]);
  });

  testWidgets('Enter in the reclaim field saves', (tester) async {
    await pumpForm(tester);
    await enterReclaim(tester, '30');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(saves, [const SystemSettingsPatch(contributionReclaimDays: 30)]);
  });

  testWidgets('a reclaim count out of range is refused on the field', (
    tester,
  ) async {
    await pumpForm(tester);
    await enterReclaim(tester, '0');

    await save(tester);

    expect(find.text(_invalidCopy), findsOneWidget);
    expect(saves, isEmpty);
  });

  testWidgets('a role that may not save sees both read-only and no Save', (
    tester,
  ) async {
    await pumpForm(tester, maySave: false);

    expect(
      tester.widget<BgeSwitchField>(find.byType(BgeSwitchField)).readOnly,
      isTrue,
    );
    expect(reclaimField(tester).readOnly, isTrue);
    expect(find.byKey(ContributionsSettingsForm.saveKey), findsNothing);
  });
}
