import 'dart:async';

import 'package:api_keys/api_keys.dart';
import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

void main() {
  late MockApiKeyRemoteDataSource remote;
  late FakeSessionLease lease;

  // Local noon: the screen shows dates in local time, and `toLocal()` keeps
  // a local time's date in every zone a test machine is in. Noon UTC was the
  // next day from UTC+12 on.
  final expires = DateTime(2027, 2, 1, 12);
  final used = DateTime(2026, 11, 20, 12);

  final readCollection = permission(
    'collection:read',
    description: 'Read your game collection',
  );
  final manageUsers = permission(
    'users:manage',
    description: 'Manage every user',
    riskLevel: RiskLevel.critical,
  );
  final manageHooks = permission(
    'webhooks:manage',
    description: 'Manage your webhook subscriptions',
    riskLevel: RiskLevel.high,
    pinnable: true,
  );

  final key = apiKey(
    'k_1',
    scopes: const [
      ApiKeyScope(slug: 'collection:read'),
      ApiKeyScope(slug: 'users:manage'),
    ],
    expiresAt: expires,
    lastUsedAt: used,
  ).copyWith(createdAt: DateTime(2026, 11, 1, 12));

  // Critical, and not held by [key]: what an edit that adds one adds.
  final managePlugins = permission(
    'plugins:manage',
    description: 'Manage your plugins',
    riskLevel: RiskLevel.critical,
  );

  // The expiry a save that sets a new one answers with.
  final renewed = DateTime.utc(2027, 6, 1, 12);

  const transient = ApiKeyTransientException('down');
  const needsConfirmation = ApiKeyCriticalNeedsConfirmationException('no');
  const unreachable =
      "Couldn't reach the server. Check your connection, then try again.";
  const criticalQuestion = 'Give this key Critical permissions?';
  const saveFailedTitle = "Couldn't save changes to CI deploy";
  const notEditable =
      "Couldn't load the permissions you can give, so this key's permissions "
      "can't be changed now. Open this page again to try.";

  setUpAll(() => registerFallbackValue(const ApiKeyPatch()));

  setUp(() {
    remote = MockApiKeyRemoteDataSource();
    lease = FakeSessionLease();
    answerGrantable(remote, [readCollection, manageUsers, manageHooks]);
    answerKey(remote, key);
  });

  Widget detail({String id = 'k_1'}) =>
      ApiKeyDetailScreen(remote: remote, id: id, sessionLease: lease);

  Widget screen({String id = 'k_1', ThemeData? theme, bool offline = false}) =>
      hostScreen(
        detail(id: id),
        theme: theme,
        offline: offline,
      );

  Future<void> show(
    WidgetTester tester, {
    String id = 'k_1',
    bool offline = false,
  }) async {
    await tester.pumpWidget(screen(id: id, offline: offline));
    await tester.pumpAndSettle();
  }

  /// Shows the screen pushed over a page, as the app has it over the list.
  Future<void> showPushed(WidgetTester tester) async {
    await tester.pumpWidget(hostOverPage(detail()));
    await tester.pumpAndSettle();
    expect(find.text(pageBeneathCopy), findsNothing);
  }

  /// What a screen reader reads for the row whose title is [title].
  String rowLabel(WidgetTester tester, String title) =>
      tester.getSemantics(find.text(title)).getSemanticsData().label;

  Finder enabledSwitch() => find.byKey(ApiKeyDetailScreen.enabledKey);

  SwitchListTile switchTile(WidgetTester tester) =>
      tester.widget<SwitchListTile>(enabledSwitch());

  FocusNode switchFocus(WidgetTester tester) => switchTile(tester).focusNode!;

  Finder deleteButton() => find.byKey(ApiKeyDetailScreen.deleteKey);

  FocusNode deleteFocus(WidgetTester tester) =>
      tester.widget<TextButton>(deleteButton()).focusNode!;

  /// Lets a bloc event reach the screen without waiting for a busy cue,
  /// which never settles.
  Future<void> pumpEvent(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> openDelete(WidgetTester tester) async {
    await tester.ensureVisible(deleteButton());
    await tester.pumpAndSettle();
    await tester.tap(deleteButton());
    await tester.pumpAndSettle();
  }

  Future<void> confirmDelete(WidgetTester tester) async {
    await openDelete(tester);
    await tester.tap(find.byKey(DeleteKeyDialog.confirmKey));
    await tester.pumpAndSettle();
  }

  /// Taps the Enabled switch, which sits below the edit form.
  Future<void> tapSwitch(WidgetTester tester) async {
    await tester.ensureVisible(enabledSwitch());
    await tester.pumpAndSettle();
    await tester.tap(enabledSwitch());
  }

  Finder nameField() => find.byKey(ApiKeyDetailScreen.nameKey);

  EditableText nameInput(WidgetTester tester) => tester.widget<EditableText>(
    find.descendant(of: nameField(), matching: find.byType(EditableText)),
  );

  Finder saveButton() => find.byKey(ApiKeyDetailScreen.saveKey);

  FocusNode saveFocus(WidgetTester tester) =>
      tester.widget<FilledButton>(saveButton()).focusNode!;

  Finder savedBanner() => find.byKey(ApiKeyDetailScreen.savedKey);

  Finder nothingToSaveBanner() =>
      find.byKey(ApiKeyDetailScreen.nothingToSaveKey);

  Finder saveFailedBanner() => find.byKey(ApiKeyDetailScreen.saveFailedKey);

  ScopePicker picker(WidgetTester tester) =>
      tester.widget<ScopePicker>(find.byType(ScopePicker));

  ExpiryControl expiry(WidgetTester tester) =>
      tester.widget<ExpiryControl>(find.byType(ExpiryControl));

  /// The picker's row for [scope]: a grantable permission's by its unpinned
  /// scope, a held one's by itself.
  Finder scopeRow(ApiKeyScope scope) => find.byKey(ScopePicker.rowKey(scope));

  /// What a screen reader reads for the picker's row for [scope].
  String scopeRowLabel(WidgetTester tester, ApiKeyScope scope) =>
      tester.getSemantics(scopeRow(scope)).getSemanticsData().label;

  Future<void> rename(WidgetTester tester, String name) async {
    await tester.enterText(nameField(), name);
    await tester.pumpAndSettle();
  }

  Finder changeScopes() => find.byKey(ApiKeyDetailScreen.changeScopesKey);

  Finder keepScopes() => find.byKey(ApiKeyDetailScreen.keepScopesKey);

  /// Presses "Change permissions", which swaps the picker in for the key's
  /// permissions, unless the picker shows already.
  Future<void> openPicker(WidgetTester tester) async {
    if (find.byType(ScopePicker).evaluate().isNotEmpty) return;
    await tester.ensureVisible(changeScopes());
    await tester.pumpAndSettle();
    await tester.tap(changeScopes());
    await tester.pumpAndSettle();
    expect(find.byType(ScopePicker), findsOneWidget);
  }

  /// Ticks or unticks the grantable permission [slug], opening the picker
  /// first if it isn't open.
  Future<void> tick(WidgetTester tester, String slug) async {
    await openPicker(tester);
    final row = scopeRow(ApiKeyScope(slug: slug));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// Picks the expiry chip labelled [chip].
  Future<void> pickExpiry(WidgetTester tester, String chip) async {
    await tester.ensureVisible(find.text(chip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(chip));
    await tester.pumpAndSettle();
  }

  Finder customDaysField() => find.ancestor(
    of: find.text('Number of days'),
    matching: find.byType(BgeTextField),
  );

  /// Presses Save, and lets whatever it opens or answers arrive. For a save
  /// that is held, use [pressSaveHeld].
  Future<void> pressSave(WidgetTester tester) async {
    await tester.ensureVisible(saveButton());
    await tester.pumpAndSettle();
    await tester.tap(saveButton());
    await tester.pumpAndSettle();
  }

  /// Presses Save from the keyboard, with focus on it, and does not wait for
  /// a spinner to settle.
  Future<void> pressSaveHeld(WidgetTester tester) async {
    await tester.ensureVisible(saveButton());
    await tester.pumpAndSettle();
    saveFocus(tester).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpEvent(tester);
  }

  /// Every patch sent since the last look, in order.
  List<ApiKeyPatch> patchesSent() => verify(
    () => remote.update('k_1', captureAny()),
  ).captured.cast<ApiKeyPatch>();

  /// The one patch sent since the last look.
  ApiKeyPatch patchSent() => patchesSent().single;

  /// Answers each update as the server would: [from] with the patch applied,
  /// and a new expiry of [renewed].
  void serverApplies(ApiKey from) {
    var current = from;
    when(() => remote.update('k_1', any())).thenAnswer((invocation) async {
      final patch = invocation.positionalArguments[1] as ApiKeyPatch;
      return current = current.copyWith(
        name: patch.name ?? current.name,
        scopes: patch.scopes ?? current.scopes,
        enabled: patch.enabled ?? current.enabled,
        expiresAt: patch.expiresInDays == null ? current.expiresAt : renewed,
      );
    });
  }

  /// Offers [managePlugins] beside the permissions every test offers.
  void offerPlugins() => answerGrantable(remote, [
    readCollection,
    manageUsers,
    manageHooks,
    managePlugins,
  ]);

  group('reading', () {
    testWidgets('the key reads its name, start, permissions, dates and '
        'whether it works', (tester) async {
      await show(tester);

      // The name heads the page as well as the app bar, which cuts a long
      // one short at 200% text, and starts the name field.
      expect(find.text('CI deploy'), findsNWidgets(3));
      expect(nameInput(tester).controller.text, 'CI deploy');
      for (final words in [
        'bge_a1B2…',
        '2 permissions, highest risk Critical',
        'Created Nov 1, 2026',
        'Expires Feb 1, 2027',
        'Last used Nov 20, 2026',
      ]) {
        expect(find.text(words), findsOneWidget, reason: words);
      }
      expect(switchTile(tester).value, isTrue);
      expect(
        tester.getSemantics(enabledSwitch()).label,
        allOf(contains('Enabled'), contains('Programs can use this key.')),
      );
      verify(() => remote.fetch('k_1')).called(1);
      verify(remote.fetchGrantable).called(1);
    });

    testWidgets('each scope reads its description and risk level in words', (
      tester,
    ) async {
      await show(tester);

      expect(
        rowLabel(tester, 'Read your game collection'),
        allOf(contains('Risk: Low'), contains('collection:read')),
      );
      expect(
        rowLabel(tester, 'Manage every user'),
        allOf(contains('Risk: Critical'), contains('users:manage')),
      );
      // In words on screen too, not only to a screen reader.
      expect(find.text('Risk: Low'), findsOneWidget);
      expect(find.text('Risk: Critical'), findsOneWidget);
    });

    testWidgets('a pinned scope reads as limited to one record', (
      tester,
    ) async {
      answerKey(
        remote,
        apiKey(
          'k_1',
          scopes: const [
            ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1'),
            ApiKeyScope(slug: 'collection:read'),
          ],
        ),
      );
      await show(tester);

      // Listed, the key's own scopes are its rows.
      expect(
        rowLabel(tester, 'Manage your webhook subscriptions'),
        allOf(contains('Risk: High'), contains('Limited to one record')),
      );

      // In the picker, its permission may be given unpinned too, which is a
      // row of its own.
      await openPicker(tester);
      expect(
        scopeRowLabel(
          tester,
          const ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1'),
        ),
        allOf(contains('Risk: High'), contains('Limited to one record')),
      );
      expect(
        scopeRowLabel(tester, const ApiKeyScope(slug: 'webhooks:manage')),
        isNot(contains('Limited to one record')),
      );
      expect(
        rowLabel(tester, 'Read your game collection'),
        isNot(contains('Limited to one record')),
      );
    });

    testWidgets('a scope missing from grantable reads no longer available', (
      tester,
    ) async {
      answerKey(
        remote,
        apiKey(
          'k_1',
          scopes: const [
            ApiKeyScope(slug: 'events:delete'),
            ApiKeyScope(slug: 'collection:read'),
          ],
        ),
      );
      await show(tester);

      expect(
        rowLabel(tester, 'events:delete'),
        allOf(contains('No longer available'), isNot(contains('Risk'))),
      );
      expect(find.text('No longer available'), findsOneWidget);
    });

    testWidgets('a grantable failure still shows the key, its scopes by their '
        'codes, and says why', (tester) async {
      when(remote.fetchGrantable).thenThrow(transient);
      answerKey(
        remote,
        apiKey(
          'k_1',
          scopes: const [
            ApiKeyScope(slug: 'collection:read'),
            ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1'),
          ],
        ),
      );
      await show(tester);

      expect(find.text('CI deploy'), findsNWidgets(3));
      expect(find.text('2 permissions'), findsOneWidget);
      expect(
        find.text(
          "Couldn't load what these permissions allow, so each is shown by "
          'its code.',
        ),
        findsOneWidget,
      );
      expect(find.text('collection:read'), findsOneWidget);
      expect(
        rowLabel(tester, 'webhooks:manage'),
        contains('Limited to one record'),
      );
      // Not knowing what a permission allows isn't its being withdrawn.
      expect(find.text('No longer available'), findsNothing);
      expect(find.textContaining('Risk:'), findsNothing);
      // Nothing to change them with: the picker has no rows to offer.
      expect(changeScopes(), findsNothing);
      expect(switchTile(tester).onChanged, isNotNull);
    });

    testWidgets('a key with no permissions says it works nowhere until it has '
        'some', (tester) async {
      answerKey(remote, apiKey('k_1', scopes: const []));
      final semantics = tester.ensureSemantics();
      await show(tester);
      expect(
        find.text(
          'This key has no permissions, so it works nowhere until it is '
          'given some.',
        ),
        findsOneWidget,
      );

      // The permissions to tick say it, under them.
      await openPicker(tester);
      final warning = find.text('With no permissions, this key works nowhere.');
      expect(warning, findsOneWidget);
      // How the key is, not news: not said over the page as it opens.
      expect(
        tester
            .widget<BgeInlineBanner>(
              find.ancestor(
                of: warning,
                matching: find.byType(BgeInlineBanner),
              ),
            )
            .announce,
        isFalse,
      );
      semantics.dispose();
    });

    testWidgets('an unnamed key and one that never expires or was never used '
        'say so', (tester) async {
      answerKey(remote, apiKey('k_1', name: null, start: null));
      await show(tester);

      expect(find.text('Unnamed key'), findsNWidgets(2));
      expect(find.text('Never expires'), findsOneWidget);
      expect(find.text('Never used'), findsOneWidget);
    });

    testWidgets('a 404 says the key no longer exists, with a way back', (
      tester,
    ) async {
      when(
        () => remote.fetch('k_1'),
      ).thenThrow(const ApiKeyNotFoundException('gone'));
      await showPushed(tester);

      expect(find.byKey(ApiKeyDetailScreen.goneKey), findsOneWidget);
      expect(find.text('This key no longer exists'), findsOneWidget);
      expect(enabledSwitch(), findsNothing);
      expect(deleteButton(), findsNothing);

      await tester.tap(find.byKey(ApiKeyDetailScreen.backKey));
      await tester.pumpAndSettle();

      expect(find.byType(ApiKeyDetailScreen), findsNothing);
      expect(find.text(pageBeneathCopy), findsOneWidget);
    });

    testWidgets('a load failure offers Try again, which reads again and keeps '
        'focus on the page', (tester) async {
      final retried = Completer<ApiKey>();
      var reads = 0;
      when(() => remote.fetch('k_1')).thenAnswer(
        (_) => reads++ == 0 ? Future.error(transient) : retried.future,
      );
      await show(tester);

      expect(find.byKey(ApiKeyDetailScreen.failedKey), findsOneWidget);
      // Nothing that answered: the connection is what to check.
      expect(
        find.text('Check your connection, then try again.'),
        findsOneWidget,
      );
      // The retry is autofocused; a keyboard press goes as the read starts.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(find.byKey(ApiKeyDetailScreen.retryKey), findsNothing);
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNot(isA<FocusScopeNode>()));
      expect(focused?.context?.widget, isA<Focus>());

      retried.complete(key);
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text('CI deploy'), findsNWidgets(3));
    });

    testWidgets("a load the server refused says why in the server's words", (
      tester,
    ) async {
      when(() => remote.fetch('k_1')).thenThrow(
        const ApiKeyPermanentException(
          'refused',
          statusCode: 400,
          apiMessage: 'That id is not a key id',
        ),
      );

      await show(tester);

      expect(find.text("Couldn't load this key"), findsOneWidget);
      expect(find.text('That id is not a key id'), findsOneWidget);
      expect(
        find.text('Check your connection, then try again.'),
        findsNothing,
      );
    });

    testWidgets('a new id reads that key', (
      tester,
    ) async {
      answerKey(remote, apiKey('k_2', name: 'Backup'));
      await show(tester);
      expect(find.text('CI deploy'), findsNWidgets(3));

      // The router keeps the page for a go to another id of the same route,
      // and builds the screen again with the new id.
      await tester.pumpWidget(screen(id: 'k_2'));
      await tester.pumpAndSettle();

      // Its form too starts from the new key.
      expect(find.text('Backup'), findsNWidgets(3));
      expect(find.text('CI deploy'), findsNothing);
      verifyInOrder([() => remote.fetch('k_1'), () => remote.fetch('k_2')]);
    });
  });

  group('enabling and disabling', () {
    testWidgets('turning the switch off sends enabled false and shows what '
        'the server answered', (tester) async {
      when(
        () => remote.update('k_1', any()),
      ).thenAnswer((_) async => key.copyWith(enabled: false));
      await show(tester);

      await tapSwitch(tester);
      await tester.pumpAndSettle();

      verify(
        () => remote.update('k_1', const ApiKeyPatch(enabled: false)),
      ).called(1);
      expect(switchTile(tester).value, isFalse);
      expect(
        tester.getSemantics(enabledSwitch()).label,
        contains(
          'Programs using this key are refused until you enable it again.',
        ),
      );
    });

    testWidgets('a second toggle while one is in flight sends nothing and '
        'keeps focus', (tester) async {
      final answer = Completer<ApiKey>();
      when(
        () => remote.update('k_1', any()),
      ).thenAnswer((_) => answer.future);
      final semantics = tester.ensureSemantics();
      await show(tester);
      await tester.ensureVisible(enabledSwitch());
      await tester.pumpAndSettle();

      switchFocus(tester).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await pumpEvent(tester);

      // On its way: the switch shows what the server last answered, stays
      // enabled with focus, and the cue says it is saving.
      expect(switchTile(tester).value, isTrue);
      expect(switchTile(tester).onChanged, isNotNull);
      expect(switchFocus(tester).hasPrimaryFocus, isTrue);
      expect(find.bySemanticsLabel('Saving…'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await pumpEvent(tester);
      await tester.tap(enabledSwitch());
      await pumpEvent(tester);

      verify(() => remote.update('k_1', any())).called(1);
      expect(switchFocus(tester).hasPrimaryFocus, isTrue);

      answer.complete(key.copyWith(enabled: false));
      await tester.pumpAndSettle();

      expect(switchTile(tester).value, isFalse);
      expect(switchFocus(tester).hasPrimaryFocus, isTrue);
      expect(find.bySemanticsLabel('Saving…'), findsNothing);
      semantics.dispose();
    });

    testWidgets('a failed toggle says why above the switch, which keeps its '
        'value and focus', (tester) async {
      when(() => remote.update('k_1', any())).thenThrow(
        const ApiKeyPermanentException('no', apiMessage: 'Not today.'),
      );
      await show(tester);

      switchFocus(tester).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      final banner = find.byKey(ApiKeyDetailScreen.toggleFailedKey);
      expect(banner, findsOneWidget);
      // The refusal has no words of the client's own: the server's show.
      expect(
        find.descendant(of: banner, matching: find.text('Not today.')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: banner,
          matching: find.text("Couldn't disable CI deploy"),
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(banner).dy,
        lessThan(tester.getTopLeft(enabledSwitch()).dy),
      );
      expect(switchTile(tester).value, isTrue);
      expect(switchFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('a 404 on a toggle says the key is gone, with focus on the '
        'page', (tester) async {
      when(
        () => remote.update('k_1', any()),
      ).thenThrow(const ApiKeyNotFoundException('gone'));
      await show(tester);

      switchFocus(tester).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(find.byKey(ApiKeyDetailScreen.goneKey), findsOneWidget);
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNot(isA<FocusScopeNode>()));
      expect(focused?.context?.mounted, isTrue);
    });
  });

  group('offline', () {
    testWidgets('offline, the switch, Delete and Save are disabled and say '
        'why', (tester) async {
      final semantics = tester.ensureSemantics();
      await show(tester, offline: true);

      expect(switchTile(tester).onChanged, isNull);
      expect(
        tester.getSemantics(enabledSwitch()).label,
        contains(onlineOnlyCopy),
      );
      expect(tester.widget<TextButton>(deleteButton()).onPressed, isNull);
      expect(
        tester.getSemantics(deleteButton()).getSemanticsData().hint,
        onlineOnlyCopy,
      );
      expect(tester.widget<FilledButton>(saveButton()).onPressed, isNull);
      expect(
        tester.getSemantics(saveButton()).getSemanticsData().hint,
        onlineOnlyCopy,
      );
      // Drawn once for each control: in the switch's label, under Delete,
      // under Save.
      expect(find.text(onlineOnlyCopy), findsNWidgets(3));
      // The form is no direct write: it can be filled in, to save later.
      expect(nameInput(tester).readOnly, isFalse);
      semantics.dispose();
    });
  });

  group('deleting', () {
    testWidgets("delete asks with the key's name and cancelling sends "
        'nothing', (tester) async {
      await show(tester);

      deleteFocus(tester).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Delete CI deploy?'), findsOneWidget);
      expect(
        find.text(
          "Programs using it stop working at once. This can't be undone.",
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(DeleteKeyDialog.cancelKey));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      verifyNever(() => remote.delete(any()));
      expect(deleteFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets("a screen reader's Delete has focus back when its dialog "
        'closes', (tester) async {
      final semantics = tester.ensureSemantics();
      await show(tester);
      await tester.ensureVisible(deleteButton());
      await tester.pumpAndSettle();

      // A double tap with a screen reader moves no input focus of its own.
      tester.semantics.tap(find.semantics.byLabel('Delete key'));
      await tester.pumpAndSettle();
      expect(find.text('Delete CI deploy?'), findsOneWidget);

      await tester.tap(find.byKey(DeleteKeyDialog.cancelKey));
      await tester.pumpAndSettle();

      expect(deleteFocus(tester).hasPrimaryFocus, isTrue);
      semantics.dispose();
    });

    testWidgets('an unnamed key is asked about by the name its row gives', (
      tester,
    ) async {
      answerKey(remote, apiKey('k_1', name: null));
      await show(tester);

      await openDelete(tester);

      expect(find.text('Delete Unnamed key?'), findsOneWidget);
    });

    testWidgets('a confirmed delete pops and says Deleted with the name', (
      tester,
    ) async {
      when(() => remote.delete('k_1')).thenAnswer((_) async {});
      await showPushed(tester);

      await confirmDelete(tester);

      verify(() => remote.delete('k_1')).called(1);
      expect(find.byType(ApiKeyDetailScreen), findsNothing);
      expect(find.text(pageBeneathCopy), findsOneWidget);
      expect(find.text('Deleted CI deploy'), findsOneWidget);
    });

    testWidgets('while the delete is on its way, Delete keeps focus and says '
        'it is deleting, and the switch takes no press', (tester) async {
      final answer = Completer<void>();
      when(() => remote.delete('k_1')).thenAnswer((_) => answer.future);
      final semantics = tester.ensureSemantics();
      await showPushed(tester);

      deleteFocus(tester).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(DeleteKeyDialog.confirmKey));
      await tester.pumpAndSettle();

      expect(find.text('Deleting…'), findsOneWidget);
      expect(find.bySemanticsLabel('Deleting…'), findsOneWidget);
      expect(deleteFocus(tester).hasPrimaryFocus, isTrue);
      expect(switchTile(tester).onChanged, isNull);

      // Another press of Delete opens nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      answer.complete();
      await tester.pumpAndSettle();
      verify(() => remote.delete('k_1')).called(1);
      expect(find.text('Deleted CI deploy'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a failed delete says why above Delete, and the screen '
        'stays', (tester) async {
      when(() => remote.delete('k_1')).thenThrow(transient);
      await showPushed(tester);

      await confirmDelete(tester);

      final banner = find.byKey(ApiKeyDetailScreen.deleteFailedKey);
      expect(banner, findsOneWidget);
      expect(
        find.descendant(
          of: banner,
          matching: find.text("Couldn't delete CI deploy"),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: banner, matching: find.text(unreachable)),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(banner).dy,
        lessThan(tester.getTopLeft(deleteButton()).dy),
      );
      expect(find.byType(ApiKeyDetailScreen), findsOneWidget);
      expect(find.text('Delete key'), findsOneWidget);
    });

    testWidgets("opening Delete's dialog retires a failure, so it isn't read "
        'again as news when the dialog closes', (tester) async {
      when(() => remote.update('k_1', any())).thenThrow(transient);
      await show(tester);
      await tapSwitch(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(ApiKeyDetailScreen.toggleFailedKey), findsOneWidget);

      await openDelete(tester);

      expect(find.byKey(ApiKeyDetailScreen.toggleFailedKey), findsNothing);
    });

    group('after the screen has gone', () {
      late Completer<void> answer;

      /// Leaves by the navigator's pop while the delete is out. The answer's
      /// completer is made here, in the test's own zone: one made in a
      /// `setUp` completes outside the fake clock, and no pump would see it.
      Future<void> leaveMidDelete(WidgetTester tester) async {
        answer = Completer<void>();
        when(() => remote.delete('k_1')).thenAnswer((_) => answer.future);
        await showPushed(tester);
        await confirmDelete(tester);
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pump();
      }

      testWidgets('a delete that lands after the screen has gone is said on '
          'the page beneath', (tester) async {
        await leaveMidDelete(tester);
        await tester.pumpAndSettle();
        expect(find.byType(ApiKeyDetailScreen), findsNothing);

        answer.complete();
        await tester.pumpAndSettle();

        expect(find.text(pageBeneathCopy), findsOneWidget);
        expect(find.text('Deleted CI deploy'), findsOneWidget);
      });

      testWidgets('one that lands while the screen is leaving is said once, '
          'and goes nowhere', (tester) async {
        await leaveMidDelete(tester);
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(ApiKeyDetailScreen), findsOneWidget);

        answer.complete();
        await tester.pumpAndSettle();

        // The page beneath is still there: the late answer popped nothing.
        expect(find.text(pageBeneathCopy), findsOneWidget);
        expect(find.text('Deleted CI deploy'), findsOneWidget);
      });

      testWidgets('a failed one says why, since its banner went with the '
          'screen', (tester) async {
        await leaveMidDelete(tester);
        await tester.pumpAndSettle();

        answer.completeError(transient);
        await tester.pumpAndSettle();

        expect(
          find.text("Couldn't delete CI deploy: $unreachable"),
          findsOneWidget,
        );
      });

      testWidgets('nothing is said once the session has ended', (
        tester,
      ) async {
        await leaveMidDelete(tester);
        lease.isLive = false;
        await tester.pump(const Duration(milliseconds: 50));

        answer.complete();
        await tester.pumpAndSettle();

        expect(find.text(pageBeneathCopy), findsOneWidget);
        expect(find.text('Deleted CI deploy'), findsNothing);
      });
    });

    testWidgets('a toggle that lands after the screen has gone says what it '
        'did', (tester) async {
      final answer = Completer<ApiKey>();
      when(
        () => remote.update('k_1', any()),
      ).thenAnswer((_) => answer.future);
      await showPushed(tester);
      await tapSwitch(tester);
      await pumpEvent(tester);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      answer.complete(key.copyWith(enabled: false));
      await tester.pumpAndSettle();

      expect(find.text('Disabled CI deploy'), findsOneWidget);
    });
  });

  group('editing', () {
    testWidgets('the form starts from the key: its name, the permissions it '
        'holds ticked, no new expiry, and Save changes, above Enabled and '
        'Delete', (tester) async {
      await show(tester);

      expect(nameInput(tester).controller.text, 'CI deploy');
      // The key's permissions are listed, with the way to change them.
      expect(find.byType(ApiKeyScopeList), findsOneWidget);
      expect(find.byType(ScopePicker), findsNothing);
      await openPicker(tester);
      final scopes = picker(tester);
      expect(scopes.offerEverything, isFalse);
      expect(find.byKey(ScopePicker.everythingKey), findsNothing);
      expect(scopes.held, key.scopes);
      expect(
        scopes.selection,
        const PickedScopes([
          ApiKeyScope(slug: 'collection:read'),
          ApiKeyScope(slug: 'users:manage'),
        ]),
      );
      expect(expiry(tester).days, isNull);
      expect(expiry(tester).label, 'Set a new expiry');
      expect(find.text('Save changes'), findsOneWidget);
      // The facts still say when the key expires now.
      expect(find.text('Expires Feb 1, 2027'), findsOneWidget);
      expect(
        tester.getTopLeft(saveButton()).dy,
        lessThan(tester.getTopLeft(enabledSwitch()).dy),
      );
      expect(
        tester.getTopLeft(enabledSwitch()).dy,
        lessThan(tester.getTopLeft(deleteButton()).dy),
      );
    });

    group('the permissions', () {
      testWidgets('are listed with what each allows and its risk, and '
          'Change permissions under them', (tester) async {
        await show(tester);

        expect(
          tester.widget<ApiKeyScopeList>(find.byType(ApiKeyScopeList)),
          isA<ApiKeyScopeList>()
              .having((list) => list.scopes, 'scopes', key.scopes)
              .having((list) => list.grantable, 'grantable', isNotNull),
        );
        expect(
          rowLabel(tester, 'Manage every user'),
          allOf(contains('Risk: Critical'), contains('users:manage')),
        );
        expect(find.byType(ScopePicker), findsNothing);
        expect(find.text('Change permissions'), findsOneWidget);
        expect(
          tester.getTopLeft(changeScopes()).dy,
          greaterThan(
            tester.getBottomLeft(find.byType(ApiKeyScopeList)).dy - 1,
          ),
        );
      });

      testWidgets('Change permissions swaps in the picker in place, ticked as '
          'the key holds them, with focus on their heading', (tester) async {
        await show(tester);
        // How far under the heading a widget starts.
        double underHeading(Finder finder) =>
            tester.getTopLeft(finder).dy -
            tester.getBottomLeft(find.text('Permissions')).dy;
        final listAt = underHeading(find.byType(ApiKeyScopeList));

        await openPicker(tester);

        expect(find.byType(ApiKeyScopeList), findsNothing);
        expect(changeScopes(), findsNothing);
        expect(underHeading(find.byType(ScopePicker)), listAt);
        expect(
          picker(tester).selection,
          const PickedScopes([
            ApiKeyScope(slug: 'collection:read'),
            ApiKeyScope(slug: 'users:manage'),
          ]),
        );
        expect(find.text('Keep permissions as they were'), findsOneWidget);
        final focused = FocusManager.instance.primaryFocus;
        expect(
          find.descendant(
            of: find.byWidget(focused!.context!.widget),
            matching: find.text('Permissions'),
          ),
          findsOneWidget,
        );
      });

      testWidgets('Keep permissions as they were goes back to the list, with '
          'the picks as the key holds them, and sends no permissions', (
        tester,
      ) async {
        serverApplies(key);
        await show(tester);
        await tick(tester, 'webhooks:manage');
        await tick(tester, 'users:manage');

        await tester.ensureVisible(keepScopes());
        await tester.pumpAndSettle();
        await tester.tap(keepScopes());
        await tester.pumpAndSettle();

        expect(find.byType(ScopePicker), findsNothing);
        expect(find.byType(ApiKeyScopeList), findsOneWidget);
        // Focus goes to the button that took its place.
        expect(
          tester.widget<TextButton>(changeScopes()).focusNode!.hasPrimaryFocus,
          isTrue,
        );

        await rename(tester, 'Renamed');
        await pressSave(tester);
        expect(patchSent(), const ApiKeyPatch(name: 'Renamed'));

        await openPicker(tester);
        expect(
          picker(tester).selection,
          const PickedScopes([
            ApiKeyScope(slug: 'collection:read'),
            ApiKeyScope(slug: 'users:manage'),
          ]),
        );
      });

      testWidgets('a failed save keeps the picker open, with the picks', (
        tester,
      ) async {
        when(() => remote.update('k_1', any())).thenThrow(transient);
        await show(tester);
        await tick(tester, 'webhooks:manage');

        await pressSave(tester);

        expect(saveFailedBanner(), findsOneWidget);
        expect(
          picker(tester).selection,
          const PickedScopes([
            ApiKeyScope(slug: 'collection:read'),
            ApiKeyScope(slug: 'users:manage'),
            ApiKeyScope(slug: 'webhooks:manage'),
          ]),
        );
      });
    });

    testWidgets('a rename sends no scopes', (tester) async {
      // The key holds a permission its owner may no longer give: sending
      // the key's scopes back would be refused over it.
      answerKey(
        remote,
        apiKey(
          'k_1',
          scopes: const [
            ApiKeyScope(slug: 'events:delete'),
            ApiKeyScope(slug: 'collection:read'),
          ],
        ),
      );
      when(
        () => remote.update('k_1', any()),
      ).thenAnswer((_) async => key.copyWith(name: 'Renamed'));
      await show(tester);

      await rename(tester, '  Renamed ');
      await pressSave(tester);

      // Trimmed, and nothing else: no scopes, expiry, enabled or
      // confirmCritical.
      expect(patchSent(), const ApiKeyPatch(name: 'Renamed'));
    });

    testWidgets('a scope edit drops a no-longer-grantable scope and keeps '
        'pins', (tester) async {
      const pinned = ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1');
      const gone = ApiKeyScope(slug: 'events:delete');
      answerKey(
        remote,
        apiKey(
          'k_1',
          scopes: const [
            pinned,
            gone,
            ApiKeyScope(slug: 'collection:read'),
          ],
        ),
      );
      serverApplies(key);
      final semantics = tester.ensureSemantics();
      await show(tester);
      await openPicker(tester);
      // The pin is held, so ticked, and can't be changed here.
      final pinRow = tester.getSemantics(scopeRow(pinned));
      expect(
        pinRow.getSemanticsData().label,
        contains('Limited to one record'),
      );
      expect(
        pinRow,
        isSemantics(isChecked: true, isReadOnly: true, isEnabled: true),
      );
      expect(scopeRowLabel(tester, gone), contains('No longer available'));
      expect(
        scopeRowLabel(tester, gone),
        isNot(contains('saving removes it')),
      );

      await tick(tester, 'webhooks:manage');

      expect(
        scopeRowLabel(tester, gone),
        contains('No longer available; saving removes it'),
      );
      await pressSave(tester);

      final patch = patchSent();
      expect(
        patch.scopes,
        unorderedEquals(const [
          pinned,
          ApiKeyScope(slug: 'collection:read'),
          ApiKeyScope(slug: 'webhooks:manage'),
        ]),
      );
      expect(patch.name, isNull);
      expect(patch.expiresInDays, isNull);
      // Nothing Critical was added.
      expect(patch.confirmCritical, isFalse);
      semantics.dispose();
    });

    testWidgets('unticking a permission sends the rest, the pin as it was', (
      tester,
    ) async {
      const pinned = ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1');
      answerKey(
        remote,
        apiKey(
          'k_1',
          scopes: const [
            pinned,
            ApiKeyScope(slug: 'collection:read'),
          ],
        ),
      );
      serverApplies(key);
      await show(tester);

      await tick(tester, 'collection:read');
      await pressSave(tester);

      expect(patchSent(), const ApiKeyPatch(scopes: [pinned]));
    });

    testWidgets('a new expiry sends expiresInDays alone', (tester) async {
      serverApplies(key);
      await show(tester);

      await pickExpiry(tester, '30 days');
      await pressSave(tester);

      expect(patchSent(), const ApiKeyPatch(expiresInDays: 30));
    });

    testWidgets('Keep current takes back a mistaken expiry, so a rename sends '
        'the name alone', (tester) async {
      serverApplies(key);
      await show(tester);

      await pickExpiry(tester, '30 days');
      await rename(tester, 'Renamed');
      await pickExpiry(tester, 'Keep current');
      await pressSave(tester);

      expect(patchSent(), const ApiKeyPatch(name: 'Renamed'));
    });

    testWidgets('a custom expiry sends its days, and once saved the form '
        'has none chosen', (tester) async {
      serverApplies(key);
      await show(tester);

      await pickExpiry(tester, 'Custom');
      await tester.enterText(customDaysField(), '12');
      await tester.pumpAndSettle();
      await pressSave(tester);

      expect(patchSent(), const ApiKeyPatch(expiresInDays: 12));
      // The key's new expiry is a fact now; the choice starts again empty.
      expect(find.text('Expires Jun 1, 2027'), findsOneWidget);
      expect(expiry(tester).days, isNull);
      expect(customDaysField(), findsNothing);
      expect(
        tester
            .widget<ChoiceChip>(
              find.ancestor(
                of: find.text('Custom'),
                matching: find.byType(ChoiceChip),
              ),
            )
            .selected,
        isFalse,
      );
      await pressSave(tester);
      expect(nothingToSaveBanner(), findsOneWidget);
    });

    testWidgets('nothing changed sends nothing', (tester) async {
      await show(tester);

      await pressSave(tester);

      verifyNever(() => remote.update(any(), any()));
      expect(
        find.descendant(
          of: nothingToSaveBanner(),
          matching: find.text('Nothing to save'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(nothingToSaveBanner()).dy,
        lessThan(tester.getTopLeft(saveButton()).dy),
      );
    });

    testWidgets('a second press with nothing changed says so again, in a new '
        'live region', (tester) async {
      final semantics = tester.ensureSemantics();
      await show(tester);
      await pressSave(tester);
      final first = tester.element(nothingToSaveBanner());
      final firstNode = tester.getSemantics(find.text('Nothing to save')).id;
      expect(
        tester
            .getSemantics(find.text('Nothing to save'))
            .getSemanticsData()
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );

      await pressSave(tester);

      verifyNever(() => remote.update(any(), any()));
      expect(nothingToSaveBanner(), findsOneWidget);
      // Built anew, so a screen reader hears it arrive again.
      expect(tester.element(nothingToSaveBanner()), isNot(same(first)));
      final second = tester.getSemantics(find.text('Nothing to save'));
      expect(second.id, isNot(firstNode));
      expect(second.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      semantics.dispose();
    });

    testWidgets('a name typed back as it was, spaces and all, is nothing to '
        'save', (tester) async {
      await show(tester);

      await rename(tester, 'Something else');
      await rename(tester, ' CI deploy  ');
      await pressSave(tester);

      verifyNever(() => remote.update(any(), any()));
      expect(nothingToSaveBanner(), findsOneWidget);
    });

    testWidgets('a save that goes through says Saved, shows the key as the '
        'server answered it, and starts the form from it again', (
      tester,
    ) async {
      serverApplies(key);
      final semantics = tester.ensureSemantics();
      await show(tester);

      await rename(tester, 'Renamed');
      await tick(tester, 'webhooks:manage');
      await pickExpiry(tester, '30 days');
      await pressSave(tester);

      expect(
        patchSent(),
        const ApiKeyPatch(
          name: 'Renamed',
          scopes: [
            ApiKeyScope(slug: 'collection:read'),
            ApiKeyScope(slug: 'users:manage'),
            ApiKeyScope(slug: 'webhooks:manage'),
          ],
          expiresInDays: 30,
        ),
      );
      expect(
        find.descendant(of: savedBanner(), matching: find.text('Saved')),
        findsOneWidget,
      );
      // The app bar, the heading and the field.
      expect(find.text('Renamed'), findsNWidgets(3));
      expect(find.text('Expires Jun 1, 2027'), findsOneWidget);
      expect(find.text('3 permissions, highest risk Critical'), findsOneWidget);
      // Back to the key's permissions, as the server answered them.
      expect(find.byType(ScopePicker), findsNothing);
      expect(
        tester.widget<ApiKeyScopeList>(find.byType(ApiKeyScopeList)).scopes,
        const [
          ApiKeyScope(slug: 'collection:read'),
          ApiKeyScope(slug: 'users:manage'),
          ApiKeyScope(slug: 'webhooks:manage'),
        ],
      );
      expect(expiry(tester).days, isNull);
      // The banner stays: starting the form again is not an edit.
      await tester.pump(const Duration(seconds: 1));
      expect(savedBanner(), findsOneWidget);
      await openPicker(tester);
      expect(
        picker(tester).selection,
        const PickedScopes([
          ApiKeyScope(slug: 'collection:read'),
          ApiKeyScope(slug: 'users:manage'),
          ApiKeyScope(slug: 'webhooks:manage'),
        ]),
      );

      // So nothing differs from the key any more.
      await pressSave(tester);
      verifyNever(() => remote.update(any(), any()));
      expect(nothingToSaveBanner(), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('an edit retires Saved, Nothing to save and a failed save', (
      tester,
    ) async {
      serverApplies(key);
      await show(tester);

      await pressSave(tester);
      expect(nothingToSaveBanner(), findsOneWidget);
      await rename(tester, 'Renamed');
      expect(nothingToSaveBanner(), findsNothing);

      await pressSave(tester);
      expect(savedBanner(), findsOneWidget);
      await tick(tester, 'webhooks:manage');
      expect(savedBanner(), findsNothing);

      when(() => remote.update('k_1', any())).thenThrow(transient);
      await pressSave(tester);
      expect(saveFailedBanner(), findsOneWidget);
      await pickExpiry(tester, '30 days');
      expect(saveFailedBanner(), findsNothing);

      await pressSave(tester);
      expect(saveFailedBanner(), findsOneWidget);
      await rename(tester, 'Renamed again');
      expect(saveFailedBanner(), findsNothing);
    });

    testWidgets("an edit leaves a failed toggle's banner, which is about the "
        'switch', (tester) async {
      when(() => remote.update('k_1', any())).thenThrow(transient);
      await show(tester);
      await tapSwitch(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(ApiKeyDetailScreen.toggleFailedKey), findsOneWidget);

      await rename(tester, 'Renamed');
      await tick(tester, 'webhooks:manage');

      expect(find.byKey(ApiKeyDetailScreen.toggleFailedKey), findsOneWidget);
    });

    testWidgets('an unnamed key saves a new expiry alone, without being '
        'named', (tester) async {
      // Keys made outside the app can have no name.
      final unnamed = key.copyWith(name: null);
      answerKey(remote, unnamed);
      serverApplies(unnamed);
      await show(tester);
      expect(nameInput(tester).controller.text, isEmpty);

      await pickExpiry(tester, '30 days');
      await pressSave(tester);

      expect(patchSent(), const ApiKeyPatch(expiresInDays: 30));
      expect(find.text('Enter a name for the key.'), findsNothing);
      expect(savedBanner(), findsOneWidget);
    });

    testWidgets('an unnamed key left unnamed is nothing to save, and never '
        'sends an empty name', (tester) async {
      answerKey(remote, key.copyWith(name: null));
      await show(tester);

      await rename(tester, '   ');
      await pressSave(tester);

      verifyNever(() => remote.update(any(), any()));
      expect(find.text('Enter a name for the key.'), findsNothing);
      expect(nothingToSaveBanner(), findsOneWidget);
    });

    testWidgets('a name typed on an unnamed key is sent', (tester) async {
      final unnamed = key.copyWith(name: null);
      answerKey(remote, unnamed);
      serverApplies(unnamed);
      await show(tester);

      await rename(tester, '  Backup  ');
      await pressSave(tester);

      expect(patchSent(), const ApiKeyPatch(name: 'Backup'));
    });

    testWidgets('an empty name is refused and focused, and nothing is sent', (
      tester,
    ) async {
      await show(tester);

      await rename(tester, '   ');
      await pressSave(tester);

      verifyNever(() => remote.update(any(), any()));
      expect(find.text('Enter a name for the key.'), findsOneWidget);
      expect(nameInput(tester).focusNode.hasFocus, isTrue);
      expect(nothingToSaveBanner(), findsNothing);
    });

    testWidgets('a custom expiry that is no number of days is refused and '
        'focused, and nothing is sent', (tester) async {
      await show(tester);

      await pickExpiry(tester, 'Custom');
      await tester.enterText(customDaysField(), '400');
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await pressSave(tester);

      verifyNever(() => remote.update(any(), any()));
      expect(
        find.text('Enter a whole number of days from 1 to 365.'),
        findsOneWidget,
      );
      final field = tester.widget<EditableText>(
        find.descendant(
          of: customDaysField(),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.focusNode.hasFocus, isTrue);
      expect(nothingToSaveBanner(), findsNothing);
    });

    group('a Critical permission', () {
      testWidgets('adding a Critical permission asks; keeping one already '
          'held does not', (tester) async {
        offerPlugins();
        serverApplies(key);
        await show(tester);

        // The key holds Manage every user, which is Critical: an edit that
        // keeps it asks nothing.
        await tick(tester, 'webhooks:manage');
        await pressSave(tester);

        expect(find.text(criticalQuestion), findsNothing);
        expect(patchSent().confirmCritical, isFalse);

        // One it doesn't hold asks, and names that one alone.
        await tick(tester, 'plugins:manage');
        await pressSave(tester);

        expect(find.text(criticalQuestion), findsOneWidget);
        final dialog = find.byType(AlertDialog);
        expect(
          find.descendant(
            of: dialog,
            matching: find.text('Manage your plugins'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dialog, matching: find.text('Manage every user')),
          findsNothing,
        );
        verifyNever(() => remote.update(any(), any()));

        await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
        await tester.pumpAndSettle();

        final patch = patchSent();
        expect(patch.confirmCritical, isTrue);
        expect(
          patch.scopes,
          contains(const ApiKeyScope(slug: 'plugins:manage')),
        );
        expect(savedBanner(), findsOneWidget);
      });

      testWidgets('cancelling the question sends nothing, and keeps the '
          'edits', (tester) async {
        offerPlugins();
        await show(tester);
        await tick(tester, 'plugins:manage');

        await pressSave(tester);
        await tester.tap(find.byKey(CriticalConfirmDialog.cancelKey));
        await tester.pumpAndSettle();

        verifyNever(() => remote.update(any(), any()));
        expect(find.byType(AlertDialog), findsNothing);
        expect(saveFailedBanner(), findsNothing);
        expect(
          (picker(tester).selection as PickedScopes).scopes,
          contains(const ApiKeyScope(slug: 'plugins:manage')),
        );
      });

      testWidgets('pressing Save again retires a failed save before a '
          'question opens over it', (tester) async {
        offerPlugins();
        when(() => remote.update('k_1', any())).thenThrow(transient);
        await show(tester);
        await tick(tester, 'plugins:manage');
        await pressSave(tester);
        await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
        await tester.pumpAndSettle();
        expect(saveFailedBanner(), findsOneWidget);

        await pressSave(tester);

        // Left under the question's barrier, it would be read again as news
        // when the question closes.
        expect(find.text(criticalQuestion), findsOneWidget);
        expect(saveFailedBanner(), findsNothing);
      });

      testWidgets("a failed toggle's banner goes too before a question opens "
          'over it', (tester) async {
        offerPlugins();
        when(() => remote.update('k_1', any())).thenThrow(transient);
        await show(tester);
        await tapSwitch(tester);
        await tester.pumpAndSettle();
        await tick(tester, 'plugins:manage');
        expect(find.byKey(ApiKeyDetailScreen.toggleFailedKey), findsOneWidget);

        await pressSave(tester);

        expect(find.text(criticalQuestion), findsOneWidget);
        expect(find.byKey(ApiKeyDetailScreen.toggleFailedKey), findsNothing);
      });

      testWidgets("a screen reader's Save has focus back when the question "
          'closes', (tester) async {
        offerPlugins();
        final semantics = tester.ensureSemantics();
        await show(tester);
        await tick(tester, 'plugins:manage');
        await tester.ensureVisible(saveButton());
        await tester.pumpAndSettle();

        // A double tap with a screen reader moves no input focus of its own.
        tester.semantics.tap(find.semantics.byLabel('Save changes'));
        await tester.pumpAndSettle();
        expect(find.text(criticalQuestion), findsOneWidget);
        await tester.tap(find.byKey(CriticalConfirmDialog.cancelKey));
        await tester.pumpAndSettle();

        expect(saveFocus(tester).hasPrimaryFocus, isTrue);
        semantics.dispose();
      });

      group('the server finds one the page did not', () {
        // The page was read before the permission became Critical.
        final wasHigh = permission(
          'plugins:manage',
          description: 'Manage your plugins',
          riskLevel: RiskLevel.high,
        );

        void permissionsChangeUnderThePage() {
          var reads = 0;
          when(remote.fetchGrantable).thenAnswer(
            (_) async => [
              readCollection,
              manageUsers,
              manageHooks,
              if (reads++ == 0) wasHigh else managePlugins,
            ],
          );
        }

        testWidgets('a server CRITICAL_NEEDS_CONFIRMATION asks, then saves '
            'once more, confirmed', (tester) async {
          permissionsChangeUnderThePage();
          var calls = 0;
          when(() => remote.update('k_1', any())).thenAnswer((_) async {
            if (calls++ == 0) throw needsConfirmation;
            return key;
          });
          await show(tester);
          await tick(tester, 'plugins:manage');

          await pressSave(tester);

          // Nothing new was Critical when the page asked, so it sent
          // unconfirmed; the server's answer asks, naming the permission
          // from the list read again.
          expect(find.text(criticalQuestion), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Manage your plugins'),
            ),
            findsOneWidget,
          );
          // The question says it: no banner under it says it again.
          expect(saveFailedBanner(), findsNothing);

          await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
          await tester.pumpAndSettle();

          final patches = patchesSent();
          expect(patches.map((patch) => patch.confirmCritical), [false, true]);
          expect(patches.last.scopes, patches.first.scopes);
          expect(savedBanner(), findsOneWidget);
        });

        testWidgets('a second one is a failure, not another question', (
          tester,
        ) async {
          permissionsChangeUnderThePage();
          when(
            () => remote.update('k_1', any()),
          ).thenThrow(needsConfirmation);
          await show(tester);
          await tick(tester, 'plugins:manage');
          await pressSave(tester);

          await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
          await tester.pumpAndSettle();

          expect(find.byType(AlertDialog), findsNothing);
          expect(
            find.descendant(
              of: saveFailedBanner(),
              matching: find.text(
                'A Critical permission needs your confirmation first.',
              ),
            ),
            findsOneWidget,
          );
          expect(patchesSent(), hasLength(2));
        });

        testWidgets('cancelling it sends nothing more and leaves no failure', (
          tester,
        ) async {
          permissionsChangeUnderThePage();
          when(
            () => remote.update('k_1', any()),
          ).thenThrow(needsConfirmation);
          await show(tester);
          await tick(tester, 'plugins:manage');
          await pressSave(tester);

          await tester.tap(find.byKey(CriticalConfirmDialog.cancelKey));
          await tester.pumpAndSettle();

          expect(patchesSent(), hasLength(1));
          expect(saveFailedBanner(), findsNothing);
          expect(find.text('Save changes'), findsOneWidget);
        });
      });
    });

    group('a refusal', () {
      testWidgets('needs recent sign-in on save says sign out and in again', (
        tester,
      ) async {
        offerPlugins();
        when(() => remote.update('k_1', any())).thenThrow(
          const ApiKeyNeedsRecentSignInException('stale', apiMessage: 'Again.'),
        );
        await show(tester);
        await tick(tester, 'plugins:manage');
        await pressSave(tester);

        await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
        await tester.pumpAndSettle();

        final banner = saveFailedBanner();
        expect(banner, findsOneWidget);
        expect(
          find.descendant(of: banner, matching: find.text(saveFailedTitle)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: banner,
            matching: find.text(
              'Giving a key a Critical permission needs a recent sign-in. '
              'Sign out, sign in again, then try once more.',
            ),
          ),
          findsOneWidget,
        );
        // Text only: signing in again without leaving the page is #1113.
        expect(tester.widget<BgeInlineBanner>(banner).action, isNull);
        // On the button it answers.
        expect(
          tester.getTopLeft(banner).dy,
          lessThan(tester.getTopLeft(saveButton()).dy),
        );
      });

      testWidgets('a save failure keeps the edits on screen', (tester) async {
        when(() => remote.update('k_1', any())).thenThrow(transient);
        await show(tester);
        await rename(tester, 'Renamed');
        await tick(tester, 'webhooks:manage');
        await pickExpiry(tester, '30 days');

        await pressSave(tester);

        expect(
          find.descendant(
            of: saveFailedBanner(),
            matching: find.text(saveFailedTitle),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: saveFailedBanner(),
            matching: find.text(unreachable),
          ),
          findsOneWidget,
        );
        expect(nameInput(tester).controller.text, 'Renamed');
        expect(
          picker(tester).selection,
          const PickedScopes([
            ApiKeyScope(slug: 'collection:read'),
            ApiKeyScope(slug: 'users:manage'),
            ApiKeyScope(slug: 'webhooks:manage'),
          ]),
        );
        expect(expiry(tester).days, 30);
        // The key is as it was.
        expect(find.text('CI deploy'), findsNWidgets(2));
        expect(find.text('Expires Feb 1, 2027'), findsOneWidget);

        // Sent again as it stands.
        when(
          () => remote.update('k_1', any()),
        ).thenAnswer((_) async => key);
        await pressSave(tester);
        final patches = patchesSent();
        expect(patches, hasLength(2));
        expect(patches.last, patches.first);
      });

      testWidgets('one that names a permission is said on its row too', (
        tester,
      ) async {
        when(() => remote.update('k_1', any())).thenThrow(
          const ApiKeyScopeNotGrantableException('no', slug: 'webhooks:manage'),
        );
        final semantics = tester.ensureSemantics();
        await show(tester);
        await tick(tester, 'webhooks:manage');

        await pressSave(tester);

        const words =
            "You can't give a key the permission Manage your webhook "
            'subscriptions.';
        expect(
          find.descendant(of: saveFailedBanner(), matching: find.text(words)),
          findsOneWidget,
        );
        expect(
          scopeRowLabel(tester, const ApiKeyScope(slug: 'webhooks:manage')),
          contains(words),
        );
        expect(
          scopeRowLabel(tester, const ApiKeyScope(slug: 'collection:read')),
          isNot(contains(words)),
        );
        semantics.dispose();
      });

      testWidgets('a 404 on a save says the key is gone', (tester) async {
        when(
          () => remote.update('k_1', any()),
        ).thenThrow(const ApiKeyNotFoundException('gone'));
        await show(tester);
        await rename(tester, 'Renamed');

        await pressSave(tester);

        expect(find.byKey(ApiKeyDetailScreen.goneKey), findsOneWidget);
        final focused = FocusManager.instance.primaryFocus;
        expect(focused, isNot(isA<FocusScopeNode>()));
        expect(focused?.context?.mounted, isTrue);
      });
    });

    group('while a write is on its way', () {
      testWidgets('fields go read-only while saving, not disabled', (
        tester,
      ) async {
        final answer = Completer<ApiKey>();
        when(
          () => remote.update('k_1', any()),
        ).thenAnswer((_) => answer.future);
        final semantics = tester.ensureSemantics();
        await show(tester);
        await rename(tester, 'Renamed');
        await openPicker(tester);

        await pressSaveHeld(tester);

        // Read-only, not disabled: each stays where a reader left it.
        expect(nameInput(tester).readOnly, isTrue);
        expect(picker(tester).readOnly, isTrue);
        expect(
          tester.getSemantics(keepScopes()),
          isSemantics(isEnabled: false, isFocusable: true, hasTapAction: false),
        );
        expect(expiry(tester).readOnly, isTrue);
        // Save keeps focus, and says it is saving as it starts.
        expect(find.text('Saving changes…'), findsOneWidget);
        final node = tester.getSemantics(saveButton()).getSemanticsData();
        expect(node.label, 'Saving changes…');
        expect(node.flagsCollection.isLiveRegion, isTrue);
        expect(saveFocus(tester).hasPrimaryFocus, isTrue);
        // The writes no press of their own started wait, disabled.
        expect(switchTile(tester).onChanged, isNull);
        expect(tester.widget<TextButton>(deleteButton()).onPressed, isNull);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await pumpEvent(tester);
        expect(patchesSent(), hasLength(1));

        answer.complete(key.copyWith(name: 'Renamed'));
        await tester.pumpAndSettle();

        expect(nameInput(tester).readOnly, isFalse);
        expect(saveFocus(tester).hasPrimaryFocus, isTrue);
        expect(savedBanner(), findsOneWidget);
        expect(switchTile(tester).onChanged, isNotNull);
        // At rest Save is no live region, so its name coming back is not
        // read over the banner.
        expect(
          tester
              .getSemantics(saveButton())
              .getSemanticsData()
              .flagsCollection
              .isLiveRegion,
          isFalse,
        );
        semantics.dispose();
      });

      testWidgets('a failure leaves focus on Save, to send it again', (
        tester,
      ) async {
        final answer = Completer<ApiKey>();
        when(
          () => remote.update('k_1', any()),
        ).thenAnswer((_) => answer.future);
        await show(tester);
        await rename(tester, 'Renamed');

        await pressSaveHeld(tester);
        answer.completeError(transient);
        await tester.pumpAndSettle();

        expect(saveFailedBanner(), findsOneWidget);
        expect(saveFocus(tester).hasPrimaryFocus, isTrue);
        expect(nameInput(tester).readOnly, isFalse);
      });

      testWidgets('while a toggle is on its way Save waits, disabled, and the '
          'fields are read-only', (tester) async {
        final answer = Completer<ApiKey>();
        when(
          () => remote.update('k_1', any()),
        ).thenAnswer((_) => answer.future);
        await show(tester);
        await rename(tester, 'Renamed');

        await tapSwitch(tester);
        await pumpEvent(tester);

        expect(tester.widget<FilledButton>(saveButton()).onPressed, isNull);
        expect(nameInput(tester).readOnly, isTrue);
        expect(expiry(tester).readOnly, isTrue);
        // The swap to the picker is read-only too: a press does nothing.
        expect(
          tester.getSemantics(changeScopes()),
          isSemantics(isEnabled: false, isFocusable: true, hasTapAction: false),
        );
        await tester.ensureVisible(changeScopes());
        await tester.tap(changeScopes());
        await pumpEvent(tester);
        expect(find.byType(ScopePicker), findsNothing);

        answer.complete(key.copyWith(enabled: false));
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(saveButton()).onPressed, isNotNull);
        // The edit is kept through it.
        expect(nameInput(tester).controller.text, 'Renamed');
      });
    });

    testWidgets('when the permissions you can give could not be read, they '
        'are not offered, and a rename still saves', (tester) async {
      when(remote.fetchGrantable).thenThrow(transient);
      when(
        () => remote.update('k_1', any()),
      ).thenAnswer((_) async => key.copyWith(name: 'Renamed'));
      await show(tester);

      expect(find.byType(ScopePicker), findsNothing);
      expect(find.text(notEditable), findsOneWidget);
      // The scopes still show, by their codes.
      expect(find.text('collection:read'), findsOneWidget);

      await rename(tester, 'Renamed');
      await pickExpiry(tester, '90 days');
      await pressSave(tester);

      expect(
        patchSent(),
        const ApiKeyPatch(name: 'Renamed', expiresInDays: 90),
      );
      expect(savedBanner(), findsOneWidget);
    });

    group('after the screen has gone', () {
      testWidgets('a save that lands says it was saved, on the page beneath', (
        tester,
      ) async {
        final answer = Completer<ApiKey>();
        when(
          () => remote.update('k_1', any()),
        ).thenAnswer((_) => answer.future);
        await showPushed(tester);
        await rename(tester, 'Renamed');
        await pressSaveHeld(tester);
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();

        answer.complete(key.copyWith(name: 'Renamed'));
        await tester.pumpAndSettle();

        expect(find.text(pageBeneathCopy), findsOneWidget);
        expect(find.text('Saved changes to Renamed'), findsOneWidget);
      });

      testWidgets('a failed one says why, since its banner went with the '
          'screen', (tester) async {
        final answer = Completer<ApiKey>();
        when(
          () => remote.update('k_1', any()),
        ).thenAnswer((_) => answer.future);
        await showPushed(tester);
        await rename(tester, 'Renamed');
        await pressSaveHeld(tester);
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();

        answer.completeError(transient);
        await tester.pumpAndSettle();

        expect(find.text('$saveFailedTitle: $unreachable'), findsOneWidget);
      });
    });
  });

  group('small', () {
    Future<void> at320x2(WidgetTester tester) async {
      useViewSize(tester, const Size(320, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      answerKey(
        remote,
        apiKey(
          'k_1',
          name: 'A rather long name of 32 chars!!',
          scopes: const [
            ApiKeyScope(slug: 'collection:read'),
            ApiKeyScope(slug: 'users:manage'),
            ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1'),
            ApiKeyScope(slug: 'events:delete'),
          ],
          expiresAt: expires,
          lastUsedAt: used,
        ),
      );
    }

    testWidgets('320dp at 2.0 lays out the key without overflow', (
      tester,
    ) async {
      await at320x2(tester);
      when(() => remote.delete('k_1')).thenThrow(transient);

      await show(tester);
      await confirmDelete(tester);

      expect(tester.takeException(), isNull);
      expect(find.byKey(ApiKeyDetailScreen.deleteFailedKey), findsOneWidget);
    });

    testWidgets('320dp at 2.0 lays out the edit form, a custom expiry and a '
        'refusal on a row without overflow', (tester) async {
      await at320x2(tester);
      when(() => remote.update('k_1', any())).thenThrow(
        const ApiKeyScopeNotGrantableException('no', slug: 'webhooks:manage'),
      );
      await show(tester);

      await tick(tester, 'webhooks:manage');
      await pickExpiry(tester, 'Custom');
      await tester.enterText(customDaysField(), '12');
      await tester.pumpAndSettle();
      await pressSave(tester);

      expect(tester.takeException(), isNull);
      expect(saveFailedBanner(), findsOneWidget);
    });

    testWidgets('320dp at 2.0 lays out Save while it is busy without '
        'overflow', (tester) async {
      await at320x2(tester);
      final answer = Completer<ApiKey>();
      when(
        () => remote.update('k_1', any()),
      ).thenAnswer((_) => answer.future);
      await show(tester);
      await rename(tester, 'Renamed');

      await pressSaveHeld(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Saving changes…'), findsOneWidget);
      answer.complete(key);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('accessibility audit', () {
    // Names the screen for tool/check_a11y_audit.dart: ApiKeyDetailScreen.
    //
    // With the edit form the page runs well below the fold at 320dp × 2.0,
    // and a scroll to a control down it can leave another cut by the top
    // edge, which the tap-target check fails at its cut size. A state
    // reached down the page is audited whole instead, in a view tall enough
    // to hold it.
    Widget Function(ThemeData) screenWith(
      void Function() seed, {
      bool offline = false,
    }) => (theme) {
      seed();
      return screen(theme: theme, offline: offline);
    };

    void nothing() {}

    /// Audits the page with nothing below the fold.
    Future<void> whole(WidgetTester tester) async {
      await useWholePage(tester);
      expectWholePage(tester);
    }

    void everyKind() => answerKey(
      remote,
      apiKey(
        'k_1',
        scopes: const [
          ApiKeyScope(slug: 'collection:read'),
          ApiKeyScope(slug: 'users:manage'),
          ApiKeyScope(slug: 'webhooks:manage', resourceId: 'wh_1'),
          ApiKeyScope(slug: 'events:delete'),
        ],
        expiresAt: expires,
        lastUsedAt: used,
      ),
    );

    auditScreen(
      'loaded',
      build: screenWith(everyKind),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(enabledSwitch(), findsOneWidget);
      },
    );

    auditScreen(
      'loaded, whole, to Delete',
      build: screenWith(everyKind),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        expect(deleteButton(), findsOneWidget);
      },
    );

    auditScreen(
      'the permissions listed, whole, with Change permissions',
      build: screenWith(everyKind),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        expect(find.byType(ApiKeyScopeList), findsOneWidget);
        expect(changeScopes(), findsOneWidget);
      },
    );

    auditScreen(
      'Change permissions open, whole, with Keep permissions as they were',
      build: screenWith(everyKind),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await openPicker(tester);
        await whole(tester);
        expect(keepScopes(), findsOneWidget);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'edit form, whole, with a permission ticked and a custom expiry',
      build: screenWith(everyKind),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await rename(tester, 'Renamed');
        await tick(tester, 'users:manage');
        await pickExpiry(tester, 'Custom');
        await tester.enterText(customDaysField(), '12');
        await tester.pumpAndSettle();
        expect(
          find.text('No longer available; saving removes it'),
          findsOneWidget,
        );
        expectWholePage(tester);
      },
    );

    auditScreen(
      'edit form, refused: no name, and a custom expiry that is no number',
      build: screenWith(nothing),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await rename(tester, '');
        await pickExpiry(tester, 'Custom');
        await tester.enterText(customDaysField(), '0');
        await tester.pumpAndSettle();
        await pressSave(tester);
        expect(find.text('Enter a name for the key.'), findsOneWidget);
        expect(
          find.text('Enter a whole number of days from 1 to 365.'),
          findsOneWidget,
        );
        expectWholePage(tester);
      },
    );

    auditScreen(
      'nothing to save',
      build: screenWith(nothing),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await pressSave(tester);
        expect(nothingToSaveBanner(), findsOneWidget);
      },
    );

    auditScreen(
      'saving',
      build: screenWith(
        () => when(
          () => remote.update('k_1', any()),
        ).thenAnswer((_) => Completer<ApiKey>().future),
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await rename(tester, 'Renamed');
        await pressSaveHeld(tester);
        expect(find.text('Saving changes…'), findsOneWidget);
      },
    );

    auditScreen(
      'saved',
      build: screenWith(() => serverApplies(key)),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await rename(tester, 'Renamed');
        await pickExpiry(tester, '30 days');
        await pressSave(tester);
        expect(savedBanner(), findsOneWidget);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'save failed, with the refused permission named on its row',
      build: screenWith(
        () => when(() => remote.update('k_1', any())).thenThrow(
          const ApiKeyScopeNotGrantableException(
            'no',
            slug: 'webhooks:manage',
          ),
        ),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await tick(tester, 'webhooks:manage');
        await pressSave(tester);
        expect(saveFailedBanner(), findsOneWidget);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'Critical confirmation',
      build: screenWith(offerPlugins),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await tick(tester, 'plugins:manage');
        await pressSave(tester);
        expect(find.text(criticalQuestion), findsOneWidget);
        expectWholePage(tester, within: find.byType(AlertDialog));
      },
    );

    auditScreen(
      'offline',
      build: screenWith(nothing, offline: true),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        expect(find.text(onlineOnlyCopy), findsNWidgets(3));
      },
    );

    auditScreen(
      'grantable failed',
      build: screenWith(() {
        everyKind();
        when(remote.fetchGrantable).thenThrow(transient);
      }),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.text('collection:read'), findsOneWidget);
      },
    );

    auditScreen(
      'grantable failed, whole',
      build: screenWith(() {
        everyKind();
        when(remote.fetchGrantable).thenThrow(transient);
      }),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        expect(find.text(notEditable), findsOneWidget);
      },
    );

    auditScreen(
      'toggle failed',
      build: screenWith(
        () => when(() => remote.update('k_1', any())).thenThrow(transient),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await tester.tap(enabledSwitch());
        await tester.pumpAndSettle();
        expect(find.byKey(ApiKeyDetailScreen.toggleFailedKey), findsOneWidget);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'delete failed',
      build: screenWith(
        () => when(() => remote.delete('k_1')).thenThrow(transient),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await confirmDelete(tester);
        expect(find.byKey(ApiKeyDetailScreen.deleteFailedKey), findsOneWidget);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'gone',
      build: screenWith(
        () => when(
          () => remote.fetch('k_1'),
        ).thenThrow(const ApiKeyNotFoundException('gone')),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(ApiKeyDetailScreen.goneKey), findsOneWidget);
      },
    );

    auditScreen(
      'failed',
      build: screenWith(
        () => when(() => remote.fetch('k_1')).thenThrow(transient),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(ApiKeyDetailScreen.failedKey), findsOneWidget);
      },
    );

    auditScreen(
      'loading',
      build: screenWith(
        () => when(
          () => remote.fetch('k_1'),
        ).thenAnswer((_) => Completer<ApiKey>().future),
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pump();
        expect(find.byKey(ApiKeyDetailScreen.loadingKey), findsOneWidget);
      },
    );
  });
}
