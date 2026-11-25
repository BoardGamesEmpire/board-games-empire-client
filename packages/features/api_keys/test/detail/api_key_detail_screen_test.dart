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

import '../support/fixtures.dart';
import '../support/harness.dart';

void main() {
  late MockApiKeyRemoteDataSource remote;
  late FakeSessionLease lease;

  // Noon UTC, so the date is the same in every zone a test machine is in.
  final expires = DateTime.utc(2027, 2, 1, 12);
  final used = DateTime.utc(2026, 11, 20, 12);

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
  ).copyWith(createdAt: DateTime.utc(2026, 11, 1, 12));

  const transient = ApiKeyTransientException('down');
  const unreachable =
      "Couldn't reach the server. Check your connection, then try again.";

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
      tester.getSemantics(find.text(title)).label;

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

  group('reading', () {
    testWidgets('the key reads its name, start, permissions, dates and '
        'whether it works', (tester) async {
      await show(tester);

      // The name heads the page as well as the app bar, which cuts a long
      // one short at 200% text.
      expect(find.text('CI deploy'), findsNWidgets(2));
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

      expect(
        rowLabel(tester, 'Manage your webhook subscriptions'),
        allOf(contains('Risk: High'), contains('Limited to one record')),
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

      expect(find.text('CI deploy'), findsNWidgets(2));
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
      expect(switchTile(tester).onChanged, isNotNull);
    });

    testWidgets('a key with no permissions says it works nowhere until it has '
        'some', (tester) async {
      answerKey(remote, apiKey('k_1', scopes: const []));
      await show(tester);

      expect(
        find.text(
          'This key has no permissions, so it works nowhere until it is '
          'given some.',
        ),
        findsOneWidget,
      );
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
      expect(find.text('CI deploy'), findsNWidgets(2));
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
      expect(find.text('CI deploy'), findsNWidgets(2));

      // The router keeps the page for a go to another id of the same route,
      // and builds the screen again with the new id.
      await tester.pumpWidget(screen(id: 'k_2'));
      await tester.pumpAndSettle();

      expect(find.text('Backup'), findsNWidgets(2));
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

      await tester.tap(enabledSwitch());
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
    testWidgets('offline, the switch and Delete are disabled and say why', (
      tester,
    ) async {
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
      // Drawn once for each control: in the switch's label, under Delete.
      expect(find.text(onlineOnlyCopy), findsNWidgets(2));
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
      await tester.tap(enabledSwitch());
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
      await tester.tap(enabledSwitch());
      await pumpEvent(tester);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      answer.complete(key.copyWith(enabled: false));
      await tester.pumpAndSettle();

      expect(find.text('Disabled CI deploy'), findsOneWidget);
    });
  });

  testWidgets('320dp at 2.0 lays out the key without overflow', (
    tester,
  ) async {
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
    when(() => remote.delete('k_1')).thenThrow(transient);

    await show(tester);
    await confirmDelete(tester);

    expect(tester.takeException(), isNull);
    expect(find.byKey(ApiKeyDetailScreen.deleteFailedKey), findsOneWidget);
  });

  group('accessibility audit', () {
    // Names the screen for tool/check_a11y_audit.dart: ApiKeyDetailScreen.
    Widget Function(ThemeData) screenWith(void Function() seed) => (theme) {
      seed();
      return screen(theme: theme);
    };

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
      'loaded, scrolled to Delete',
      build: screenWith(everyKind),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await tester.ensureVisible(deleteButton());
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
      'toggle failed',
      build: screenWith(
        () => when(() => remote.update('k_1', any())).thenThrow(transient),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        // At 200% text the switch starts below the fold.
        await tester.ensureVisible(enabledSwitch());
        await tester.pumpAndSettle();
        await tester.tap(enabledSwitch());
        await tester.pumpAndSettle();
        expect(find.byKey(ApiKeyDetailScreen.toggleFailedKey), findsOneWidget);
      },
    );

    auditScreen(
      'delete failed',
      build: screenWith(
        () => when(() => remote.delete('k_1')).thenThrow(transient),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await confirmDelete(tester);
        expect(find.byKey(ApiKeyDetailScreen.deleteFailedKey), findsOneWidget);
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
