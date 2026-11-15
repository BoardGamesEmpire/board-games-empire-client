import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/src/widgets/settings_group_binding.dart';
import 'package:server_settings/src/widgets/settings_group_form.dart';
import 'package:ui/ui.dart';

import 'support/fake_system_settings_remote.dart';
import 'support/harness.dart';

const _open = 'open';
const _name = 'name';

const _openKey = Key('test_group.open');
const _nameKey = Key('test_group.name');
const _saveKey = Key('test_group.save');

const _saveCopy = 'Save test settings';
const _savedCopy = 'Test settings saved.';
const _emptyCopy = 'Enter a name.';
const _storedName = 'Board Games Empire';

const _labels = SettingsGroupLabels(
  saveKey: _saveKey,
  saveLabel: _saveCopy,
  savingLabel: 'Saving…',
  savedKey: Key('test_group.saved'),
  savedMessage: _savedCopy,
  failureKey: Key('test_group.failure'),
  failureTitle: 'Test settings not saved',
);

/// A group of two: a switch, then a text field that must not be empty.
FormGroup _buildForm(Map<String, Object?> values) => FormGroup({
  _open: FormControl<bool>(value: values[_open] as bool?),
  _name: FormControl<String>(
    value: values[_name] as String?,
    validators: [Validators.required],
  ),
});

Map<String, Object?> _valuesOf(SystemSettings settings) => {
  _open: settings.allowUserRegistration,
  _name: settings.name,
};

/// Refuses an invalid form: the form asks only of a valid one.
SystemSettingsPatch _patchOf(SystemSettings base, FormGroup form) {
  if (!form.valid) throw StateError('A patch of an invalid form');
  final open = form.control(_open).value as bool;
  final name = form.control(_name).value as String;
  return SystemSettingsPatch(
    allowUserRegistration: open == base.allowUserRegistration ? null : open,
    name: name == base.name ? null : name,
  );
}

