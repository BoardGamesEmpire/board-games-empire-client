import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:server_settings/src/widgets/general_settings_form.dart';
import 'package:server_settings/src/widgets/settings_group_binding.dart';
import 'package:ui/ui.dart';

import 'support/fake_system_settings_remote.dart';
import 'support/harness.dart';

const _emptyCopy = 'Enter a name for the server.';
const _tooLongCopy = 'Use at most 100 characters.';

void main() {
  late List<SystemSettingsPatch> saves;

  setUp(() => saves = []);

  Future<void> pumpForm(
    WidgetTester tester, {
    bool maySave = true,
    SystemSettings? settings,
    int revision = 1,
  }) async {
    await pumpOnPage(
      tester,
      GeneralSettingsForm(
        binding: SettingsGroupBinding(
          settings: settings ?? settingsFixture(),
          revision: revision,
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

  Finder nameFinder() => find.byKey(GeneralSettingsForm.nameFieldKey);

  EditableText nameField(WidgetTester tester) => tester.widget<EditableText>(
    find.descendant(of: nameFinder(), matching: find.byType(EditableText)),
  );

  Future<void> enterName(WidgetTester tester, String text) async {
    await tester.enterText(nameFinder(), text);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(GeneralSettingsForm.saveKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(GeneralSettingsForm.saveKey));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the server name', (tester) async {
    await pumpForm(tester);

    expect(nameField(tester).controller.text, 'Board Games Empire');
    expect(find.text('Server name'), findsOneWidget);
    expect(
      find.text('People see this name when they choose which server to add.'),
      findsOneWidget,
    );
  });

  testWidgets('a padded name is sent trimmed', (tester) async {
    await pumpForm(tester);
    await enterName(tester, '  Home  ');

    await save(tester);

    expect(saves, [const SystemSettingsPatch(name: 'Home')]);
  });

  testWidgets('a name differing only by padding sends nothing', (tester) async {
    await pumpForm(tester);
    await enterName(tester, '  Board Games Empire ');

    await save(tester);

    expect(saves, [const SystemSettingsPatch()]);
  });

  testWidgets('a stored name with padding shows trimmed and is no edit', (
    tester,
  ) async {
    final padded = settingsFixture(name: '  Board Games Empire ');
    await pumpForm(tester, settings: padded);

    expect(nameField(tester).controller.text, 'Board Games Empire');
    await save(tester);
    expect(saves, [const SystemSettingsPatch()]);

    // Nothing unsaved, so another group's save hands it newer values.
    await pumpForm(
      tester,
      settings: settingsFixture(name: 'Game Night'),
      revision: 2,
    );
    expect(nameField(tester).controller.text, 'Game Night');
  });

  testWidgets('a blank name is refused on the field', (tester) async {
    await pumpForm(tester);
    await enterName(tester, '   ');

    await save(tester);

    expect(find.text(_emptyCopy), findsOneWidget);
    expect(saves, isEmpty);
  });

  testWidgets('a name longer than 100 is refused on the field', (
    tester,
  ) async {
    await pumpForm(tester);
    await enterName(tester, 'a' * 101);

    await save(tester);

    expect(find.text(_tooLongCopy), findsOneWidget);
    expect(saves, isEmpty);
  });

  testWidgets('a name of exactly 100 is saved', (tester) async {
    await pumpForm(tester);
    await enterName(tester, 'a' * 100);

    await save(tester);

    expect(find.text(_tooLongCopy), findsNothing);
    expect(saves, [SystemSettingsPatch(name: 'a' * 100)]);
  });

  testWidgets("the length is counted the server's way: 100 emoji are saved", (
    tester,
  ) async {
    final name = '\u{1F3B2}' * 100;
    await pumpForm(tester);
    await enterName(tester, name);

    await save(tester);

    expect(find.text(_tooLongCopy), findsNothing);
    expect(saves, [SystemSettingsPatch(name: name)]);
  });

  testWidgets('Enter in the name field saves', (tester) async {
    await pumpForm(tester);
    await enterName(tester, 'Home');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(saves, [const SystemSettingsPatch(name: 'Home')]);
  });

  testWidgets('a role that may not save sees the name read-only and no Save', (
    tester,
  ) async {
    await pumpForm(tester, maySave: false);

    expect(nameField(tester).readOnly, isTrue);
    expect(find.byKey(GeneralSettingsForm.saveKey), findsNothing);
    expect(find.byType(BgeTextField), findsOneWidget);
  });
}
