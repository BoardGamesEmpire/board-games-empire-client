import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/src/widgets/retention_settings_form.dart';
import 'package:server_settings/src/widgets/settings_group_binding.dart';
import 'package:ui/ui.dart';

import 'support/fake_system_settings_remote.dart';
import 'support/harness.dart';

const _feedbackLabel = 'Days to keep feedback reports';
const _feedbackHelper =
    'Older reports are deleted automatically. From 1 to 36500 days.';
const _redactionLabel = 'Redact feedback reports on the server';
const _warningCopy =
    'Feedback reports are stored as they arrive, and the server relies on '
    'each app to redact them.';
const _auditLabel = 'Delete old audit log entries';
const _auditSubtitle = 'While this is off, entries are kept indefinitely.';
const _auditDaysLabel = 'Days to keep audit log entries';
const _daysHelper = 'From 1 to 36500 days.';
const _invalidCopy = 'Enter a whole number of days from 1 to 36500.';
const _saveCopy = 'Save data retention settings';

void main() {
  late List<SystemSettingsPatch> saves;
  late int edits;

  setUp(() {
    saves = [];
    edits = 0;
  });

  Future<void> pumpForm(
    WidgetTester tester, {
    SystemSettings? settings,
    int revision = 1,
    bool maySave = true,
  }) async {
    await pumpOnPage(
      tester,
      RetentionSettingsForm(
        binding: SettingsGroupBinding(
          settings: settings ?? settingsFixture(),
          revision: revision,
          maySave: maySave,
          saving: false,
          otherGroupSaving: false,
          onSave: saves.add,
          onEdited: () => edits++,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder feedback() => find.byKey(RetentionSettingsForm.feedbackDaysFieldKey);
  Finder auditDays() => find.byKey(RetentionSettingsForm.auditDaysFieldKey);
  Finder warning() => find.byKey(RetentionSettingsForm.redactionWarningKey);

  EditableText textField(WidgetTester tester, Finder field) =>
      tester.widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );

  bool switchValue(WidgetTester tester, Key key) =>
      tester.widget<SwitchListTile>(find.byKey(key)).value;

  BgeSwitchField switchField(WidgetTester tester, Key key) =>
      tester.widget<BgeSwitchField>(
        find.ancestor(
          of: find.byKey(key),
          matching: find.byType(BgeSwitchField),
        ),
      );

  /// The group's form, as the fields find it.
  FormGroup form(WidgetTester tester) =>
      ReactiveForm.of(tester.element(feedback()), listen: false)! as FormGroup;

  Future<void> tapKey(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  Future<void> toggleAudit(WidgetTester tester) =>
      tapKey(tester, RetentionSettingsForm.auditSwitchKey);

  Future<void> toggleRedaction(WidgetTester tester) =>
      tapKey(tester, RetentionSettingsForm.redactionSwitchKey);

  Future<void> enter(WidgetTester tester, Finder field, String text) async {
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, text);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) =>
      tapKey(tester, RetentionSettingsForm.saveKey);

  /// Whether keyboard focus is inside what [finder] finds.
  bool focusIsIn(Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    return find
        .ancestor(
          of: find.byElementPredicate((e) => identical(e, focused)),
          matching: finder,
        )
        .evaluate()
        .isNotEmpty;
  }

  Future<void> focusSave(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(RetentionSettingsForm.saveKey));
    await tester.pumpAndSettle();
    Focus.of(
      tester.element(find.text(_saveCopy)),
      createDependency: false,
    ).requestFocus();
    await tester.pump();
    expect(focusIsIn(find.byKey(RetentionSettingsForm.saveKey)), isTrue);
  }

  group('the controls', () {
    testWidgets('shows the feedback days, the two switches and their words, '
        'in order', (tester) async {
      await pumpForm(
        tester,
        settings: settingsFixture(auditLogRetentionDays: 30),
      );

      expect(find.text(_feedbackLabel), findsOneWidget);
      expect(find.text(_feedbackHelper), findsOneWidget);
      expect(textField(tester, feedback()).controller.text, '90');
      expect(find.text(_redactionLabel), findsOneWidget);
      expect(
        switchValue(tester, RetentionSettingsForm.redactionSwitchKey),
        isTrue,
      );
      expect(find.text(_auditLabel), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(RetentionSettingsForm.auditSwitchKey),
          matching: find.text(_auditSubtitle),
        ),
        findsOneWidget,
      );
      expect(find.text(_auditDaysLabel), findsOneWidget);
      expect(find.text(_daysHelper), findsOneWidget);
      final tops = [
        RetentionSettingsForm.feedbackDaysFieldKey,
        RetentionSettingsForm.redactionSwitchKey,
        RetentionSettingsForm.auditSwitchKey,
        RetentionSettingsForm.auditDaysFieldKey,
      ].map((key) => tester.getRect(find.byKey(key)).top).toList();
      for (var i = 1; i < tops.length; i++) {
        expect(tops[i], greaterThan(tops[i - 1]), reason: 'control $i');
      }
    });

    testWidgets('a changed feedback count is saved', (tester) async {
      await pumpForm(tester);
      await enter(tester, feedback(), '30');

      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(feedbackReportRetentionDays: 30),
      ]);
    });

    testWidgets('feedback days out of range are refused on the field', (
      tester,
    ) async {
      await pumpForm(tester);

      for (final text in ['0', '36501']) {
        await enter(tester, feedback(), text);
        await save(tester);

        expect(saves, isEmpty, reason: text);
        expect(
          find.descendant(of: feedback(), matching: find.text(_invalidCopy)),
          findsOneWidget,
          reason: text,
        );
      }
    });

    testWidgets('Enter in the feedback days does not save', (tester) async {
      await pumpForm(tester);
      await enter(tester, feedback(), '30');

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(saves, isEmpty);
    });

    testWidgets('the redaction switch is saved alone', (tester) async {
      await pumpForm(tester);
      await toggleRedaction(tester);

      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(feedbackReportServerRedactionEnabled: false),
      ]);
    });
  });

  group('redaction', () {
    testWidgets('redaction off warns, heard and not scrolled to', (
      tester,
    ) async {
      await pumpForm(tester);
      expect(warning(), findsNothing);

      await toggleRedaction(tester);

      final banner = tester.widget<BgeInlineBanner>(warning());
      expect(banner.message, _warningCopy);
      expect(banner.tone, BgeBannerTone.warning);
      expect(banner.announce, isTrue);
      expect(banner.reveal, isFalse);

      // As saved, too, on a form of its own.
      await tester.pumpWidget(const SizedBox());
      await pumpForm(
        tester,
        settings: settingsFixture(feedbackReportServerRedactionEnabled: false),
      );

      expect(
        switchValue(tester, RetentionSettingsForm.redactionSwitchKey),
        isFalse,
      );
      expect(tester.widget<BgeInlineBanner>(warning()).reveal, isFalse);
    });

    testWidgets('turning redaction back on takes the warning away', (
      tester,
    ) async {
      await pumpForm(tester);
      await toggleRedaction(tester);
      expect(warning(), findsOneWidget);

      await toggleRedaction(tester);

      expect(warning(), findsNothing);
      expect(find.text(_warningCopy), findsNothing);
    });

    testWidgets('the warning sits under the redaction switch', (tester) async {
      await pumpForm(tester);
      await toggleRedaction(tester);

      final warningRect = tester.getRect(warning());
      expect(
        warningRect.top,
        greaterThan(
          tester
              .getRect(find.byKey(RetentionSettingsForm.redactionSwitchKey))
              .bottom,
        ),
      );
      expect(
        warningRect.bottom,
        lessThan(
          tester.getRect(find.byKey(RetentionSettingsForm.auditSwitchKey)).top,
        ),
      );
    });
  });

  group('audit retention', () {
    testWidgets('a null audit retention shows the switch off and no days '
        'field', (tester) async {
      await pumpForm(tester);

      expect(
        switchValue(tester, RetentionSettingsForm.auditSwitchKey),
        isFalse,
      );
      expect(auditDays(), findsNothing);
      expect(find.text(_auditDaysLabel), findsNothing);
    });

    testWidgets('a set audit retention shows the switch on and its days', (
      tester,
    ) async {
      await pumpForm(
        tester,
        settings: settingsFixture(auditLogRetentionDays: 30),
      );

      expect(switchValue(tester, RetentionSettingsForm.auditSwitchKey), isTrue);
      expect(textField(tester, auditDays()).controller.text, '30');
    });

    testWidgets('turning the audit switch off sends a clear', (tester) async {
      await pumpForm(
        tester,
        settings: settingsFixture(auditLogRetentionDays: 30),
      );

      await toggleAudit(tester);
      expect(auditDays(), findsNothing);
      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(
          auditLogRetentionDays: SettingValue.clear(),
        ),
      ]);
    });

    testWidgets('turning it on needs a days count', (tester) async {
      await pumpForm(tester);

      await toggleAudit(tester);
      expect(textField(tester, auditDays()).controller.text, isEmpty);
      await save(tester);

      expect(saves, isEmpty);
      expect(
        find.descendant(of: auditDays(), matching: find.text(_invalidCopy)),
        findsOneWidget,
      );

      await enter(tester, auditDays(), '365');
      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(
          auditLogRetentionDays: SettingValue.set(365),
        ),
      ]);
    });

    testWidgets('a changed audit count is saved', (tester) async {
      await pumpForm(
        tester,
        settings: settingsFixture(auditLogRetentionDays: 30),
      );

      await enter(tester, auditDays(), '60');
      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(auditLogRetentionDays: SettingValue.set(60)),
      ]);
    });

    testWidgets('turning the switch off and on again sends nothing', (
      tester,
    ) async {
      await pumpForm(
        tester,
        settings: settingsFixture(auditLogRetentionDays: 30),
      );

      await toggleAudit(tester);
      await toggleAudit(tester);
      expect(textField(tester, auditDays()).controller.text, '30');
      await save(tester);

      expect(saves, [const SystemSettingsPatch()]);
    });

    testWidgets('an invalid days count is dropped when the switch goes off', (
      tester,
    ) async {
      await pumpForm(tester);
      await toggleAudit(tester);
      await enter(tester, auditDays(), '0');
      expect(form(tester).valid, isFalse);

      await toggleAudit(tester);

      expect(form(tester).valid, isTrue);
      await save(tester);
      // Empty: the screen's save says nothing changed.
      expect(saves, [const SystemSettingsPatch()]);
    });

    testWidgets('the same, from a set value', (tester) async {
      await pumpForm(
        tester,
        settings: settingsFixture(auditLogRetentionDays: 30),
      );
      await enter(tester, auditDays(), '0');
      expect(form(tester).valid, isFalse);

      await toggleAudit(tester);

      expect(form(tester).valid, isTrue);
      await save(tester);
      expect(saves, [
        const SystemSettingsPatch(
          auditLogRetentionDays: SettingValue.clear(),
        ),
      ]);
    });

    testWidgets('Enter in the audit days saves', (tester) async {
      await pumpForm(
        tester,
        settings: settingsFixture(auditLogRetentionDays: 30),
      );
      await enter(tester, auditDays(), '60');

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(saves, [
        const SystemSettingsPatch(auditLogRetentionDays: SettingValue.set(60)),
      ]);
    });
  });

  group('access and new values from the server', () {
    testWidgets('a role that may not save sees every control read-only and '
        'no Save', (tester) async {
      await pumpForm(
        tester,
        settings: settingsFixture(auditLogRetentionDays: 30),
        maySave: false,
      );

      expect(textField(tester, feedback()).readOnly, isTrue);
      expect(
        switchField(tester, RetentionSettingsForm.redactionSwitchKey).readOnly,
        isTrue,
      );
      expect(
        switchField(tester, RetentionSettingsForm.auditSwitchKey).readOnly,
        isTrue,
      );
      expect(textField(tester, auditDays()).readOnly, isTrue);
      expect(find.byKey(RetentionSettingsForm.saveKey), findsNothing);
    });

    testWidgets('taking new values is not an edit', (tester) async {
      await pumpForm(tester);

      // The server turns audit retention on, then off again.
      await pumpForm(
        tester,
        settings: settingsFixture(auditLogRetentionDays: 30),
        revision: 2,
      );

      expect(switchValue(tester, RetentionSettingsForm.auditSwitchKey), isTrue);
      expect(textField(tester, auditDays()).controller.text, '30');

      await pumpForm(tester, revision: 3);

      expect(
        switchValue(tester, RetentionSettingsForm.auditSwitchKey),
        isFalse,
      );
      expect(auditDays(), findsNothing);
      expect(form(tester).valid, isTrue);
      expect(edits, 0);
    });

    testWidgets('values taken are checked at once, whichever control moves', (
      tester,
    ) async {
      await pumpForm(
        tester,
        settings: settingsFixture(auditLogRetentionDays: 30),
      );
      final group = form(tester);
      final on = Map.of(group.value);
      await pumpForm(tester, revision: 2);
      final off = Map.of(group.value);

      // Taken as the form takes them, in one reset, and read before any
      // value change is delivered.
      group.reset(value: on);
      expect(group.valid, isTrue);
      group.reset(value: off);
      expect(group.valid, isTrue);

      // On with no count: only the switch moves, the days stay empty.
      group.reset(value: {...off, 'audit': true});
      expect(group.valid, isFalse);
      group.reset(value: off);
      expect(group.valid, isTrue);
      await tester.pumpAndSettle();
    });

    testWidgets('a stored audit count out of range is invalid from the start, '
        "and another group's save doesn't take it", (tester) async {
      // A count the server took that this app's range doesn't hold, such as
      // one from a server with a higher limit.
      final settings = settingsFixture(auditLogRetentionDays: 40000);
      await pumpForm(tester, settings: settings);

      expect(form(tester).valid, isFalse);

      // An invalid form holds unsaved changes, so it keeps them, and no
      // patch is asked of it.
      await pumpForm(tester, settings: settings, revision: 2);
      expect(tester.takeException(), isNull);
      expect(textField(tester, auditDays()).controller.text, '40000');

      await save(tester);
      expect(saves, isEmpty);
      expect(
        find.descendant(of: auditDays(), matching: find.text(_invalidCopy)),
        findsOneWidget,
      );
    });

    testWidgets('a move of the audit switch is one edit', (tester) async {
      await pumpForm(tester);

      await toggleAudit(tester);
      expect(edits, 1);
      await toggleAudit(tester);
      expect(edits, 2);
    });

    testWidgets("another group's save landing keeps an unsaved audit count", (
      tester,
    ) async {
      await pumpForm(tester);
      await toggleAudit(tester);
      await enter(tester, auditDays(), '4');

      await pumpForm(tester, revision: 2);

      expect(switchValue(tester, RetentionSettingsForm.auditSwitchKey), isTrue);
      expect(textField(tester, auditDays()).controller.text, '4');
    });

    testWidgets('Save with focus hands it to the audit days, the last field, '
        'when the role may no longer save with the audit switch on', (
      tester,
    ) async {
      await pumpForm(
        tester,
        settings: settingsFixture(auditLogRetentionDays: 30),
      );
      // Off, unsaved: losing access puts it back on.
      await toggleAudit(tester);
      expect(auditDays(), findsNothing);
      await focusSave(tester);

      await pumpForm(
        tester,
        settings: settingsFixture(auditLogRetentionDays: 30),
        maySave: false,
      );

      expect(switchValue(tester, RetentionSettingsForm.auditSwitchKey), isTrue);
      expect(focusIsIn(auditDays()), isTrue);
    });

    testWidgets('Save with focus hands it to the audit switch, the last '
        'field, when the role may no longer save with the switch off', (
      tester,
    ) async {
      await pumpForm(tester);
      // On, unsaved: losing access puts it back off, and its days go.
      await toggleAudit(tester);
      expect(auditDays(), findsOneWidget);
      await focusSave(tester);

      await pumpForm(tester, maySave: false);

      expect(
        switchValue(tester, RetentionSettingsForm.auditSwitchKey),
        isFalse,
      );
      expect(auditDays(), findsNothing);
      expect(
        focusIsIn(find.byKey(RetentionSettingsForm.auditSwitchKey)),
        isTrue,
      );
    });
  });
}
