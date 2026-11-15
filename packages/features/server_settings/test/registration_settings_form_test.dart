import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:server_settings/server_settings.dart';
import 'package:server_settings/src/widgets/registration_settings_form.dart';
import 'package:server_settings/src/widgets/settings_group_binding.dart';
import 'package:ui/ui.dart';

import 'support/fake_system_settings_remote.dart';
import 'support/harness.dart';

SystemSettings _settings([
  ProviderLinkingPolicy linking = ProviderLinkingPolicy.signedIn,
]) => settingsFixture(
  smtpHost: 'smtp.example.com',
  mailFromAddress: 'games@example.com',
  providerLinkingPolicy: linking,
);

const _signedInLabel = 'Only from a signed-in account';
const _automaticLabel = 'Automatically, when both have verified the email';
const _unknownCopy = "A setting this app doesn't know";
const _signedInCopy =
    'People link a provider from their sign-in methods while signed in.';
const _warningCopy =
    "Anyone who controls a registered user's verified email at a sign-in "
    'provider can sign in as that user, the Owner included.';
const _resetsSubtitleCopy =
    'Reset links go out by email, through the Mail settings.';
const _savedCopy = 'Registration and sign-in settings saved.';
const _notSavedCopy = 'Registration and sign-in settings not saved';
const _rejectedCopy =
    'The server refused one of these values. Check them and try again.';
const _otherSavingCopy = 'Available when the save in progress finishes.';

