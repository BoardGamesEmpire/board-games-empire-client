import 'package:bge_test_support/access.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:server_settings/server_settings.dart';
import 'package:server_settings/src/widgets/contributions_settings_form.dart';
import 'package:server_settings/src/widgets/general_settings_form.dart';
import 'package:server_settings/src/widgets/invitations_settings_form.dart';
import 'package:server_settings/src/widgets/mail_settings_form.dart';
import 'package:server_settings/src/widgets/mail_test_panel.dart';
import 'package:server_settings/src/widgets/registration_settings_form.dart';
import 'package:server_settings/src/widgets/retention_settings_form.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'support/fake_notification_remote.dart';
import 'support/fake_system_settings_remote.dart';
import 'support/harness.dart';

CallerAccess _access({required AccessExtent update}) => CallerAccess.known({
  ResourceType.systemSetting: ResourceAccess(
    create: AccessExtent.none,
    read: AccessExtent.all,
    update: update,
    delete: AccessExtent.none,
    manage: AccessExtent.none,
  ),
});

final CallerAccess _admin = _access(update: AccessExtent.all);

/// Reads every setting and changes none.
final CallerAccess _moderator = _access(update: AccessExtent.none);

/// Mail set up, with no password saved.
SystemSettings _settings({
  String? user = 'mailer',
  ProviderLinkingPolicy linking = ProviderLinkingPolicy.signedIn,
  String name = 'Board Games Empire',
  Reach household = Reach.public,
  Reach event = Reach.public,
  bool approval = false,
  int feedbackDays = 90,
  bool redaction = true,
  int? auditDays,
}) => settingsFixture(
  smtpHost: 'smtp.example.com',
  smtpUser: user,
  mailFromAddress: 'games@example.com',
  providerLinkingPolicy: linking,
  name: name,
  householdInviteePolicy: household,
  eventInviteePolicy: event,
  requireContributionApproval: approval,
  feedbackReportRetentionDays: feedbackDays,
  feedbackReportServerRedactionEnabled: redaction,
  auditLogRetentionDays: auditDays,
);

/// Every group showing all it can: the linking warning, the longest invitee
/// descriptions, the redaction warning and the audit days.
SystemSettings _everythingShown() => _settings(
  linking: ProviderLinkingPolicy.automaticWhenVerified,
  household: Reach.friendsOfFriends,
  event: Reach.friendsOfFriends,
  redaction: false,
  auditDays: 365,
);

/// A settings group as these tests drive it: its heading and form, its Save,
/// its last field, an edit that gives it something to save, and the
/// settings that save lands with.
typedef _Group = ({
  String title,
  Type form,
  Key save,
  Key lastField,
  Future<void> Function(WidgetTester tester) edit,
  SystemSettings landed,
});

const _title = 'Server settings';
const _loadFailedCopy = "Couldn't load the server's settings.";
const _refusedCopy = "Your role can't view the server's settings.";
const _readOnlyCopy = 'Your role can view these settings but not change them.';
const _automaticLabel = 'Automatically, when both have verified the email';
const _warningCopy =
    "Anyone who controls a registered user's verified email at a sign-in "
    'provider can sign in as that user, the Owner included.';
const _registrationTitle = 'Registration and sign-in';
const _mailSavedCopy = 'Mail settings saved.';
const _registrationSavedCopy = 'Registration and sign-in settings saved.';
const _contributionsSavedCopy = 'Contribution settings saved.';
const _redactionOffCopy =
    'Feedback reports are stored as they arrive, and the server relies on '
    'each app to redact them.';
const _waitingCopy =
    "Test email queued for your address. Waiting for the mail server's answer…";
const _sentCopy = 'The test email was sent. Check your inbox.';

/// The app around the screen, as the shell hosts it: the connectivity scope
/// sits above the navigator, so it reaches every route.
Widget _app(
  Widget home, {
  ThemeData? theme,
  GlobalKey<NavigatorState>? navigatorKey,
}) => MaterialApp(
  navigatorKey: navigatorKey,
  theme: theme ?? BgeTheme.light(),
  localizationsDelegates: ServerSettingsLocalizations.localizationsDelegates,
  supportedLocales: ServerSettingsLocalizations.supportedLocales,
  builder: (context, child) => BgeConnectivityScope(
    offline: false,
    noticeShowing: false,
    onlineOnlyReason: onlineOnlyCopy,
    child: child!,
  ),
  home: home,
);

