import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:server_settings/server_settings.dart';
import 'package:server_settings/src/widgets/mail_settings_form.dart';
import 'package:server_settings/src/widgets/mail_test_panel.dart';
import 'package:ui/ui.dart';

import 'support/harness.dart';

/// Settings with mail set up and a password saved, unless told otherwise.
SystemSettings _settings({
  String? host = 'smtp.example.com',
  int port = 587,
  SmtpSecurity security = SmtpSecurity.startTls,
  String? user = 'mailer',
  bool passwordSet = true,
  String? from = 'games@example.com',
  int lifetime = 1440,
  bool allowPasswordResets = true,
  ProviderLinkingPolicy linking = ProviderLinkingPolicy.signedIn,
}) => SystemSettings(
  id: 'settings-1',
  smtpHost: host,
  smtpPort: port,
  smtpSecurity: security,
  smtpUser: user,
  smtpPasswordSet: passwordSet,
  mailFromAddress: from,
  passwordResetLinkLifetimeMinutes: lifetime,
  allowPasswordResets: allowPasswordResets,
  providerLinkingPolicy: linking,
);

/// No mail set up: nothing saved for host, user, password or From.
final SystemSettings _unset = _settings(
  host: null,
  user: null,
  passwordSet: false,
  from: null,
);

const _passwordRequiredCopy =
    'The connection changed, so enter the password again or remove it.';
const _removingCopy = 'The saved password will be removed when you save.';
const _savedPasswordCopy = 'A password is saved.';
const _savedCopy = 'Mail settings saved.';
const _tooLongCopy = 'Use at most 255 characters.';

const _panelKey = Key('test panel');