void main() {
  late List<SystemSettingsPatch> saves;
  late int edits;
  late List<bool> readOnlyBuilt;

  /// What `ReactiveForm.of` found from the fields' context.
  Object? formOfFields;

  /// When the last field was asked for, and the switch's value in the form
  /// it was asked of.
  late List<(SchedulerPhase, Object?)> lastFieldAsked;

  setUp(() {
    saves = [];
    edits = 0;
    readOnlyBuilt = [];
    lastFieldAsked = [];
  });

  /// [settle] false pumps one frame only, for a save in flight, whose
  /// spinner never lets the page settle.
  Future<void> pumpGroup(
    WidgetTester tester, {
    SystemSettings? settings,
    int revision = 1,
    bool maySave = true,
    bool saving = false,
    bool saved = false,
    bool settle = true,
  }) async {
    await pumpOnPage(
      tester,
      SettingsGroupForm(
        binding: SettingsGroupBinding(
          settings: settings ?? settingsFixture(),
          revision: revision,
          maySave: maySave,
          saving: saving,
          otherGroupSaving: false,
          saved: saved,
          onSave: saves.add,
          onEdited: () => edits++,
        ),
        buildForm: _buildForm,
        valuesOf: _valuesOf,
        patchOf: _patchOf,
        lastField: (form) {
          lastFieldAsked.add((
            SchedulerBinding.instance.schedulerPhase,
            form.control(_open).value,
          ));
          return _name;
        },
        labels: _labels,
        fields: (context, {required readOnly, required submit}) {
          readOnlyBuilt.add(readOnly);
          formOfFields = ReactiveForm.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              BgeSwitchField(
                formControlName: _open,
                label: 'Open',
                readOnly: readOnly,
                switchKey: _openKey,
              ),
              BgeTextField(
                key: _nameKey,
                formControlName: _name,
                label: 'Name',
                readOnly: readOnly,
                textInputAction: TextInputAction.done,
                onSubmitted: submit,
                validationMessages: {
                  ValidationMessage.required: (_) => _emptyCopy,
                },
              ),
            ],
          );
        },
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  EditableText nameField(WidgetTester tester) => tester.widget<EditableText>(
    find.descendant(
      of: find.byKey(_nameKey),
      matching: find.byType(EditableText),
    ),
  );

  String nameText(WidgetTester tester) => nameField(tester).controller.text;

  bool isOpen(WidgetTester tester) =>
      tester.widget<SwitchListTile>(find.byKey(_openKey)).value;

  Future<void> enterName(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(_nameKey), text);
    await tester.pumpAndSettle();
  }

  Future<void> toggleOpen(WidgetTester tester) async {
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(_saveKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_saveKey));
    await tester.pumpAndSettle();
  }

  group('saving', () {
    testWidgets('Save sends only what changed', (tester) async {
      await pumpGroup(tester);

      await enterName(tester, 'New');
      await save(tester);

      expect(saves, [const SystemSettingsPatch(name: 'New')]);
    });

    testWidgets('Save with nothing changed sends an empty patch', (
      tester,
    ) async {
      await pumpGroup(tester);
      await enterName(tester, 'New');
      await enterName(tester, _storedName);

      await save(tester);

      expect(saves, [const SystemSettingsPatch()]);
    });

    testWidgets('an invalid field blocks Save and shows its message', (
      tester,
    ) async {
      await pumpGroup(tester);

      await enterName(tester, '');
      await save(tester);

      expect(saves, isEmpty);
      expect(find.text(_emptyCopy), findsOneWidget);
    });

    testWidgets('the submit handed to the fields saves as Save does', (
      tester,
    ) async {
      await pumpGroup(tester);
      await enterName(tester, 'New');

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(saves, [const SystemSettingsPatch(name: 'New')]);
    });

    testWidgets('while saving, the fields go read-only', (tester) async {
      await pumpGroup(tester);
      expect(readOnlyBuilt.last, isFalse);

      await pumpGroup(tester, saving: true, settle: false);

      expect(readOnlyBuilt.last, isTrue);
      expect(nameField(tester).readOnly, isTrue);
      expect(find.text('Saving…'), findsOneWidget);
    });
  });

  group('edits and new values from the server', () {
    testWidgets("another group's save landing keeps an unsaved edit", (
      tester,
    ) async {
      await pumpGroup(tester);
      await enterName(tester, 'New');
      expect(edits, greaterThan(0));
      final editsBefore = edits;

      await pumpGroup(
        tester,
        settings: settingsFixture(
          name: 'Elsewhere',
          allowUserRegistration: false,
        ),
        revision: 2,
      );

      expect(nameText(tester), 'New');
      expect(isOpen(tester), isTrue);
      expect(edits, editsBefore);
    });

    testWidgets("another group's save landing keeps an invalid edit: the "
        "server's values are always valid, so it changed", (tester) async {
      await pumpGroup(tester);
      await enterName(tester, '');

      await pumpGroup(
        tester,
        settings: settingsFixture(name: 'Elsewhere'),
        revision: 2,
      );

      expect(nameText(tester), isEmpty);
    });

    testWidgets('a save after new values were kept out sends only what was '
        'edited, not the fields left showing the old values', (tester) async {
      await pumpGroup(tester);
      await enterName(tester, 'New');
      await pumpGroup(
        tester,
        settings: settingsFixture(allowUserRegistration: false),
        revision: 2,
      );

      await save(tester);

      expect(saves, [const SystemSettingsPatch(name: 'New')]);
    });

    testWidgets('its own save landing takes the saved values and is not an '
        'edit', (tester) async {
      await pumpGroup(tester);
      await enterName(tester, 'New');
      await save(tester);
      await pumpGroup(tester, saving: true, settle: false);
      final editsBefore = edits;

      await pumpGroup(
        tester,
        settings: settingsFixture(name: 'New', allowUserRegistration: false),
        revision: 2,
        saved: true,
      );

      expect(nameText(tester), 'New');
      expect(isOpen(tester), isFalse);
      expect(edits, editsBefore);
      expect(find.text(_savedCopy), findsOneWidget);

      await save(tester);
      expect(saves.last, const SystemSettingsPatch());
    });

    testWidgets('new values with nothing unsaved are taken, and are not an '
        'edit', (tester) async {
      await pumpGroup(tester);

      await pumpGroup(
        tester,
        settings: settingsFixture(
          name: 'Elsewhere',
          allowUserRegistration: false,
        ),
        revision: 2,
      );

      expect(nameText(tester), 'Elsewhere');
      expect(isOpen(tester), isFalse);
      expect(edits, 0);
    });
  });

  group('access', () {
    testWidgets('losing save access puts back the saved values', (
      tester,
    ) async {
      await pumpGroup(tester);
      await toggleOpen(tester);
      await enterName(tester, 'New');
      final editsBefore = edits;

      await pumpGroup(tester, maySave: false);

      expect(nameText(tester), _storedName);
      expect(isOpen(tester), isTrue);
      expect(readOnlyBuilt.last, isTrue);
      expect(find.byKey(_saveKey), findsNothing);
      expect(edits, editsBefore);
    });

    testWidgets('Save with focus hands it to the last field when the role '
        'may no longer save', (tester) async {
      await pumpGroup(tester);
      await toggleOpen(tester);
      final saveFocus = Focus.of(
        tester.element(find.text(_saveCopy)),
        createDependency: false,
      )..requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(saveFocus));

      await pumpGroup(tester, maySave: false);

      expect(
        FocusManager.instance.primaryFocus,
        same(nameField(tester).focusNode),
      );
      // Asked of the group's form once the frame that took the settings was
      // built: what a group answers can turn on a value just put back.
      expect(lastFieldAsked, [(SchedulerPhase.postFrameCallbacks, true)]);
    });
  });

  testWidgets("the fields find the group's form from their context", (
    tester,
  ) async {
    await pumpGroup(tester);

    expect(formOfFields, isA<FormGroup>());
  });
}
