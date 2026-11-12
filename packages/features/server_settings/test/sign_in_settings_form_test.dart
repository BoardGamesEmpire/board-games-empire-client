import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:server_settings/server_settings.dart';
import 'package:server_settings/src/widgets/sign_in_settings_form.dart';
import 'package:ui/ui.dart';

import 'support/harness.dart';

SystemSettings _settings([
  ProviderLinkingPolicy linking = ProviderLinkingPolicy.signedIn,
]) => SystemSettings(
  id: 'settings-1',
  smtpHost: 'smtp.example.com',
  smtpPort: 587,
  smtpSecurity: SmtpSecurity.startTls,
  smtpUser: null,
  smtpPasswordSet: false,
  mailFromAddress: 'games@example.com',
  passwordResetLinkLifetimeMinutes: 1440,
  allowPasswordResets: true,
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
const _savedCopy = 'Sign-in settings saved.';
const _rejectedCopy =
    'The server refused one of these values. Check them and try again.';
const _otherSavingCopy = 'Available when the other save finishes.';

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
      SignInSettingsForm(
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
      offline: offline,
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Finder policy() => find.byKey(SignInSettingsForm.policyFieldKey);

  Finder inPolicy(String text) =>
      find.descendant(of: policy(), matching: find.text(text));

  BgeDropdownField<ProviderLinkingPolicy> policyField(WidgetTester tester) =>
      tester.widget<BgeDropdownField<ProviderLinkingPolicy>>(policy());

  Future<void> pick(WidgetTester tester, String label) async {
    await tester.ensureVisible(policy());
    await tester.pumpAndSettle();
    await tester.tap(policy());
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(SignInSettingsForm.saveKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SignInSettingsForm.saveKey));
    await tester.pumpAndSettle();
  }

  Finder saveButtonFinder() => find.descendant(
    of: find.byKey(SignInSettingsForm.saveKey),
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
        of: find.byType(SignInSettingsForm),
        matching: find.byType(Text),
      )
      .evaluate()
      .length;

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
        find.byKey(SignInSettingsForm.warningKey),
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
    testWidgets('a role that may not save sees the field read-only and no '
        'Save', (tester) async {
      await pumpForm(tester, maySave: false);

      expect(policyField(tester).readOnly, isTrue);
      expect(find.text(_signedInCopy), findsOneWidget);
      expect(find.byKey(SignInSettingsForm.saveKey), findsNothing);
    });

    testWidgets('losing save access puts back the saved policy, and is not '
        'an edit', (tester) async {
      await pumpForm(tester);
      await pick(tester, _automaticLabel);
      final editsBefore = edits;

      await pumpForm(tester, maySave: false);

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

      expect(find.byKey(SignInSettingsForm.saveKey), findsNothing);
      expect(find.text('Sign-in settings not saved'), findsOneWidget);
      expect(
        find.text("Your role can't change the server's settings."),
        findsOneWidget,
      );
    });

    testWidgets('while saving, the field goes read-only and Save says so', (
      tester,
    ) async {
      await pumpForm(tester, saving: true, settle: false);

      expect(policyField(tester).readOnly, isTrue);
      expect(find.text('Saving…'), findsOneWidget);
    });

    testWidgets('Save is disabled while the other group saves, with the '
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
        tester.getSemantics(find.byKey(SignInSettingsForm.saveKey)).hint,
        _otherSavingCopy,
      );
      expect(textsInForm(), textsAtRest);
      // One tree shape: the hint comes and goes, no wrapper does.
      expect(tester.state(saveButtonFinder()), same(buttonAtRest));
      handle.dispose();
    });

    testWidgets('offline while the other group saves, the offline reason is '
        "Save's hint", (tester) async {
      final handle = tester.ensureSemantics();
      await pumpForm(tester, offline: true, otherGroupSaving: true);

      expect(
        tester.getSemantics(find.byKey(SignInSettingsForm.saveKey)).hint,
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
        tester.getSemantics(find.byKey(SignInSettingsForm.saveKey)).hint,
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
            matching: find.text('Sign-in settings not saved'),
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
      final banner = tester.getRect(find.byKey(SignInSettingsForm.savedKey));
      final saveRect = tester.getRect(find.byKey(SignInSettingsForm.saveKey));
      expect(banner.bottom, lessThan(saveRect.top));
    });

    testWidgets('Save with focus hands it to the field when the role may no '
        'longer save', (tester) async {
      await pumpForm(tester);
      Focus.of(
        tester.element(find.text('Save sign-in settings')),
        createDependency: false,
      ).requestFocus();
      await tester.pump();
      expect(focusIsIn(find.byKey(SignInSettingsForm.saveKey)), isTrue);

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