void main() {
  late FakeSystemSettingsRemote remote;
  late FakeNotificationRemote notifications;
  late FakeCallerAccessRepository access;

  setUp(() {
    remote = FakeSystemSettingsRemote();
    notifications = FakeNotificationRemote([<UnreadNotification>[]]);
    access = FakeCallerAccessRepository(_admin);
  });

  tearDown(() => access.dispose());

  Widget screen() => ServerSettingsScreen(
    remote: remote,
    notifications: notifications,
    access: access,
  );

  /// Pumps the screen and answers its read with [settings].
  Future<void> pumpScreen(
    WidgetTester tester, {
    SystemSettings? settings,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(_app(screen(), theme: theme));
    await tester.pump();
    remote.fetches.single.complete(settings ?? _settings());
    await tester.pumpAndSettle();
  }

  Finder field(Key key) =>
      find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

  EditableText editable(WidgetTester tester, Key key) =>
      tester.widget<EditableText>(field(key));

  Future<void> enter(WidgetTester tester, Key key, String text) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.enterText(find.byKey(key), text);
    await tester.pumpAndSettle();
  }

  /// Opens the menu of the dropdown at [key] and picks [label].
  Future<void> pick(WidgetTester tester, Key key, String label) async {
    final menu = find.byKey(key);
    await tester.ensureVisible(menu);
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> pickAutomatic(WidgetTester tester) =>
      pick(tester, RegistrationSettingsForm.policyFieldKey, _automaticLabel);

  Future<void> toggle(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  /// Presses [key] and pumps one frame: a save's spinner never settles.
  Future<void> press(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pump();
    await tester.pump();
  }

  FilledButton saveButton(WidgetTester tester, Key key) =>
      tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(FilledButton),
        ),
      );

  Finder bannerWith(String text) => find.ancestor(
    of: find.text(text),
    matching: find.byType(BgeInlineBanner),
  );

  /// Whether keyboard focus is on the [Focus] nearest above what [finder]
  /// finds: its own node, not a scope further up.
  bool focusIsOn(WidgetTester tester, Finder finder) => tester
      .widget<Focus>(
        find.ancestor(of: finder, matching: find.byType(Focus)).first,
      )
      .focusNode!
      .hasPrimaryFocus;

  /// The six groups, in the order the page lists them (#894).
  final groups = <_Group>[
    (
      title: 'General',
      form: GeneralSettingsForm,
      save: GeneralSettingsForm.saveKey,
      lastField: GeneralSettingsForm.nameFieldKey,
      edit: (tester) =>
          enter(tester, GeneralSettingsForm.nameFieldKey, 'Game night'),
      landed: _settings(name: 'Game night'),
    ),
    (
      title: _registrationTitle,
      form: RegistrationSettingsForm,
      save: RegistrationSettingsForm.saveKey,
      lastField: RegistrationSettingsForm.policyFieldKey,
      edit: pickAutomatic,
      landed: _settings(linking: ProviderLinkingPolicy.automaticWhenVerified),
    ),
    (
      title: 'Mail',
      form: MailSettingsForm,
      save: MailSettingsForm.saveKey,
      lastField: MailSettingsForm.fromFieldKey,
      edit: (tester) => enter(tester, MailSettingsForm.userFieldKey, 'relay'),
      landed: _settings(user: 'relay'),
    ),
    (
      title: 'Invitations',
      form: InvitationsSettingsForm,
      save: InvitationsSettingsForm.saveKey,
      lastField: InvitationsSettingsForm.eventFieldKey,
      edit: (tester) =>
          pick(tester, InvitationsSettingsForm.householdFieldKey, 'Friends'),
      landed: _settings(household: Reach.friends),
    ),
    (
      title: 'Contributions',
      form: ContributionsSettingsForm,
      save: ContributionsSettingsForm.saveKey,
      lastField: ContributionsSettingsForm.reclaimFieldKey,
      edit: (tester) =>
          toggle(tester, ContributionsSettingsForm.approvalSwitchKey),
      landed: _settings(approval: true),
    ),
    (
      title: 'Data retention',
      form: RetentionSettingsForm,
      save: RetentionSettingsForm.saveKey,
      lastField: RetentionSettingsForm.auditDaysFieldKey,
      edit: (tester) =>
          enter(tester, RetentionSettingsForm.feedbackDaysFieldKey, '30'),
      landed: _settings(feedbackDays: 30),
    ),
  ];

  group('loading', () {
    testWidgets('waits for the read, then shows the six groups in order', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(screen()));
      await tester.pump();

      expect(find.text(_title), findsOneWidget);
      expect(find.byKey(ServerSettingsScreen.loadingKey), findsOneWidget);
      for (final group in groups) {
        expect(find.byType(group.form), findsNothing, reason: group.title);
      }

      remote.fetches.single.complete(_settings());
      await tester.pumpAndSettle();

      expect(find.byKey(ServerSettingsScreen.loadingKey), findsNothing);
      expect(find.byKey(ServerSettingsScreen.readOnlyKey), findsNothing);
      // Each heading sits below the group before it, and above its own form.
      var above = double.negativeInfinity;
      for (final group in groups) {
        expect(find.byType(group.form), findsOneWidget, reason: group.title);
        final heading = tester.getRect(find.text(group.title));
        final form = tester.getRect(find.byType(group.form));
        expect(heading.top, greaterThan(above), reason: group.title);
        expect(heading.bottom, lessThan(form.top), reason: group.title);
        above = form.bottom;
      }
      for (final group in groups) {
        final heading = find.text(group.title);
        await tester.ensureVisible(heading);
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(heading),
          isSemantics(isHeader: true, label: group.title),
        );
      }
      handle.dispose();
    });

    testWidgets('a refused read says the role cannot view the settings, and '
        'offers no retry', (tester) async {
      await tester.pumpWidget(_app(screen()));
      await tester.pump();

      remote.fetches.single.completeError(
        const SystemSettingsForbiddenException('no', statusCode: 403),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ServerSettingsScreen.refusedKey), findsOneWidget);
      expect(find.text(_refusedCopy), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      expect(find.byType(MailSettingsForm), findsNothing);
    });

    testWidgets('a failed read offers a retry, which reads again with focus '
        'parked on the title', (tester) async {
      await tester.pumpWidget(_app(screen()));
      await tester.pump();

      remote.fetches.single.completeError(
        const SystemSettingsTransientException('down'),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ServerSettingsScreen.errorKey), findsOneWidget);
      expect(find.text(_loadFailedCopy), findsOneWidget);
      expect(find.text('Check your connection and try again.'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();

      expect(remote.fetches, hasLength(2));
      expect(find.byKey(ServerSettingsScreen.loadingKey), findsOneWidget);
      expect(focusIsOn(tester, find.text(_title)), isTrue);

      remote.fetches.last.complete(_settings());
      await tester.pumpAndSettle();

      expect(find.byType(MailSettingsForm), findsOneWidget);
      expect(find.byType(RegistrationSettingsForm), findsOneWidget);
      // The title stays through the read, and focus with it.
      expect(focusIsOn(tester, find.text(_title)), isTrue);
    });
  });

  group('access', () {
    testWidgets('a Moderator sees every group read-only, is told why at the '
        'top', (tester) async {
      final handle = tester.ensureSemantics();
      access.current = _moderator;
      await pumpScreen(tester, settings: _everythingShown());

      final banner = tester.widget<BgeInlineBanner>(
        find.byKey(ServerSettingsScreen.readOnlyKey),
      );
      expect(banner.message, _readOnlyCopy);
      expect(banner.reveal, isFalse);
      expect(
        tester.getRect(find.byKey(ServerSettingsScreen.readOnlyKey)).bottom,
        lessThan(tester.getRect(find.text(groups.first.title)).top),
      );
      for (final key in [
        GeneralSettingsForm.nameFieldKey,
        RegistrationSettingsForm.lifetimeFieldKey,
        MailSettingsForm.hostFieldKey,
        MailSettingsForm.portFieldKey,
        MailSettingsForm.userFieldKey,
        MailSettingsForm.fromFieldKey,
        ContributionsSettingsForm.reclaimFieldKey,
        RetentionSettingsForm.feedbackDaysFieldKey,
        RetentionSettingsForm.auditDaysFieldKey,
      ]) {
        expect(editable(tester, key).readOnly, isTrue, reason: '$key');
      }
      expect(
        tester
            .widget<BgeDropdownField<ProviderLinkingPolicy>>(
              find.byKey(RegistrationSettingsForm.policyFieldKey),
            )
            .readOnly,
        isTrue,
      );
      expect(
        tester
            .widget<BgeDropdownField<SmtpSecurity>>(
              find.byKey(MailSettingsForm.securityFieldKey),
            )
            .readOnly,
        isTrue,
      );
      for (final key in [
        InvitationsSettingsForm.householdFieldKey,
        InvitationsSettingsForm.eventFieldKey,
      ]) {
        expect(
          tester.widget<BgeDropdownField<Reach>>(find.byKey(key)).readOnly,
          isTrue,
          reason: '$key',
        );
      }
      // A switch reads as read-only, as assistive tech hears it.
      for (final key in [
        RegistrationSettingsForm.signUpsSwitchKey,
        RegistrationSettingsForm.usernameChangeSwitchKey,
        RegistrationSettingsForm.passwordResetsSwitchKey,
        ContributionsSettingsForm.approvalSwitchKey,
        RetentionSettingsForm.redactionSwitchKey,
        RetentionSettingsForm.auditSwitchKey,
      ]) {
        await tester.ensureVisible(find.byKey(key));
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(find.byKey(key)).flagsCollection.isReadOnly,
          isTrue,
          reason: '$key',
        );
      }
      for (final group in groups) {
        expect(find.byKey(group.save), findsNothing, reason: group.title);
      }
      expect(find.byKey(MailTestPanel.sendKey), findsNothing);
      expect(find.text('Send test email'), findsNothing);
      handle.dispose();
    });

    testWidgets('while access is unknown nothing is said about the role, and '
        'nothing can be saved', (tester) async {
      access.current = const CallerAccess.unknown();
      await pumpScreen(tester);

      expect(find.byKey(ServerSettingsScreen.readOnlyKey), findsNothing);
      expect(find.text(_readOnlyCopy), findsNothing);
      for (final group in groups) {
        expect(find.byKey(group.save), findsNothing, reason: group.title);
      }
      expect(find.byKey(MailTestPanel.sendKey), findsNothing);
    });

    testWidgets('an admin sees no read-only banner, and can save every group '
        'and send a test', (tester) async {
      await pumpScreen(tester);

      expect(find.byKey(ServerSettingsScreen.readOnlyKey), findsNothing);
      for (final group in groups) {
        expect(find.byKey(group.save), findsOneWidget, reason: group.title);
      }
      expect(find.byKey(MailTestPanel.sendKey), findsOneWidget);
    });
  });

  group('saving', () {
    testWidgets('choosing Automatically warns, Save sends the policy alone, '
        'and the landed save says so and stays', (tester) async {
      await pumpScreen(tester);

      await pickAutomatic(tester);
      expect(find.text(_warningCopy), findsOneWidget);

      await press(tester, RegistrationSettingsForm.saveKey);
      expect(remote.updateCalls, hasLength(1));
      expect(remote.updateCalls.single.id, 'settings-1');
      expect(
        remote.updateCalls.single.patch,
        const SystemSettingsPatch(
          providerLinkingPolicy: ProviderLinkingPolicy.automaticWhenVerified,
        ),
      );

      remote.updates.single.complete(
        _settings(linking: ProviderLinkingPolicy.automaticWhenVerified),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text(_registrationSavedCopy), findsOneWidget);
      expect(find.text(_warningCopy), findsOneWidget);
    });

    testWidgets('a Mail save that lands says so, and it stays', (
      tester,
    ) async {
      await pumpScreen(tester);
      await enter(tester, MailSettingsForm.userFieldKey, 'relay');

      await press(tester, MailSettingsForm.saveKey);
      expect(
        remote.updateCalls.single.patch,
        const SystemSettingsPatch(smtpUser: SettingValue.set('relay')),
      );
      remote.updates.single.complete(_settings(user: 'relay'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));

      expect(find.text(_mailSavedCopy), findsOneWidget);
      expect(
        editable(tester, MailSettingsForm.userFieldKey).controller.text,
        'relay',
      );
    });

    testWidgets('a Registration save that lands leaves unsaved Mail edits as '
        'typed', (tester) async {
      await pumpScreen(tester);
      await enter(tester, MailSettingsForm.userFieldKey, 'relay');
      await pickAutomatic(tester);

      await press(tester, RegistrationSettingsForm.saveKey);
      remote.updates.single.complete(
        _settings(linking: ProviderLinkingPolicy.automaticWhenVerified),
      );
      await tester.pumpAndSettle();

      expect(find.text(_registrationSavedCopy), findsOneWidget);
      expect(
        editable(tester, MailSettingsForm.userFieldKey).controller.text,
        'relay',
      );
    });

    testWidgets('a refused Registration save says so above its Save', (
      tester,
    ) async {
      await pumpScreen(tester);
      await pickAutomatic(tester);

      await press(tester, RegistrationSettingsForm.saveKey);
      remote.updates.single.completeError(
        const SystemSettingsForbiddenException('no', statusCode: 403),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Registration and sign-in settings not saved'),
        findsOneWidget,
      );
      expect(
        find.text("Your role can't change the server's settings."),
        findsOneWidget,
      );
      expect(find.text('Mail settings not saved'), findsNothing);
    });

    testWidgets("a refused save that takes the role's access puts back the "
        'saved values and still says the save failed', (tester) async {
      await pumpScreen(tester);
      await enter(tester, MailSettingsForm.userFieldKey, 'relay');

      await press(tester, MailSettingsForm.saveKey);
      remote.updates.single.completeError(
        const SystemSettingsForbiddenException('no', statusCode: 403),
      );
      await tester.pumpAndSettle();
      expect(access.refreshCount, 1);
      // What the refresh the refusal asked for finds.
      access.current = _moderator;
      await tester.pumpAndSettle();

      expect(find.text(_readOnlyCopy), findsOneWidget);
      final user = editable(tester, MailSettingsForm.userFieldKey);
      expect(user.controller.text, 'mailer');
      expect(user.readOnly, isTrue);
      expect(find.byKey(MailSettingsForm.saveKey), findsNothing);
      expect(find.text('Mail settings not saved'), findsOneWidget);
      expect(
        find.text("Your role can't change the server's settings."),
        findsOneWidget,
      );
    });

    group('saving any group disables every other Save', () {
      for (final saving in groups) {
        testWidgets('while ${saving.title} saves', (tester) async {
          await pumpScreen(tester);
          await saving.edit(tester);

          // An empty patch sends nothing, so the edit is what starts it.
          await press(tester, saving.save);
          expect(remote.updateCalls, hasLength(1));
          for (final other in groups.where((group) => group != saving)) {
            expect(
              saveButton(tester, other.save).onPressed,
              isNull,
              reason: other.title,
            );
          }

          remote.updates.single.complete(saving.landed);
          await tester.pumpAndSettle();
          for (final group in groups) {
            expect(
              saveButton(tester, group.save).onPressed,
              isNotNull,
              reason: group.title,
            );
          }

          // The group took what landed, so Save again has nothing to send.
          await press(tester, saving.save);
          expect(remote.updateCalls, hasLength(1));
        });
      }
    });

    testWidgets('an edit after a landed save takes its saved line away', (
      tester,
    ) async {
      await pumpScreen(tester);
      await toggle(tester, ContributionsSettingsForm.approvalSwitchKey);
      await press(tester, ContributionsSettingsForm.saveKey);
      remote.updates.single.complete(_settings(approval: true));
      await tester.pumpAndSettle();
      expect(find.text(_contributionsSavedCopy), findsOneWidget);

      await toggle(tester, ContributionsSettingsForm.approvalSwitchKey);

      expect(find.text(_contributionsSavedCopy), findsNothing);
    });

    testWidgets('a Contributions save that lands leaves unsaved Invitations '
        'edits as they are', (tester) async {
      await pumpScreen(tester);
      await pick(tester, InvitationsSettingsForm.householdFieldKey, 'Friends');
      await toggle(tester, ContributionsSettingsForm.approvalSwitchKey);

      await press(tester, ContributionsSettingsForm.saveKey);
      expect(
        remote.updateCalls.single.patch,
        const SystemSettingsPatch(requireContributionApproval: true),
      );
      remote.updates.single.complete(_settings(approval: true));
      await tester.pumpAndSettle();

      expect(find.text(_contributionsSavedCopy), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(InvitationsSettingsForm.householdFieldKey),
          matching: find.text('Friends'),
        ),
        findsOneWidget,
      );

      // Still an edit: its own Save sends it, and only it.
      await press(tester, InvitationsSettingsForm.saveKey);
      expect(
        remote.updateCalls.last.patch,
        const SystemSettingsPatch(householdInviteePolicy: Reach.friends),
      );
    });
  });

  group('the test email', () {
    Future<void> sendTest(WidgetTester tester) =>
        press(tester, MailTestPanel.sendKey);

    testWidgets('says it is waiting for the mail server, then what came of '
        'the test, and marks that result read', (tester) async {
      notifications = FakeNotificationRemote([
        <UnreadNotification>[],
        <UnreadNotification>[],
        [resultNotification('n1')],
      ]);
      await pumpScreen(tester);

      await sendTest(tester);

      expect(remote.sendMailTestCalls, 1);
      expect(find.text(_waitingCopy), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text(_waitingCopy), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text(_waitingCopy), findsNothing);
      expect(find.text(_sentCopy), findsOneWidget);
      expect(notifications.markReadCalls, [
        ['n1'],
      ]);
    });

    testWidgets('two identical outcomes in a row are two banners, so the '
        'second is heard too', (tester) async {
      notifications = FakeNotificationRemote([
        <UnreadNotification>[],
        [resultNotification('n1')],
        <UnreadNotification>[],
        [resultNotification('n2')],
      ]);
      await pumpScreen(tester);

      await sendTest(tester);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      final first = tester.widget(bannerWith(_sentCopy)).key;
      final firstState = tester.state(bannerWith(_sentCopy));

      await sendTest(tester);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      final second = tester.widget(bannerWith(_sentCopy)).key;

      expect(first, isNotNull);
      expect(second, isNot(first));
      expect(tester.state(bannerWith(_sentCopy)), isNot(same(firstState)));
    });

    testWidgets(
      'an edit to Mail retires the outcome, and an edit to Registration '
      'does not',
      (tester) async {
        notifications = FakeNotificationRemote([
          <UnreadNotification>[],
          [resultNotification('n1')],
        ]);
        await pumpScreen(tester);
        await sendTest(tester);
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(find.text(_sentCopy), findsOneWidget);

        await pickAutomatic(tester);
        expect(find.text(_sentCopy), findsOneWidget);

        await enter(tester, MailSettingsForm.userFieldKey, 'relay');

        expect(find.text(_sentCopy), findsNothing);
        expect(
          find.descendant(
            of: find.byType(MailTestPanel),
            matching: find.byType(BgeInlineBanner),
          ),
          findsNothing,
        );
      },
    );

    testWidgets('an edit to Mail while the test is out retires the outcome '
        'it comes to, so nothing is shown once the edit is saved', (
      tester,
    ) async {
      notifications = FakeNotificationRemote([
        <UnreadNotification>[],
        <UnreadNotification>[],
        [resultNotification('n1')],
      ]);
      await pumpScreen(tester);
      await sendTest(tester);
      expect(find.text(_waitingCopy), findsOneWidget);

      await enter(tester, MailSettingsForm.userFieldKey, 'relay');
      expect(find.text(_waitingCopy), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(notifications.markReadCalls, [
        ['n1'],
      ]);
      expect(find.text(_waitingCopy), findsNothing);
      expect(find.text(_sentCopy), findsNothing);

      await press(tester, MailSettingsForm.saveKey);
      remote.updates.single.complete(_settings(user: 'relay'));
      await tester.pumpAndSettle();

      expect(find.text(_mailSavedCopy), findsOneWidget);
      expect(find.text(_sentCopy), findsNothing);
    });

    testWidgets('leaving the screen while it waits stops the polling, even '
        'while the screen animates away', (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _app(const Text('home'), navigatorKey: navigator),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => screen()),
      );
      await tester.pump();
      await tester.pump();
      remote.fetches.single.complete(_settings());
      await tester.pumpAndSettle();

      await sendTest(tester);
      expect(find.text(_waitingCopy), findsOneWidget);
      final reads = notifications.fetchCalls;

      // Just before the first poll is due.
      await tester.pump(const Duration(milliseconds: 4900));
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // The poll fell due with the screen still on its way out.
      expect(find.byType(ServerSettingsScreen), findsOneWidget);
      expect(notifications.fetchCalls, reads);

      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));

      expect(find.byType(ServerSettingsScreen), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(notifications.fetchCalls, reads);
    });

    testWidgets('a router dropping its page while it waits stops the '
        'polling too, while the next page animates in', (tester) async {
      // As go_router does on a `go` elsewhere: the page is dropped from the
      // list, not popped, so it completes rather than pops.
      final pages = ValueNotifier<List<Page<void>>>([
        const MaterialPage<void>(key: ValueKey('home'), child: Text('home')),
        MaterialPage<void>(key: const ValueKey('settings'), child: screen()),
      ]);
      addTearDown(pages.dispose);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<List<Page<void>>>(
            valueListenable: pages,
            builder: (context, list, _) =>
                Navigator(pages: list, onDidRemovePage: (_) {}),
          ),
        ),
      );
      await tester.pump();
      remote.fetches.single.complete(_settings());
      await tester.pumpAndSettle();

      await sendTest(tester);
      expect(find.text(_waitingCopy), findsOneWidget);
      final reads = notifications.fetchCalls;

      await tester.pump(const Duration(milliseconds: 4900));
      pages.value = [
        pages.value.first,
        const MaterialPage<void>(key: ValueKey('other'), child: Text('other')),
      ];
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // The poll fell due with the screen still under the incoming page.
      expect(find.byType(ServerSettingsScreen), findsOneWidget);
      expect(notifications.fetchCalls, reads);

      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));

      expect(find.byType(ServerSettingsScreen), findsNothing);
      expect(find.text('other'), findsOneWidget);
      expect(notifications.fetchCalls, reads);
    });
  });

  // Each group's end in turn: its Save, or for a role with none, its last
  // field.
  for (final (name, account, ends) in [
    ('an admin', _admin, [for (final group in groups) group.save]),
    ('a Moderator', _moderator, [for (final group in groups) group.lastField]),
  ]) {
    testWidgets('fits a 320dp window at 200% text for $name, top to bottom', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(320, 480)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      access.current = account;

      await pumpScreen(tester, settings: _everythingShown());
      final page = find.byType(Scrollable).first;
      for (final end in ends) {
        await tester.scrollUntilVisible(
          find.byKey(end),
          200,
          scrollable: page,
        );
        await tester.ensureVisible(find.byKey(end));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$end');
      }
      final position = tester.state<ScrollableState>(page).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(_warningCopy), findsOneWidget);
      expect(find.text(_redactionOffCopy), findsOneWidget);
    });
  }

  group('accessibility audit', () {
    Future<void> Function(WidgetTester, ThemeData) loaded({
      CallerAccess? as,
    }) => (tester, theme) async {
      if (as != null) access.current = as;
      await pumpScreen(tester, theme: theme, settings: _everythingShown());
    };

    /// The whole page in view. At 320dp × 2.0 the six groups run past
    /// [useWholePage]'s 6000dp, so the view grows by what is left to scroll.
    Future<void> wholePage(WidgetTester tester) async {
      await useWholePage(tester);
      final rest = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .maxScrollExtent;
      final ratio = tester.view.devicePixelRatio;
      final view = tester.view.physicalSize / ratio;
      tester.view.physicalSize = Size(view.width, view.height + rest) * ratio;
      await tester.pumpAndSettle();
      expectWholePage(tester);
    }

    auditScreen('loaded, whole page', pump: loaded(), arrange: wholePage);

    auditScreen(
      'read-only, whole page',
      pump: loaded(as: _moderator),
      arrange: wholePage,
    );

    auditScreen(
      'loading',
      pump: (tester, theme) async {
        await tester.pumpWidget(_app(screen(), theme: theme));
      },
      settle: false,
      arrange: (tester) async {
        await tester.pump();
        expect(find.byKey(ServerSettingsScreen.loadingKey), findsOneWidget);
      },
    );

    auditScreen(
      'refused',
      pump: (tester, theme) async {
        await tester.pumpWidget(_app(screen(), theme: theme));
        await tester.pump();
        remote.fetches.single.completeError(
          const SystemSettingsForbiddenException('no', statusCode: 403),
        );
        await tester.pumpAndSettle();
      },
      arrange: (tester) async {
        expect(find.byKey(ServerSettingsScreen.refusedKey), findsOneWidget);
      },
    );

    auditScreen(
      'failed to load',
      pump: (tester, theme) async {
        await tester.pumpWidget(_app(screen(), theme: theme));
        await tester.pump();
        remote.fetches.single.completeError(
          const SystemSettingsTransientException('down'),
        );
        await tester.pumpAndSettle();
      },
      arrange: (tester) async {
        expect(find.byKey(ServerSettingsScreen.errorKey), findsOneWidget);
      },
    );
  });
}