void main() {
  late List<SystemSettingsPatch> saves;
  late int edits;

  setUp(() {
    saves = [];
    edits = 0;
  });

  /// [settle] false pumps one frame only, for a save in flight, whose
  /// spinner never lets the page settle.
  Future<void> pumpForm(
    WidgetTester tester, {
    SystemSettings? settings,
    int revision = 1,
    bool maySave = true,
    bool saving = false,
    bool otherGroupSaving = false,
    SettingsSaveFailure? failure,
    bool saved = false,
    bool offline = false,
    Widget Function(BuildContext, {required bool hasUnsavedChanges})?
    testPanelBuilder,
    bool settle = true,
  }) async {
    await pumpOnPage(
      tester,
      MailSettingsForm(
        settings: settings ?? _settings(),
        revision: revision,
        maySave: maySave,
        saving: saving,
        otherGroupSaving: otherGroupSaving,
        failure: failure,
        saved: saved,
        onSave: saves.add,
        onEdited: () => edits++,
        testPanelBuilder:
            testPanelBuilder ??
            (context, {required hasUnsavedChanges}) =>
                Text('unsaved: $hasUnsavedChanges', key: _panelKey),
      ),
      offline: offline,
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Finder field(Key key) =>
      find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

  EditableText editable(WidgetTester tester, Key key) =>
      tester.widget<EditableText>(field(key));

  String textOf(WidgetTester tester, Key key) =>
      editable(tester, key).controller.text;

  Future<void> enter(WidgetTester tester, Key key, String text) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.enterText(find.byKey(key), text);
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) =>
      tapKey(tester, MailSettingsForm.saveKey);

  FocusNode buttonNode(WidgetTester tester, Key key) =>
      tester.widget<TextButton>(find.byKey(key)).focusNode!;

  /// Presses the button [key] from the keyboard, as Tab and Space would.
  Future<void> pressByKeyboard(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    buttonNode(tester, key).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
  }

  FocusNode? focused() => FocusManager.instance.primaryFocus;

  String panelText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(_panelKey)).data!;

  group('the password rule', () {
    testWidgets('changing the port with a password saved asks for the '
        'password, on its field with focus, and sends nothing', (tester) async {
      await pumpForm(tester);

      await enter(tester, MailSettingsForm.portFieldKey, '2525');
      await save(tester);

      expect(saves, isEmpty);
      expect(find.byKey(MailSettingsForm.passwordFieldKey), findsOneWidget);
      expect(find.text(_passwordRequiredCopy), findsOneWidget);
      expect(
        focused(),
        same(editable(tester, MailSettingsForm.passwordFieldKey).focusNode),
      );
    });

    testWidgets('the password entered with the change is sent with it', (
      tester,
    ) async {
      await pumpForm(tester);
      await enter(tester, MailSettingsForm.portFieldKey, '2525');
      await save(tester);

      await enter(tester, MailSettingsForm.passwordFieldKey, ' s3cret ');
      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(
          smtpPort: 2525,
          smtpPassword: SettingValue.set(' s3cret '),
        ),
      ]);
    });

    testWidgets('removing the password with the change saves without asking', (
      tester,
    ) async {
      await pumpForm(tester);
      await enter(tester, MailSettingsForm.portFieldKey, '2525');
      await tapKey(tester, MailSettingsForm.removePasswordKey);

      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(
          smtpPort: 2525,
          smtpPassword: SettingValue.clear(),
        ),
      ]);
    });

    testWidgets('asked for the password, Remove password beside the field '
        'removes it instead, and the save goes without asking again', (
      tester,
    ) async {
      await pumpForm(tester);
      await enter(tester, MailSettingsForm.portFieldKey, '2525');
      await save(tester);
      expect(find.text(_passwordRequiredCopy), findsOneWidget);
      expect(find.byKey(MailSettingsForm.keepSavedPasswordKey), findsOneWidget);

      await tapKey(tester, MailSettingsForm.removePasswordKey);

      expect(find.byKey(MailSettingsForm.passwordFieldKey), findsNothing);
      expect(find.text(_removingCopy), findsOneWidget);
      expect(
        focused(),
        same(buttonNode(tester, MailSettingsForm.keepPasswordKey)),
      );

      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(
          smtpPort: 2525,
          smtpPassword: SettingValue.clear(),
        ),
      ]);
      expect(find.text(_passwordRequiredCopy), findsNothing);
      expect(find.byKey(MailSettingsForm.passwordFieldKey), findsNothing);
    });

    testWidgets('clearing the host with a password saved saves without '
        'asking', (tester) async {
      await pumpForm(tester);

      await enter(tester, MailSettingsForm.hostFieldKey, '');
      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(smtpHost: SettingValue.clear()),
      ]);
      expect(find.text(_passwordRequiredCopy), findsNothing);
    });

    testWidgets("the server's demand for the password lands on the same "
        'field, with focus, and no banner says it twice', (tester) async {
      await pumpForm(tester);
      await enter(tester, MailSettingsForm.userFieldKey, 'relay');
      await pumpForm(tester, saving: true, settle: false);

      await pumpForm(tester, failure: SettingsSaveFailure.passwordRequired);

      expect(find.byKey(MailSettingsForm.passwordFieldKey), findsOneWidget);
      expect(find.text(_passwordRequiredCopy), findsOneWidget);
      expect(
        focused(),
        same(editable(tester, MailSettingsForm.passwordFieldKey).focusNode),
      );
      expect(find.text('Mail settings not saved'), findsNothing);
    });
  });

  group('the saved password', () {
    testWidgets('is never shown: the form says one is saved', (tester) async {
      await pumpForm(tester);

      expect(find.text(_savedPasswordCopy), findsOneWidget);
      expect(find.byKey(MailSettingsForm.passwordFieldKey), findsNothing);
      expect(find.byKey(MailSettingsForm.changePasswordKey), findsOneWidget);
      expect(find.byKey(MailSettingsForm.removePasswordKey), findsOneWidget);
    });

    testWidgets('with none saved, the field shows directly', (tester) async {
      await pumpForm(tester, settings: _unset);

      expect(find.byKey(MailSettingsForm.passwordFieldKey), findsOneWidget);
      expect(find.text(_savedPasswordCopy), findsNothing);
      expect(find.byKey(MailSettingsForm.keepSavedPasswordKey), findsNothing);
    });

    testWidgets('Change password opens the field and puts focus in it', (
      tester,
    ) async {
      await pumpForm(tester);

      await tapKey(tester, MailSettingsForm.changePasswordKey);

      expect(find.byKey(MailSettingsForm.passwordFieldKey), findsOneWidget);
      expect(find.text(_savedPasswordCopy), findsNothing);
      expect(
        focused(),
        same(editable(tester, MailSettingsForm.passwordFieldKey).focusNode),
      );
    });

    testWidgets('Keep saved password closes the field, drops what was typed '
        'and hands focus to Change password', (tester) async {
      await pumpForm(tester);
      await tapKey(tester, MailSettingsForm.changePasswordKey);
      await enter(tester, MailSettingsForm.passwordFieldKey, 'half');

      await pressByKeyboard(tester, MailSettingsForm.keepSavedPasswordKey);

      expect(find.byKey(MailSettingsForm.passwordFieldKey), findsNothing);
      expect(find.text(_savedPasswordCopy), findsOneWidget);
      expect(
        focused(),
        same(buttonNode(tester, MailSettingsForm.changePasswordKey)),
      );

      await tapKey(tester, MailSettingsForm.changePasswordKey);
      expect(textOf(tester, MailSettingsForm.passwordFieldKey), isEmpty);
    });

    testWidgets('Remove password says what a save will do and hands focus to '
        'Keep password', (tester) async {
      await pumpForm(tester);

      await pressByKeyboard(tester, MailSettingsForm.removePasswordKey);

      expect(find.text(_removingCopy), findsOneWidget);
      expect(
        focused(),
        same(buttonNode(tester, MailSettingsForm.keepPasswordKey)),
      );
    });

    testWidgets('a tap on Remove password hands focus to Keep password too: '
        "a tap, like a screen reader's double tap, moves no focus", (
      tester,
    ) async {
      await pumpForm(tester);

      await tapKey(tester, MailSettingsForm.removePasswordKey);

      expect(find.text(_removingCopy), findsOneWidget);
      expect(
        focused(),
        same(buttonNode(tester, MailSettingsForm.keepPasswordKey)),
      );
    });

    testWidgets('Keep password hands focus back to Change password', (
      tester,
    ) async {
      await pumpForm(tester);
      await pressByKeyboard(tester, MailSettingsForm.removePasswordKey);

      await pressByKeyboard(tester, MailSettingsForm.keepPasswordKey);

      expect(find.text(_savedPasswordCopy), findsOneWidget);
      expect(
        focused(),
        same(buttonNode(tester, MailSettingsForm.changePasswordKey)),
      );
    });

    testWidgets('a password state change is an edit', (tester) async {
      await pumpForm(tester);

      await tapKey(tester, MailSettingsForm.removePasswordKey);

      expect(edits, greaterThan(0));
      expect(panelText(tester), 'unsaved: true');
    });

    testWidgets('an empty new password with one saved is refused', (
      tester,
    ) async {
      await pumpForm(tester);
      await tapKey(tester, MailSettingsForm.changePasswordKey);

      await save(tester);

      expect(saves, isEmpty);
      expect(
        find.text('Enter the new password, or keep the saved one.'),
        findsOneWidget,
      );
    });

    testWidgets('a first password is sent untrimmed', (tester) async {
      await pumpForm(tester, settings: _unset);

      await enter(tester, MailSettingsForm.passwordFieldKey, ' p ');
      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(smtpPassword: SettingValue.set(' p ')),
      ]);
    });
  });

  group('connection security', () {
    Future<void> pick(WidgetTester tester, String label) async {
      await tester.ensureVisible(find.byKey(MailSettingsForm.securityFieldKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MailSettingsForm.securityFieldKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    const warning =
        'With no TLS, the password and every email cross the network '
        'unencrypted. Use it only for a mail relay on a network you trust.';

    testWidgets('choosing None warns that nothing is encrypted', (
      tester,
    ) async {
      await pumpForm(tester, settings: _unset);
      expect(find.text(warning), findsNothing);

      await pick(tester, 'None');

      expect(find.text(warning), findsOneWidget);
    });

    testWidgets('a setting this app does not know shows as such, and a save '
        'leaves it alone', (tester) async {
      await pumpForm(
        tester,
        settings: _settings(security: SmtpSecurity.unknown),
      );

      expect(
        find.descendant(
          of: find.byKey(MailSettingsForm.securityFieldKey),
          matching: find.text("A setting this app doesn't know"),
        ),
        findsOneWidget,
      );

      await enter(tester, MailSettingsForm.userFieldKey, 'relay');
      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(smtpUser: SettingValue.set('relay')),
      ]);
    });
  });

  group('the reset link lifetime', () {
    testWidgets('reads 1440 minutes as a day, with the limits', (
      tester,
    ) async {
      await pumpForm(tester);

      expect(find.text('1 day. From 15 minutes to 7 days.'), findsOneWidget);
    });

    testWidgets('the reading follows what is typed', (tester) async {
      await pumpForm(tester);

      await enter(tester, MailSettingsForm.lifetimeFieldKey, '90');

      expect(
        find.text('1 hour, 30 minutes. From 15 minutes to 7 days.'),
        findsOneWidget,
      );
    });

    testWidgets('a lifetime out of range is refused on the form', (
      tester,
    ) async {
      await pumpForm(tester);

      await enter(tester, MailSettingsForm.lifetimeFieldKey, '14');
      await save(tester);

      expect(saves, isEmpty);
      expect(
        find.text('Enter a whole number of minutes from 15 to 10080 (7 days).'),
        findsOneWidget,
      );
    });

    testWidgets('a changed lifetime and switch are saved', (tester) async {
      await pumpForm(tester);

      await enter(tester, MailSettingsForm.lifetimeFieldKey, '60');
      await tapKey(tester, MailSettingsForm.passwordResetsSwitchKey);
      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(
          passwordResetLinkLifetimeMinutes: 60,
          allowPasswordResets: false,
        ),
      ]);
    });
  });

  group('field checks', () {
    testWidgets('a host of 256 characters is refused', (tester) async {
      await pumpForm(tester, settings: _unset);

      await enter(tester, MailSettingsForm.hostFieldKey, 'a' * 256);
      await save(tester);

      expect(saves, isEmpty);
      expect(find.text(_tooLongCopy), findsOneWidget);
    });

    testWidgets('a host of 255 characters is saved', (tester) async {
      await pumpForm(tester, settings: _unset);

      await enter(tester, MailSettingsForm.hostFieldKey, 'a' * 255);
      await save(tester);

      expect(saves, [
        SystemSettingsPatch(smtpHost: SettingValue.set('a' * 255)),
      ]);
    });

    testWidgets('255 emoji are 255 characters to the server, and saved', (
      tester,
    ) async {
      await pumpForm(tester, settings: _unset);
      final emoji = '\u{1F600}' * 255;

      await enter(tester, MailSettingsForm.hostFieldKey, emoji);
      await save(tester);

      expect(find.text(_tooLongCopy), findsNothing);
      expect(saves, [SystemSettingsPatch(smtpHost: SettingValue.set(emoji))]);
    });

    for (final port in ['0', '65536', '0x50', '+25', '']) {
      testWidgets('a port of "$port" is refused', (tester) async {
        await pumpForm(tester, settings: _unset);

        await enter(tester, MailSettingsForm.portFieldKey, port);
        await save(tester);

        expect(saves, isEmpty);
        expect(find.text('Enter a port from 1 to 65535.'), findsOneWidget);
      });
    }

    testWidgets('a From that is not an email address is refused', (
      tester,
    ) async {
      await pumpForm(tester, settings: _unset);

      await enter(tester, MailSettingsForm.fromFieldKey, 'games at example');
      await save(tester);

      expect(saves, isEmpty);
      expect(find.text('Enter an email address.'), findsOneWidget);
    });

    testWidgets('host, user and From are saved trimmed', (tester) async {
      await pumpForm(tester, settings: _unset);

      await enter(tester, MailSettingsForm.hostFieldKey, ' smtp.example.com ');
      await enter(tester, MailSettingsForm.userFieldKey, ' relay ');
      await enter(tester, MailSettingsForm.fromFieldKey, ' a@example.com ');
      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(
          smtpHost: SettingValue.set('smtp.example.com'),
          smtpUser: SettingValue.set('relay'),
          mailFromAddress: SettingValue.set('a@example.com'),
        ),
      ]);
    });

    testWidgets('host, user and From are not prose: no autocorrect, no '
        'suggestions', (tester) async {
      await pumpForm(tester, settings: _unset);

      for (final key in [
        MailSettingsForm.hostFieldKey,
        MailSettingsForm.userFieldKey,
        MailSettingsForm.passwordFieldKey,
        MailSettingsForm.fromFieldKey,
      ]) {
        final text = editable(tester, key);
        expect(text.autocorrect, isFalse, reason: '$key');
        expect(text.enableSuggestions, isFalse, reason: '$key');
      }
    });
  });

  group('access and saving', () {
    final fieldKeys = [
      MailSettingsForm.hostFieldKey,
      MailSettingsForm.portFieldKey,
      MailSettingsForm.userFieldKey,
      MailSettingsForm.fromFieldKey,
      MailSettingsForm.lifetimeFieldKey,
    ];

    testWidgets('a role that may not save sees every field read-only, and no '
        'Save, password buttons or test button', (tester) async {
      await pumpForm(
        tester,
        maySave: false,
        testPanelBuilder: (context, {required hasUnsavedChanges}) =>
            MailTestPanel(
              state: const MailTestIdle(),
              hasUnsavedChanges: hasUnsavedChanges,
              mailConfigured: true,
              onSend: () {},
            ),
      );

      for (final key in fieldKeys) {
        expect(editable(tester, key).readOnly, isTrue, reason: '$key');
      }
      expect(
        tester
            .widget<BgeDropdownField<SmtpSecurity>>(
              find.byKey(MailSettingsForm.securityFieldKey),
            )
            .readOnly,
        isTrue,
      );
      expect(
        tester
            .widget<BgeSwitchField>(
              find.ancestor(
                of: find.byKey(MailSettingsForm.passwordResetsSwitchKey),
                matching: find.byType(BgeSwitchField),
              ),
            )
            .readOnly,
        isTrue,
      );
      expect(find.text(_savedPasswordCopy), findsOneWidget);
      expect(find.byKey(MailSettingsForm.saveKey), findsNothing);
      expect(find.byKey(MailSettingsForm.changePasswordKey), findsNothing);
      expect(find.byKey(MailSettingsForm.removePasswordKey), findsNothing);
      expect(find.text('Send test email'), findsNothing);
    });

    testWidgets('losing save access puts back the saved values and the kept '
        'password, and is not an edit', (tester) async {
      await pumpForm(tester);
      await enter(tester, MailSettingsForm.userFieldKey, 'relay');
      await tapKey(tester, MailSettingsForm.removePasswordKey);
      final editsBefore = edits;

      await pumpForm(tester, maySave: false);

      expect(textOf(tester, MailSettingsForm.userFieldKey), 'mailer');
      expect(find.text(_removingCopy), findsNothing);
      expect(find.text(_savedPasswordCopy), findsOneWidget);
      expect(edits, editsBefore);
    });

    testWidgets('a failed save still says so once Save is gone', (
      tester,
    ) async {
      await pumpForm(
        tester,
        maySave: false,
        failure: SettingsSaveFailure.refused,
      );

      expect(find.byKey(MailSettingsForm.saveKey), findsNothing);
      expect(find.text('Mail settings not saved'), findsOneWidget);
      expect(
        find.text("Your role can't change the server's settings."),
        findsOneWidget,
      );
    });

    testWidgets('while saving, the fields go read-only and Save says so', (
      tester,
    ) async {
      await pumpForm(tester, saving: true, settle: false);

      for (final key in fieldKeys) {
        expect(editable(tester, key).readOnly, isTrue, reason: '$key');
      }
      expect(find.text('Saving…'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(MailSettingsForm.changePasswordKey),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('Save is disabled while the other group saves', (
      tester,
    ) async {
      await pumpForm(tester, otherGroupSaving: true);
      await enter(tester, MailSettingsForm.userFieldKey, 'relay');

      await tester.ensureVisible(find.byKey(MailSettingsForm.saveKey));
      await tester.tap(find.byKey(MailSettingsForm.saveKey));
      await tester.pumpAndSettle();

      expect(saves, isEmpty);
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(
                of: find.byKey(MailSettingsForm.saveKey),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(editable(tester, MailSettingsForm.hostFieldKey).readOnly, isFalse);
    });

    testWidgets('offline, Save is disabled and the reason is drawn once for '
        'the group, Save carrying it as its hint', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpForm(
        tester,
        offline: true,
        testPanelBuilder: (context, {required hasUnsavedChanges}) =>
            MailTestPanel(
              state: const MailTestIdle(),
              hasUnsavedChanges: hasUnsavedChanges,
              mailConfigured: true,
              onSend: () {},
            ),
      );
      await enter(tester, MailSettingsForm.userFieldKey, 'relay');

      await tester.ensureVisible(find.byKey(MailSettingsForm.saveKey));
      await tester.tap(find.byKey(MailSettingsForm.saveKey));
      await tester.pumpAndSettle();

      expect(saves, isEmpty);
      expect(find.text(onlineOnlyCopy), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(MailSettingsForm.saveKey)).hint,
        onlineOnlyCopy,
      );
      handle.dispose();
    });

    for (final (failure, copy) in [
      (SettingsSaveFailure.nothingChanged, 'No setting changed.'),
      (
        SettingsSaveFailure.refused,
        "Your role can't change the server's settings.",
      ),
      (
        SettingsSaveFailure.rejected,
        'The server refused one of these values. Check them and try again.',
      ),
      (
        SettingsSaveFailure.failed,
        "Couldn't reach the server. Check your connection and try again.",
      ),
    ]) {
      testWidgets('a save that failed as ${failure.name} says so above Save', (
        tester,
      ) async {
        await pumpForm(tester, failure: failure);

        expect(find.text('Mail settings not saved'), findsOneWidget);
        expect(find.text(copy), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(BgeFormActions),
            matching: find.text(copy),
          ),
          findsOneWidget,
        );
      });
    }

    testWidgets('a save that landed says so above Save', (tester) async {
      await pumpForm(tester, saved: true);

      expect(find.text(_savedCopy), findsOneWidget);
      final banner = tester.getRect(find.byKey(MailSettingsForm.savedKey));
      final saveButton = tester.getRect(find.byKey(MailSettingsForm.saveKey));
      expect(banner.bottom, lessThan(saveButton.top));
    });

    testWidgets('Save with focus hands it to the last field when the role '
        'may no longer save', (tester) async {
      await pumpForm(tester);
      final saveFocus = Focus.of(
        tester.element(find.text('Save mail settings')),
        createDependency: false,
      )..requestFocus();
      await tester.pump();
      expect(focused(), same(saveFocus));

      await pumpForm(tester, maySave: false);

      expect(
        focused(),
        same(editable(tester, MailSettingsForm.lifetimeFieldKey).focusNode),
      );
    });

    testWidgets('a password button with focus hands it to the field before '
        'it when the role may no longer save', (tester) async {
      await pumpForm(tester);
      buttonNode(tester, MailSettingsForm.removePasswordKey).requestFocus();
      await tester.pump();

      await pumpForm(tester, maySave: false);

      expect(
        focused(),
        same(editable(tester, MailSettingsForm.userFieldKey).focusNode),
      );
    });
  });

  group('edits and new values from the server', () {
    testWidgets('every edit is reported', (tester) async {
      await pumpForm(tester);

      await enter(tester, MailSettingsForm.userFieldKey, 'relay');

      expect(edits, greaterThan(0));
    });

    testWidgets('the test panel learns of unsaved changes, half-typed numbers '
        'included', (tester) async {
      await pumpForm(tester);
      expect(panelText(tester), 'unsaved: false');

      await enter(tester, MailSettingsForm.portFieldKey, '25x');
      expect(panelText(tester), 'unsaved: true');

      await enter(tester, MailSettingsForm.portFieldKey, ' 587 ');
      expect(panelText(tester), 'unsaved: false');

      await enter(tester, MailSettingsForm.lifetimeFieldKey, '');
      expect(panelText(tester), 'unsaved: true');

      await enter(tester, MailSettingsForm.lifetimeFieldKey, '1440');
      await enter(tester, MailSettingsForm.userFieldKey, ' mailer ');
      expect(panelText(tester), 'unsaved: false');
    });

    testWidgets('its own save landing takes the saved values, returns the '
        'password to kept, and is not an edit, so "saved" stays', (
      tester,
    ) async {
      await pumpForm(tester, settings: _unset);
      await enter(tester, MailSettingsForm.userFieldKey, '  relay  ');
      await enter(tester, MailSettingsForm.passwordFieldKey, 'secret');
      await save(tester);
      expect(saves, [
        const SystemSettingsPatch(
          smtpUser: SettingValue.set('relay'),
          smtpPassword: SettingValue.set('secret'),
        ),
      ]);
      await pumpForm(tester, settings: _unset, saving: true, settle: false);
      final editsBefore = edits;

      await pumpForm(
        tester,
        settings: _settings(host: null, user: 'relay', from: null),
        revision: 2,
        saved: true,
      );

      expect(textOf(tester, MailSettingsForm.userFieldKey), 'relay');
      expect(find.text(_savedPasswordCopy), findsOneWidget);
      expect(find.byKey(MailSettingsForm.passwordFieldKey), findsNothing);
      expect(edits, editsBefore);
      expect(find.text(_savedCopy), findsOneWidget);
      expect(panelText(tester), 'unsaved: false');
    });

    testWidgets("another group's save landing keeps unsaved mail edits and "
        "the password's state", (tester) async {
      await pumpForm(tester);
      await enter(tester, MailSettingsForm.userFieldKey, 'relay');
      await tapKey(tester, MailSettingsForm.removePasswordKey);

      await pumpForm(
        tester,
        settings: _settings(
          linking: ProviderLinkingPolicy.automaticWhenVerified,
        ),
        revision: 2,
      );

      expect(textOf(tester, MailSettingsForm.userFieldKey), 'relay');
      expect(find.text(_removingCopy), findsOneWidget);
      expect(panelText(tester), 'unsaved: true');
    });

    testWidgets('a save after new values were kept out sends only what was '
        'edited, not the fields left showing the old values', (tester) async {
      await pumpForm(tester);
      await enter(tester, MailSettingsForm.userFieldKey, 'relay');
      // Another admin changed the From; another group's save brings it,
      // and the unsaved user name keeps it out of the form.
      await pumpForm(
        tester,
        settings: _settings(from: 'admin@other.org'),
        revision: 2,
      );

      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(smtpUser: SettingValue.set('relay')),
      ]);
    });

    testWidgets('an edit put back after new values were kept out leaves '
        'nothing unsaved', (tester) async {
      await pumpForm(tester);
      await enter(tester, MailSettingsForm.userFieldKey, 'relay');
      await pumpForm(
        tester,
        settings: _settings(from: 'admin@other.org'),
        revision: 2,
      );

      await enter(tester, MailSettingsForm.userFieldKey, 'mailer');

      expect(panelText(tester), 'unsaved: false');
    });

    testWidgets('new values with nothing unsaved are taken', (tester) async {
      await pumpForm(tester);

      await pumpForm(
        tester,
        settings: _settings(host: 'mail.other.org', port: 465),
        revision: 2,
      );

      expect(
        textOf(tester, MailSettingsForm.hostFieldKey),
        'mail.other.org',
      );
      expect(textOf(tester, MailSettingsForm.portFieldKey), '465');
      expect(edits, 0);
      expect(panelText(tester), 'unsaved: false');
    });

    testWidgets('an edit after new values were taken is reported, even one '
        'that puts back the value taken', (tester) async {
      await pumpForm(tester);
      await pumpForm(
        tester,
        settings: _settings(host: 'mail.other.org'),
        revision: 2,
      );

      await enter(tester, MailSettingsForm.hostFieldKey, 'mail.other.or');
      final afterFirst = edits;
      await enter(tester, MailSettingsForm.hostFieldKey, 'mail.other.org');

      expect(afterFirst, greaterThan(0));
      expect(edits, greaterThan(afterFirst));
    });
  });

  testWidgets('fits a 320dp window at 200% text, and Save scrolls into '
      'view', (tester) async {
    tester.view
      ..physicalSize = const Size(320, 480)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpForm(
      tester,
      settings: _settings(security: SmtpSecurity.none),
      failure: SettingsSaveFailure.rejected,
      testPanelBuilder: (context, {required hasUnsavedChanges}) =>
          MailTestPanel(
            state: const MailTestNoResult(attempt: 1),
            hasUnsavedChanges: true,
            mailConfigured: true,
            onSend: () {},
          ),
    );
    await tapKey(tester, MailSettingsForm.removePasswordKey);
    await tester.ensureVisible(find.byKey(MailSettingsForm.saveKey));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final saveButton = tester.getRect(find.byKey(MailSettingsForm.saveKey));
    expect(saveButton.top, greaterThanOrEqualTo(0));
    expect(saveButton.bottom, lessThanOrEqualTo(480));
  });
}