const List<Key> _switchKeys = [
  RegistrationSettingsForm.signUpsSwitchKey,
  RegistrationSettingsForm.usernameChangeSwitchKey,
  RegistrationSettingsForm.passwordResetsSwitchKey,
];

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
    bool settle = true,
  }) async {
    await pumpOnPage(
      tester,
      RegistrationSettingsForm(
        binding: SettingsGroupBinding(
          settings: settings ?? _settings(),
          revision: revision,
          maySave: maySave,
          saving: saving,
          otherGroupSaving: otherGroupSaving,
          failure: failure,
          saved: saved,
          onSave: saves.add,
          onEdited: () => edits++,
        ),
      ),
      offline: offline,
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Finder policy() => find.byKey(RegistrationSettingsForm.policyFieldKey);

  Finder inPolicy(String text) =>
      find.descendant(of: policy(), matching: find.text(text));

  BgeDropdownField<ProviderLinkingPolicy> policyField(WidgetTester tester) =>
      tester.widget<BgeDropdownField<ProviderLinkingPolicy>>(policy());

  BgeSwitchField switchField(WidgetTester tester, Key key) =>
      tester.widget<BgeSwitchField>(
        find.ancestor(
          of: find.byKey(key),
          matching: find.byType(BgeSwitchField),
        ),
      );

  bool switchValue(WidgetTester tester, Key key) =>
      tester.widget<SwitchListTile>(find.byKey(key)).value;

  EditableText lifetimeField(WidgetTester tester) =>
      tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(RegistrationSettingsForm.lifetimeFieldKey),
          matching: find.byType(EditableText),
        ),
      );

  Future<void> pick(WidgetTester tester, String label) async {
    await tester.ensureVisible(policy());
    await tester.pumpAndSettle();
    await tester.tap(policy());
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  Future<void> enterLifetime(WidgetTester tester, String text) async {
    await tester.ensureVisible(
      find.byKey(RegistrationSettingsForm.lifetimeFieldKey),
    );
    await tester.enterText(
      find.byKey(RegistrationSettingsForm.lifetimeFieldKey),
      text,
    );
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) =>
      tapKey(tester, RegistrationSettingsForm.saveKey);

  Finder saveButtonFinder() => find.descendant(
    of: find.byKey(RegistrationSettingsForm.saveKey),
    matching: find.byType(FilledButton),
  );

  FilledButton saveButton(WidgetTester tester) =>
      tester.widget<FilledButton>(saveButtonFinder());

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

  int textsInForm() => find
      .descendant(
        of: find.byType(RegistrationSettingsForm),
        matching: find.byType(Text),
      )
      .evaluate()
      .length;

  group('the controls', () {
    testWidgets('shows the five controls in order', (tester) async {
      await pumpForm(tester);

      expect(find.text('Let people create an account'), findsOneWidget);
      expect(find.text('Let people change their username'), findsOneWidget);
      expect(
        find.text('Let people reset a forgotten password'),
        findsOneWidget,
      );
      expect(find.text('Reset link lifetime, in minutes'), findsOneWidget);
      expect(find.text('Linking a sign-in provider'), findsOneWidget);
      final tops = [
        ..._switchKeys,
        RegistrationSettingsForm.lifetimeFieldKey,
        RegistrationSettingsForm.policyFieldKey,
      ].map((key) => tester.getRect(find.byKey(key)).top).toList();
      for (var i = 1; i < tops.length; i++) {
        expect(tops[i], greaterThan(tops[i - 1]), reason: 'control $i');
      }
    });

    testWidgets('the switches show the saved values', (tester) async {
      await pumpForm(
        tester,
        settings: settingsFixture(
          allowUserRegistration: false,
          allowPasswordResets: false,
        ),
      );

      expect(
        switchValue(tester, RegistrationSettingsForm.signUpsSwitchKey),
        isFalse,
      );
      expect(
        switchValue(tester, RegistrationSettingsForm.usernameChangeSwitchKey),
        isTrue,
      );
      expect(
        switchValue(tester, RegistrationSettingsForm.passwordResetsSwitchKey),
        isFalse,
      );
    });

    testWidgets('the resets switch says reset links go out by email', (
      tester,
    ) async {
      await pumpForm(tester);

      expect(
        find.descendant(
          of: find.byKey(RegistrationSettingsForm.passwordResetsSwitchKey),
          matching: find.text(_resetsSubtitleCopy),
        ),
        findsOneWidget,
      );
    });

    for (final (name, key, patch) in [
      (
        'sign-ups',
        RegistrationSettingsForm.signUpsSwitchKey,
        const SystemSettingsPatch(allowUserRegistration: false),
      ),
      (
        'username change',
        RegistrationSettingsForm.usernameChangeSwitchKey,
        const SystemSettingsPatch(allowUsernameChange: false),
      ),
      (
        'password resets',
        RegistrationSettingsForm.passwordResetsSwitchKey,
        const SystemSettingsPatch(allowPasswordResets: false),
      ),
    ]) {
      testWidgets('the $name switch is saved alone', (tester) async {
        await pumpForm(tester);

        await tapKey(tester, key);
        await save(tester);

        expect(saves, [patch]);
      });
    }
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

      await enterLifetime(tester, '90');

      expect(
        find.text('1 hour, 30 minutes. From 15 minutes to 7 days.'),
        findsOneWidget,
      );
    });

    testWidgets('the limits still show while what is typed has no reading', (
      tester,
    ) async {
      await pumpForm(tester);

      await enterLifetime(tester, '1');

      expect(find.text('From 15 minutes to 7 days.'), findsOneWidget);
    });

    testWidgets('a lifetime out of range is refused on the form', (
      tester,
    ) async {
      await pumpForm(tester);

      await enterLifetime(tester, '14');
      await save(tester);

      expect(saves, isEmpty);
      expect(
        find.text('Enter a whole number of minutes from 15 to 10080 (7 days).'),
        findsOneWidget,
      );
    });

    testWidgets('a changed lifetime is saved', (tester) async {
      await pumpForm(tester);

      await enterLifetime(tester, '60');
      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(passwordResetLinkLifetimeMinutes: 60),
      ]);
    });
  });

  group('the linking policy', () {
    testWidgets('shows the saved policy and what it means', (tester) async {
      await pumpForm(tester);

      expect(find.text('Linking a sign-in provider'), findsOneWidget);
      expect(inPolicy(_signedInLabel), findsOneWidget);
      expect(find.text(_signedInCopy), findsOneWidget);
      expect(find.text(_warningCopy), findsNothing);
    });

    testWidgets('choosing Automatically shows the warning, heard and not '
        'scrolled to, in place of the description', (tester) async {
      await pumpForm(tester);

      await pick(tester, _automaticLabel);

      expect(inPolicy(_automaticLabel), findsOneWidget);
      expect(find.text(_signedInCopy), findsNothing);
      final warning = tester.widget<BgeInlineBanner>(
        find.byKey(RegistrationSettingsForm.warningKey),
      );
      expect(warning.message, _warningCopy);
      expect(warning.tone, BgeBannerTone.warning);
      expect(warning.announce, isTrue);
      expect(warning.reveal, isFalse);
    });

    testWidgets('a saved Automatically shows the warning', (tester) async {
      await pumpForm(
        tester,
        settings: _settings(ProviderLinkingPolicy.automaticWhenVerified),
      );

      expect(inPolicy(_automaticLabel), findsOneWidget);
      expect(find.text(_warningCopy), findsOneWidget);
      expect(find.text(_signedInCopy), findsNothing);
    });

    testWidgets('the description is a live region, so a pick back to it is '
        'heard', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpForm(
        tester,
        settings: _settings(ProviderLinkingPolicy.automaticWhenVerified),
      );

      await pick(tester, _signedInLabel);

      expect(
        tester.getSemantics(find.text(_signedInCopy)),
        isSemantics(isLiveRegion: true, label: _signedInCopy),
      );
      handle.dispose();
    });

    testWidgets('Save sends the policy alone', (tester) async {
      await pumpForm(tester);
      await pick(tester, _automaticLabel);

      await save(tester);

      expect(saves, [
        const SystemSettingsPatch(
          providerLinkingPolicy: ProviderLinkingPolicy.automaticWhenVerified,
        ),
      ]);
    });

    testWidgets('Save with nothing changed sends an empty patch', (
      tester,
    ) async {
      await pumpForm(tester);
      await pick(tester, _automaticLabel);
      await pick(tester, _signedInLabel);

      await save(tester);

      expect(saves, [const SystemSettingsPatch()]);
    });

    testWidgets('a policy this app does not know shows as such, with no '
        'description, and a save leaves it alone', (tester) async {
      await pumpForm(
        tester,
        settings: _settings(ProviderLinkingPolicy.unknown),
      );

      expect(inPolicy(_unknownCopy), findsOneWidget);
      expect(find.text(_signedInCopy), findsNothing);
      expect(find.text(_warningCopy), findsNothing);

      await save(tester);
      expect(saves, [const SystemSettingsPatch()]);

      await pick(tester, _signedInLabel);
      await save(tester);
      expect(
        saves.last,
        const SystemSettingsPatch(
          providerLinkingPolicy: ProviderLinkingPolicy.signedIn,
        ),
      );
    });
  });

  group('access and saving', () {
    testWidgets('a role that may not save sees every control read-only and '
        'no Save', (tester) async {
      await pumpForm(tester, maySave: false);

      for (final key in _switchKeys) {
        expect(switchField(tester, key).readOnly, isTrue, reason: '$key');
      }
      expect(lifetimeField(tester).readOnly, isTrue);
      expect(policyField(tester).readOnly, isTrue);
      expect(find.text(_signedInCopy), findsOneWidget);
      expect(find.byKey(RegistrationSettingsForm.saveKey), findsNothing);
    });

    testWidgets('losing save access puts back the saved values, and is not '
        'an edit', (tester) async {
      await pumpForm(tester);
      await tapKey(tester, RegistrationSettingsForm.signUpsSwitchKey);
      await enterLifetime(tester, '60');
      await pick(tester, _automaticLabel);
      final editsBefore = edits;

      await pumpForm(tester, maySave: false);

      expect(
        switchValue(tester, RegistrationSettingsForm.signUpsSwitchKey),
        isTrue,
      );
      expect(lifetimeField(tester).controller.text, '1440');
      expect(inPolicy(_signedInLabel), findsOneWidget);
      expect(find.text(_warningCopy), findsNothing);
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

      expect(find.byKey(RegistrationSettingsForm.saveKey), findsNothing);
      expect(find.text(_notSavedCopy), findsOneWidget);
      expect(
        find.text("Your role can't change the server's settings."),
        findsOneWidget,
      );
    });

    testWidgets('while saving, the controls go read-only and Save says so', (
      tester,
    ) async {
      await pumpForm(tester, saving: true, settle: false);

      for (final key in _switchKeys) {
        expect(switchField(tester, key).readOnly, isTrue, reason: '$key');
      }
      expect(lifetimeField(tester).readOnly, isTrue);
      expect(policyField(tester).readOnly, isTrue);
      expect(find.text('Saving…'), findsOneWidget);
    });

    testWidgets('Save is disabled while another group saves, with the '
        'reason as its hint and no line drawn', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpForm(tester);
      await pick(tester, _automaticLabel);
      final textsAtRest = textsInForm();
      final buttonAtRest = tester.state(saveButtonFinder());

      await pumpForm(tester, otherGroupSaving: true);
      await save(tester);

      expect(saves, isEmpty);
      expect(saveButton(tester).onPressed, isNull);
      expect(policyField(tester).readOnly, isFalse);
      expect(
        tester.getSemantics(find.byKey(RegistrationSettingsForm.saveKey)).hint,
        _otherSavingCopy,
      );
      expect(textsInForm(), textsAtRest);
      // One tree shape: the hint comes and goes, no wrapper does.
      expect(tester.state(saveButtonFinder()), same(buttonAtRest));
      handle.dispose();
    });

    testWidgets('offline while another group saves, the offline reason is '
        "Save's hint", (tester) async {
      final handle = tester.ensureSemantics();
      await pumpForm(tester, offline: true, otherGroupSaving: true);

      expect(
        tester.getSemantics(find.byKey(RegistrationSettingsForm.saveKey)).hint,
        onlineOnlyCopy,
      );
      handle.dispose();
    });

    testWidgets('offline, Save is disabled and the reason is drawn once, '
        'Save carrying it as its hint', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpForm(tester, offline: true);
      await pick(tester, _automaticLabel);

      await save(tester);

      expect(saves, isEmpty);
      expect(find.text(onlineOnlyCopy), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(RegistrationSettingsForm.saveKey)).hint,
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
      (SettingsSaveFailure.rejected, _rejectedCopy),
      (
        SettingsSaveFailure.failed,
        "Couldn't reach the server. Check your connection and try again.",
      ),
      // Only the Mail group can be asked for a password: should the server
      // say so here, it refused the values.
      (SettingsSaveFailure.passwordRequired, _rejectedCopy),
    ]) {
      testWidgets('a save that failed as ${failure.name} says so above Save', (
        tester,
      ) async {
        await pumpForm(tester, failure: failure);

        expect(
          find.descendant(
            of: find.byType(BgeFormActions),
            matching: find.text(_notSavedCopy),
          ),
          findsOneWidget,
        );
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
      final banner = tester.getRect(
        find.byKey(RegistrationSettingsForm.savedKey),
      );
      final saveRect = tester.getRect(
        find.byKey(RegistrationSettingsForm.saveKey),
      );
      expect(banner.bottom, lessThan(saveRect.top));
    });

    testWidgets('Save with focus hands it to the linking policy, the last '
        'field, when the role may no longer save', (tester) async {
      await pumpForm(tester);
      Focus.of(
        tester.element(find.text('Save registration and sign-in settings')),
        createDependency: false,
      ).requestFocus();
      await tester.pump();
      expect(focusIsIn(find.byKey(RegistrationSettingsForm.saveKey)), isTrue);

      await pumpForm(tester, maySave: false);

      expect(focusIsIn(policy()), isTrue);
    });
  });

  group('edits and new values from the server', () {
    testWidgets('a pick is reported as an edit', (tester) async {
      await pumpForm(tester);

      await pick(tester, _automaticLabel);

      expect(edits, greaterThan(0));
    });

    testWidgets('a switch toggled is reported as an edit', (tester) async {
      await pumpForm(tester);

      await tapKey(tester, RegistrationSettingsForm.usernameChangeSwitchKey);

      expect(edits, greaterThan(0));
    });

    testWidgets('its own save landing takes the saved policy and is not an '
        'edit, so "saved" stays', (tester) async {
      await pumpForm(tester);
      await pick(tester, _automaticLabel);
      await save(tester);
      await pumpForm(tester, saving: true, settle: false);
      final editsBefore = edits;

      await pumpForm(
        tester,
        settings: _settings(ProviderLinkingPolicy.automaticWhenVerified),
        revision: 2,
        saved: true,
      );

      expect(inPolicy(_automaticLabel), findsOneWidget);
      expect(edits, editsBefore);
      expect(find.text(_savedCopy), findsOneWidget);
    });

    testWidgets("another group's save landing keeps an unsaved pick", (
      tester,
    ) async {
      await pumpForm(tester);
      await pick(tester, _automaticLabel);
      final editsBefore = edits;

      await pumpForm(tester, revision: 2);

      expect(inPolicy(_automaticLabel), findsOneWidget);
      expect(find.text(_warningCopy), findsOneWidget);
      expect(edits, editsBefore);
    });

    testWidgets("another group's save landing keeps a half-typed lifetime", (
      tester,
    ) async {
      await pumpForm(tester);
      await enterLifetime(tester, '6');

      await pumpForm(tester, revision: 2);

      expect(lifetimeField(tester).controller.text, '6');
    });

    testWidgets('new values with nothing unsaved are taken, and are not an '
        'edit', (tester) async {
      await pumpForm(tester);

      await pumpForm(
        tester,
        settings: _settings(ProviderLinkingPolicy.automaticWhenVerified),
        revision: 2,
      );

      expect(inPolicy(_automaticLabel), findsOneWidget);
      expect(edits, 0);
    });

    testWidgets('a pick after new values were taken is reported, even one '
        'that puts back the value taken', (tester) async {
      await pumpForm(tester);
      await pumpForm(
        tester,
        settings: _settings(ProviderLinkingPolicy.automaticWhenVerified),
        revision: 2,
      );

      await pick(tester, _signedInLabel);
      final afterFirst = edits;
      await pick(tester, _automaticLabel);

      expect(afterFirst, greaterThan(0));
      expect(edits, greaterThan(afterFirst));
    });
  });
}
