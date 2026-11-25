import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:api_keys/api_keys.dart';
import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

void main() {
  late MockApiKeyRemoteDataSource remote;

  final readGames = permission(
    'collection:read',
    description: 'Read your game collection',
  );
  final changeGames = permission(
    'collection:write',
    description: 'Change your game collection',
    riskLevel: RiskLevel.medium,
  );
  final manageUsers = permission(
    'users:manage',
    description: 'Manage every user',
    riskLevel: RiskLevel.critical,
  );

  const secret = 'bge_s3cr3t_a1B2c3D4e5F6';
  final made = CreatedApiKey(apiKey: apiKey('k_new'), secret: secret);

  const transient = ApiKeyTransientException('down');
  const needsConfirmation = ApiKeyCriticalNeedsConfirmationException(
    'unconfirmed',
  );
  const unreachable =
      "Couldn't reach the server. Check your connection, then try again.";
  const noneWarning = 'With no permissions, this key works nowhere.';
  const criticalQuestion = 'Give this key Critical permissions?';
  const leaveQuestion = 'Leave without copying?';
  const failedTitle = "Couldn't create the key";

  setUpAll(
    () => registerFallbackValue(
      const ApiKeyCreate(name: 'x', grant: ApiKeyEverythingGrant()),
    ),
  );

  setUp(() {
    remote = MockApiKeyRemoteDataSource();
    answerGrantable(remote, [readGames, changeGames, manageUsers]);
    when(() => remote.create(any())).thenAnswer((_) async => made);
  });

  Widget screen({ThemeData? theme, bool offline = false}) => hostScreen(
    ApiKeyCreateScreen(remote: remote),
    theme: theme,
    offline: offline,
  );

  Future<void> show(WidgetTester tester, {bool offline = false}) async {
    await tester.pumpWidget(screen(offline: offline));
    await tester.pumpAndSettle();
  }

  /// Shows the screen pushed over a page, as the app has it over the list.
  Future<void> showPushed(WidgetTester tester) async {
    await tester.pumpWidget(hostOverPage(ApiKeyCreateScreen(remote: remote)));
    await tester.pumpAndSettle();
    expect(find.text(pageBeneathCopy), findsNothing);
  }

  Finder nameField() => find.byKey(ApiKeyCreateScreen.nameKey);

  EditableText nameInput(WidgetTester tester) => tester.widget<EditableText>(
    find.descendant(of: nameField(), matching: find.byType(EditableText)),
  );

  Finder createButton() => find.byKey(ApiKeyCreateScreen.submitKey);

  FocusNode createFocus(WidgetTester tester) =>
      tester.widget<FilledButton>(createButton()).focusNode!;

  Finder failureBanner() => find.byKey(ApiKeyCreateScreen.errorKey);

  /// Lets a bloc event reach the screen without waiting for a busy cue,
  /// which never settles.
  Future<void> pumpEvent(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> enterName(
    WidgetTester tester, [
    String name = 'CI deploy',
  ]) async {
    await tester.enterText(nameField(), name);
    await tester.pumpAndSettle();
  }

  /// Ticks or unticks the permission described as [description].
  Future<void> tick(WidgetTester tester, String description) async {
    final row = find.text(description);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  Future<void> switchEverything(WidgetTester tester) async {
    final row = find.byKey(ScopePicker.everythingKey);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// Presses Create, and lets whatever it opens or answers arrive. For a
  /// create that is held, use [pressCreateHeld].
  Future<void> pressCreate(WidgetTester tester) async {
    await tester.ensureVisible(createButton());
    await tester.pumpAndSettle();
    await tester.tap(createButton());
    await tester.pumpAndSettle();
  }

  /// Presses Create from the keyboard, with focus on it, and does not wait
  /// for a spinner to settle.
  Future<void> pressCreateHeld(WidgetTester tester) async {
    await tester.ensureVisible(createButton());
    await tester.pumpAndSettle();
    createFocus(tester).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpEvent(tester);
  }

  /// Names a key and creates it with no permissions, to its secret.
  Future<void> createKey(WidgetTester tester) async {
    await enterName(tester);
    await pressCreate(tester);
    expect(find.byType(SecretPanel), findsOneWidget);
  }

  /// What the one create call was sent.
  ApiKeyCreate sent() =>
      verify(() => remote.create(captureAny())).captured.single as ApiKeyCreate;

  /// Whether keyboard focus is on the page's title, which reads [title].
  bool focusIsOnTitle(String title) {
    final focused = FocusManager.instance.primaryFocus;
    final context = focused?.context;
    if (focused == null || focused is FocusScopeNode || context == null) {
      return false;
    }
    return find
        .descendant(
          of: find.byElementPredicate((element) => identical(element, context)),
          matching: find.text(title),
        )
        .evaluate()
        .isNotEmpty;
  }

  /// What a screen reader reads for the permission row titled [description].
  String rowLabel(WidgetTester tester, String description) =>
      tester.getSemantics(find.text(description)).getSemanticsData().label;

  /// The nothing-picked warning under the permissions.
  BgeInlineBanner noneBanner(WidgetTester tester) =>
      tester.widget<BgeInlineBanner>(
        find.ancestor(
          of: find.text(noneWarning),
          matching: find.byType(BgeInlineBanner),
        ),
      );

  group('the form', () {
    testWidgets('offers a name, the permissions with Everything I can do, '
        'the expiry with 90 days chosen, and Create', (tester) async {
      await show(tester);

      expect(find.text('Create an API key'), findsOneWidget);
      expect(nameField(), findsOneWidget);
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Permissions'), findsOneWidget);
      expect(find.text('Everything I can do'), findsOneWidget);
      for (final each in [readGames, changeGames, manageUsers]) {
        expect(find.text(each.description), findsOneWidget);
      }
      expect(find.text('Expires in'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(
              find.ancestor(
                of: find.text('90 days'),
                matching: find.byType(ChoiceChip),
              ),
            )
            .selected,
        isTrue,
      );
      expect(find.text('Create key'), findsOneWidget);
      verify(remote.fetchGrantable).called(1);
    });

    testWidgets('while the permissions load it says so, and a failed read '
        'offers Try again, which reads again', (tester) async {
      final retried = Completer<List<GrantablePermission>>();
      var reads = 0;
      when(remote.fetchGrantable).thenAnswer(
        (_) => reads++ == 0 ? Future.error(transient) : retried.future,
      );
      await show(tester);

      expect(find.byKey(ApiKeyCreateScreen.failedKey), findsOneWidget);
      expect(
        find.text("Couldn't load the permissions you can give a key"),
        findsOneWidget,
      );
      expect(nameField(), findsNothing);

      // The retry is autofocused; a keyboard press goes as the read starts.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(find.byKey(ApiKeyCreateScreen.loadingKey), findsOneWidget);
      expect(focusIsOnTitle('Create an API key'), isTrue);

      retried.complete([readGames]);
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(nameField(), findsOneWidget);
    });

    testWidgets('an empty name is refused and focused', (tester) async {
      await show(tester);

      await pressCreate(tester);

      verifyNever(() => remote.create(any()));
      expect(find.text('Enter a name for the key.'), findsOneWidget);
      expect(nameInput(tester).focusNode.hasPrimaryFocus, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a name of only spaces is refused', (tester) async {
      await show(tester);
      await enterName(tester, '   ');

      await pressCreate(tester);

      verifyNever(() => remote.create(any()));
      expect(find.text('Enter a name for the key.'), findsOneWidget);
    });

    testWidgets('a 33-character name is refused', (tester) async {
      await show(tester);
      await enterName(tester, 'a' * 33);

      await pressCreate(tester);

      verifyNever(() => remote.create(any()));
      expect(find.text('Use 32 characters at most.'), findsOneWidget);
      expect(nameInput(tester).focusNode.hasPrimaryFocus, isTrue);
    });

    testWidgets('a 32-character name with spaces around it is sent trimmed', (
      tester,
    ) async {
      await show(tester);
      await enterName(tester, '  ${'a' * 32} ');

      await pressCreate(tester);

      expect(sent().name, 'a' * 32);
    });

    testWidgets('a custom expiry that is no number of days is refused and '
        'focused', (tester) async {
      await show(tester);
      await enterName(tester);
      await tester.ensureVisible(find.text('Custom'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      final days = find.ancestor(
        of: find.text('Number of days'),
        matching: find.byType(BgeTextField),
      );
      await tester.enterText(days, '400');
      await tester.pumpAndSettle();

      await pressCreate(tester);

      verifyNever(() => remote.create(any()));
      expect(
        find.text('Enter a whole number of days from 1 to 365.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: days, matching: find.byType(EditableText)),
            )
            .focusNode
            .hasPrimaryFocus,
        isTrue,
      );
    });

    testWidgets('no Critical pick sends confirmCritical absent', (
      tester,
    ) async {
      await show(tester);
      await enterName(tester);
      await tick(tester, readGames.description);
      await tick(tester, changeGames.description);

      await pressCreate(tester);

      expect(find.text(criticalQuestion), findsNothing);
      final request = sent();
      expect(
        request,
        const ApiKeyCreate(
          name: 'CI deploy',
          grant: ApiKeyScopesGrant([
            ApiKeyScope(slug: 'collection:read'),
            ApiKeyScope(slug: 'collection:write'),
          ]),
        ),
      );
      expect(request.confirmCritical, isFalse);
      // What the form starts with, and the server's own default.
      expect(request.expiresInDays, 90);
    });

    testWidgets('the expiry chosen is the days sent', (tester) async {
      await show(tester);
      await enterName(tester);
      await tester.ensureVisible(find.text('30 days'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 days'));
      await tester.pumpAndSettle();

      await pressCreate(tester);

      expect(sent().expiresInDays, 30);
    });

    testWidgets('a key with no permissions may be made, and the form says '
        'it will work nowhere', (tester) async {
      await show(tester);
      await enterName(tester);
      expect(find.text(noneWarning), findsOneWidget);

      await pressCreate(tester);

      expect(sent().grant, const ApiKeyScopesGrant([]));
    });

    testWidgets('the nowhere warning is furniture on a form nobody has '
        'touched, and news once the user empties the picks', (tester) async {
      await show(tester);

      // Said on open, it would be the first thing a screen reader hears of
      // a form nobody has filled in yet.
      expect(noneBanner(tester).announce, isFalse);

      await tick(tester, readGames.description);
      expect(find.text(noneWarning), findsNothing);
      await tick(tester, readGames.description);

      expect(noneBanner(tester).announce, isTrue);
    });
  });

  group('a Critical permission', () {
    testWidgets('the preset with a Critical grantable asks first', (
      tester,
    ) async {
      await show(tester);
      await enterName(tester);
      await switchEverything(tester);

      await pressCreate(tester);

      expect(find.text(criticalQuestion), findsOneWidget);
      // Named by what it lets a key do, in the dialog as well as on its row.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Manage every user'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Read your game collection'),
        ),
        findsNothing,
      );
      expect(
        find.text('The server may ask you to sign in again first.'),
        findsOneWidget,
      );
      verifyNever(() => remote.create(any()));
    });

    testWidgets('cancelling the Critical confirmation sends nothing', (
      tester,
    ) async {
      await show(tester);
      await enterName(tester);
      await switchEverything(tester);
      await pressCreate(tester);

      await tester.tap(find.byKey(CriticalConfirmDialog.cancelKey));
      await tester.pumpAndSettle();

      verifyNever(() => remote.create(any()));
      expect(find.byType(AlertDialog), findsNothing);
      // The form is as it was, to change or send again.
      expect(nameInput(tester).controller.text, 'CI deploy');
      expect(failureBanner(), findsNothing);
    });

    testWidgets('confirming sends confirmCritical true', (tester) async {
      await show(tester);
      await enterName(tester);
      await switchEverything(tester);
      await pressCreate(tester);

      await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
      await tester.pumpAndSettle();

      expect(
        sent(),
        const ApiKeyCreate(
          name: 'CI deploy',
          grant: ApiKeyEverythingGrant(),
          confirmCritical: true,
        ),
      );
      expect(find.byType(SecretPanel), findsOneWidget);
    });

    testWidgets('a picked Critical permission asks too, naming it', (
      tester,
    ) async {
      await show(tester);
      await enterName(tester);
      await tick(tester, readGames.description);
      await tick(tester, manageUsers.description);

      await pressCreate(tester);

      expect(find.text(criticalQuestion), findsOneWidget);
      await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
      await tester.pumpAndSettle();

      final request = sent();
      expect(
        request.grant,
        const ApiKeyScopesGrant([
          ApiKeyScope(slug: 'collection:read'),
          ApiKeyScope(slug: 'users:manage'),
        ]),
      );
      expect(request.confirmCritical, isTrue);
    });

    testWidgets('the preset with no Critical grantable asks nothing', (
      tester,
    ) async {
      answerGrantable(remote, [readGames, changeGames]);
      await show(tester);
      await enterName(tester);
      await switchEverything(tester);

      await pressCreate(tester);

      expect(find.text(criticalQuestion), findsNothing);
      expect(
        sent(),
        const ApiKeyCreate(name: 'CI deploy', grant: ApiKeyEverythingGrant()),
      );
    });

    testWidgets("a screen reader's Create has focus back when the question "
        'closes', (tester) async {
      final semantics = tester.ensureSemantics();
      await show(tester);
      await enterName(tester);
      await switchEverything(tester);
      await tester.ensureVisible(createButton());
      await tester.pumpAndSettle();
      // Typing left focus in the name field.
      expect(createFocus(tester).hasPrimaryFocus, isFalse);

      // A double tap with a screen reader moves no input focus of its own.
      tester.semantics.tap(find.semantics.byLabel('Create key'));
      await tester.pumpAndSettle();
      expect(find.text(criticalQuestion), findsOneWidget);

      await tester.tap(find.byKey(CriticalConfirmDialog.cancelKey));
      await tester.pumpAndSettle();

      expect(createFocus(tester).hasPrimaryFocus, isTrue);
      semantics.dispose();
    });

    group('the server finds one the form did not', () {
      // The form was built before the permission became Critical.
      final wasHigh = permission(
        'users:manage',
        description: 'Manage every user',
        riskLevel: RiskLevel.high,
      );

      /// The grantable read answers [first], then what is true now.
      void permissionsChangeUnderTheForm() {
        var reads = 0;
        when(remote.fetchGrantable).thenAnswer(
          (_) async =>
              reads++ == 0 ? [readGames, wasHigh] : [readGames, manageUsers],
        );
      }

      testWidgets('a server CRITICAL_NEEDS_CONFIRMATION asks, then resubmits '
          'once', (tester) async {
        permissionsChangeUnderTheForm();
        var calls = 0;
        when(() => remote.create(any())).thenAnswer((_) async {
          if (calls++ == 0) throw needsConfirmation;
          return made;
        });
        await show(tester);
        await enterName(tester);
        await tick(tester, 'Manage every user');

        await pressCreate(tester);

        // Nothing here was Critical when the form asked, so it sent
        // unconfirmed; the server's answer brings the question up, naming
        // the permission from the list read again.
        expect(find.text(criticalQuestion), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Manage every user'),
          ),
          findsOneWidget,
        );
        // The dialog says it: no banner sits under it to be read again.
        expect(failureBanner(), findsNothing);
        expect(calls, 1);

        await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
        await tester.pumpAndSettle();

        final requests = verify(
          () => remote.create(captureAny()),
        ).captured.cast<ApiKeyCreate>();
        expect(requests.map((request) => request.confirmCritical), [
          false,
          true,
        ]);
        expect(requests.last.name, 'CI deploy');
        expect(
          requests.last.grant,
          const ApiKeyScopesGrant([ApiKeyScope(slug: 'users:manage')]),
        );
        expect(find.byType(SecretPanel), findsOneWidget);
      });

      testWidgets('a second one is a failure, not another question', (
        tester,
      ) async {
        permissionsChangeUnderTheForm();
        when(() => remote.create(any())).thenThrow(needsConfirmation);
        await show(tester);
        await enterName(tester);
        await tick(tester, 'Manage every user');
        await pressCreate(tester);

        await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsNothing);
        expect(failureBanner(), findsOneWidget);
        expect(
          find.text('A Critical permission needs your confirmation first.'),
          findsOneWidget,
        );
        verify(() => remote.create(any())).called(2);
      });

      testWidgets('cancelling it sends nothing more and leaves no failure', (
        tester,
      ) async {
        permissionsChangeUnderTheForm();
        when(() => remote.create(any())).thenThrow(needsConfirmation);
        final semantics = tester.ensureSemantics();
        await show(tester);
        await enterName(tester);
        await tick(tester, 'Manage every user');
        expect(rowLabel(tester, 'Manage every user'), contains('Risk: High'));
        await pressCreate(tester);

        await tester.tap(find.byKey(CriticalConfirmDialog.cancelKey));
        await tester.pumpAndSettle();

        verify(() => remote.create(any())).called(1);
        expect(failureBanner(), findsNothing);
        expect(find.text('Create key'), findsOneWidget);
        // Its row now says what it is.
        expect(
          rowLabel(tester, 'Manage every user'),
          contains('Risk: Critical'),
        );
        semantics.dispose();
      });

      testWidgets('a permission the user can no longer give is not sent '
          'again', (tester) async {
        var reads = 0;
        when(remote.fetchGrantable).thenAnswer(
          (_) async => reads++ == 0
              ? [readGames, changeGames, wasHigh]
              : [readGames, manageUsers],
        );
        var calls = 0;
        when(() => remote.create(any())).thenAnswer((_) async {
          if (calls++ == 0) throw needsConfirmation;
          return made;
        });
        await show(tester);
        await enterName(tester);
        await tick(tester, changeGames.description);
        await tick(tester, 'Manage every user');
        await pressCreate(tester);

        await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
        await tester.pumpAndSettle();

        final requests = verify(
          () => remote.create(captureAny()),
        ).captured.cast<ApiKeyCreate>();
        // Its row went with the list read again, so its tick went too.
        expect(
          requests.last.grant,
          const ApiKeyScopesGrant([ApiKeyScope(slug: 'users:manage')]),
        );
      });
    });
  });

  group('a refusal', () {
    testWidgets('needs recent sign-in says sign out and in again', (
      tester,
    ) async {
      when(() => remote.create(any())).thenThrow(
        const ApiKeyNeedsRecentSignInException('stale', apiMessage: 'Again.'),
      );
      await show(tester);
      await enterName(tester);
      await tick(tester, manageUsers.description);
      await pressCreate(tester);

      await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
      await tester.pumpAndSettle();

      final banner = failureBanner();
      expect(banner, findsOneWidget);
      expect(
        find.descendant(of: banner, matching: find.text(failedTitle)),
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
      // Text only: signing in again without leaving the form is #1113.
      expect(tester.widget<BgeInlineBanner>(banner).action, isNull);
      // On the button it answers, and the form is as it was.
      expect(
        tester.getTopLeft(banner).dy,
        lessThan(tester.getTopLeft(createButton()).dy),
      );
      expect(nameInput(tester).controller.text, 'CI deploy');
      expect(find.byType(SecretPanel), findsNothing);
    });

    testWidgets('scope not grantable names the permission', (tester) async {
      when(() => remote.create(any())).thenThrow(
        const ApiKeyScopeNotGrantableException('no', slug: 'collection:read'),
      );
      final semantics = tester.ensureSemantics();
      await show(tester);
      await enterName(tester);
      await tick(tester, readGames.description);

      await pressCreate(tester);

      const words =
          "You can't give a key the permission Read your game collection.";
      expect(
        find.descendant(of: failureBanner(), matching: find.text(words)),
        findsOneWidget,
      );
      // On the permission's own row as well, read with it.
      expect(rowLabel(tester, readGames.description), contains(words));
      expect(
        rowLabel(tester, changeGames.description),
        isNot(contains(words)),
      );
      semantics.dispose();
    });

    testWidgets("one the form has no name for is named by the server's code "
        'for it', (tester) async {
      when(() => remote.create(any())).thenThrow(
        const ApiKeyScopeNotPinnableException('no', slug: 'jobs:manage'),
      );
      await show(tester);
      await enterName(tester);

      await pressCreate(tester);

      expect(
        find.text(
          "The permission jobs:manage can't be limited to one record.",
        ),
        findsOneWidget,
      );
    });

    testWidgets("an expiry out of range uses the server's min and max", (
      tester,
    ) async {
      when(() => remote.create(any())).thenThrow(
        const ApiKeyExpiryOutOfRangeException('no', min: 7, max: 60),
      );
      await show(tester);
      await enterName(tester);

      await pressCreate(tester);

      expect(
        find.text('A key can last from 7 days to 60 days.'),
        findsOneWidget,
      );
    });

    testWidgets("one this app has no words for is said in the server's", (
      tester,
    ) async {
      when(() => remote.create(any())).thenThrow(
        const ApiKeyPermanentException('no', apiMessage: 'Not today.'),
      );
      await show(tester);
      await enterName(tester);

      await pressCreate(tester);

      expect(
        find.descendant(of: failureBanner(), matching: find.text('Not today.')),
        findsOneWidget,
      );
    });

    testWidgets('an edit to the name, the permissions or the expiry retires '
        'it', (tester) async {
      when(() => remote.create(any())).thenThrow(transient);
      await show(tester);
      await enterName(tester);

      Future<void> fail() async {
        await pressCreate(tester);
        expect(
          find.descendant(
            of: failureBanner(),
            matching: find.text(unreachable),
          ),
          findsOneWidget,
        );
      }

      await fail();
      await enterName(tester, 'CI deploy 2');
      expect(failureBanner(), findsNothing);

      await fail();
      await tick(tester, readGames.description);
      expect(failureBanner(), findsNothing);

      await fail();
      await tester.ensureVisible(find.text('30 days'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 days'));
      await tester.pumpAndSettle();
      expect(failureBanner(), findsNothing);
    });

    testWidgets('pressing Create again retires it before a question opens '
        'over it', (tester) async {
      when(() => remote.create(any())).thenThrow(transient);
      await show(tester);
      await enterName(tester);
      await tick(tester, manageUsers.description);
      await pressCreate(tester);
      await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
      await tester.pumpAndSettle();
      expect(failureBanner(), findsOneWidget);

      await pressCreate(tester);

      // Left under the dialog's barrier, it would be read again as news
      // when the dialog closes.
      expect(find.text(criticalQuestion), findsOneWidget);
      expect(failureBanner(), findsNothing);
    });
  });

  group('while the key is on its way', () {
    testWidgets('Create keeps focus and says it is creating, the fields are '
        'read-only, and another press sends nothing more', (tester) async {
      final answer = Completer<CreatedApiKey>();
      when(() => remote.create(any())).thenAnswer((_) => answer.future);
      final semantics = tester.ensureSemantics();
      await show(tester);
      await enterName(tester);
      await tick(tester, readGames.description);

      await pressCreateHeld(tester);

      expect(find.text('Creating key…'), findsOneWidget);
      final node = tester.getSemantics(createButton()).getSemanticsData();
      expect(node.label, 'Creating key…');
      // Said as it starts, to a reader who is not on the button.
      expect(node.flagsCollection.isLiveRegion, isTrue);
      expect(createFocus(tester).hasPrimaryFocus, isTrue);
      // Read-only, not disabled: each stays where a reader left it.
      expect(nameInput(tester).readOnly, isTrue);
      expect(
        tester.widget<ScopePicker>(find.byType(ScopePicker)).readOnly,
        isTrue,
      );
      expect(
        tester.widget<ExpiryControl>(find.byType(ExpiryControl)).readOnly,
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpEvent(tester);
      verify(() => remote.create(any())).called(1);

      answer.complete(made);
      await tester.pumpAndSettle();
      expect(find.byType(SecretPanel), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('at rest Create is no live region, so its name coming back '
        'after a failure is not read over the failure', (tester) async {
      when(() => remote.create(any())).thenThrow(transient);
      final semantics = tester.ensureSemantics();
      await show(tester);
      await enterName(tester);

      await pressCreate(tester);

      final node = tester.getSemantics(createButton()).getSemanticsData();
      expect(node.label, 'Create key');
      expect(node.flagsCollection.isLiveRegion, isFalse);
      semantics.dispose();
    });

    testWidgets('a failure leaves focus on Create, to send it again', (
      tester,
    ) async {
      final answer = Completer<CreatedApiKey>();
      when(() => remote.create(any())).thenAnswer((_) => answer.future);
      await show(tester);
      await enterName(tester);

      await pressCreateHeld(tester);
      answer.completeError(transient);
      await tester.pumpAndSettle();

      expect(failureBanner(), findsOneWidget);
      expect(createFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('Back waits for the answer, which would otherwise be lost '
        'with the page', (tester) async {
      final answer = Completer<CreatedApiKey>();
      when(() => remote.create(any())).thenAnswer((_) => answer.future);
      await showPushed(tester);
      await enterName(tester);
      await pressCreateHeld(tester);

      await tester.binding.handlePopRoute();
      await pumpEvent(tester);

      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);

      answer.complete(made);
      await tester.pumpAndSettle();
      expect(find.text(secret), findsOneWidget);
    });

    testWidgets('once it has failed, Back leaves as it did before', (
      tester,
    ) async {
      when(() => remote.create(any())).thenThrow(transient);
      await showPushed(tester);
      await enterName(tester);
      await pressCreate(tester);
      expect(failureBanner(), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(find.text(pageBeneathCopy), findsOneWidget);
    });
  });

  group('offline', () {
    testWidgets('offline, Create is disabled and says why', (tester) async {
      final semantics = tester.ensureSemantics();
      await show(tester, offline: true);
      await enterName(tester);
      await tester.ensureVisible(createButton());
      await tester.pumpAndSettle();

      expect(tester.widget<FilledButton>(createButton()).onPressed, isNull);
      final node = tester.getSemantics(createButton()).getSemanticsData();
      expect(node.label, 'Create key');
      expect(node.hint, onlineOnlyCopy);
      expect(node.flagsCollection.isEnabled, isNot(Tristate.isTrue));
      // Drawn once, under the button.
      expect(find.text(onlineOnlyCopy), findsOneWidget);

      await tester.tap(createButton(), warnIfMissed: false);
      await tester.pumpAndSettle();
      verifyNever(() => remote.create(any()));
      semantics.dispose();
    });

    testWidgets('a connection that comes back enables it where it stands', (
      tester,
    ) async {
      await show(tester, offline: true);
      await enterName(tester);
      final before = tester.element(createButton());

      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();

      expect(tester.widget<FilledButton>(createButton()).onPressed, isNotNull);
      // The same button and the same form, with what was typed.
      expect(tester.element(createButton()), same(before));
      expect(nameInput(tester).controller.text, 'CI deploy');
    });
  });

  group('the secret', () {
    testWidgets('success shows the secret, selectable, with Copy and Done', (
      tester,
    ) async {
      await show(tester);

      await createKey(tester);

      // In place of the form, on the same page.
      expect(nameField(), findsNothing);
      expect(createButton(), findsNothing);
      expect(find.text('Key created'), findsOneWidget);
      expect(find.text('Create an API key'), findsNothing);
      expect(find.text('CI deploy'), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byKey(SecretPanel.secretKey)).data,
        secret,
      );
      expect(find.text('Copy key'), findsOneWidget);
      expect(
        find.text(
          'This is the only time the key is shown. Copy it now and store it '
          'somewhere safe.',
        ),
        findsOneWidget,
      );
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('focus goes to the title as the form, and Create with it, '
        'leaves', (tester) async {
      final answer = Completer<CreatedApiKey>();
      when(() => remote.create(any())).thenAnswer((_) => answer.future);
      await show(tester);
      await enterName(tester);
      await pressCreateHeld(tester);
      expect(createFocus(tester).hasPrimaryFocus, isTrue);

      answer.complete(made);
      await tester.pumpAndSettle();

      expect(focusIsOnTitle('Key created'), isTrue);
    });

    testWidgets('it starts from its top, however far down Create was', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 480));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await show(tester);
      await enterName(tester);
      await tester.ensureVisible(createButton());
      await tester.pumpAndSettle();
      final page = Scrollable.of(tester.element(createButton())).position;
      expect(page.pixels, greaterThan(0));

      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(find.byType(SecretPanel), findsOneWidget);
      expect(page.pixels, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Copy puts the secret on the clipboard and says Key copied', (
      tester,
    ) async {
      final copies = captureClipboardCopies();
      await show(tester);
      await createKey(tester);

      await tester.tap(find.byKey(SecretPanel.copyKey));
      await tester.pumpAndSettle();

      expect(copies, [secret]);
      expect(find.text('Key copied'), findsOneWidget);
      // The page stays, with the key, for the user to leave when ready.
      expect(find.text(secret), findsOneWidget);
    });

    /// Each way a pop is asked for that the page may refuse.
    final ways = <String, Future<void> Function(WidgetTester)>{
      "the page's back arrow": (tester) => tester.pageBack(),
      'System Back': (tester) => tester.binding.handlePopRoute(),
      'a pop the navigator may refuse': (tester) async {
        final navigator = Navigator.of(
          tester.element(find.byType(SecretPanel)),
        );
        await navigator.maybePop();
      },
    };

    for (final MapEntry(key: way, value: goBack) in ways.entries) {
      testWidgets('back from the secret asks before leaving: $way', (
        tester,
      ) async {
        await showPushed(tester);
        await createKey(tester);

        await goBack(tester);
        await tester.pumpAndSettle();

        expect(find.text(leaveQuestion), findsOneWidget);
        expect(find.text("You won't see this key again."), findsOneWidget);
        expect(find.byKey(ApiKeyCreateScreen.leaveStayKey), findsOneWidget);
        expect(find.byKey(ApiKeyCreateScreen.leaveConfirmKey), findsOneWidget);
        // Nothing has left: the key is still on the page beneath.
        expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
        expect(find.text(secret), findsOneWidget);
        expect(find.text(pageBeneathCopy), findsNothing);
      });
    }

    testWidgets('a back swipe has nothing to drag while the secret shows, '
        'or while the key is on its way', (tester) async {
      final answer = Completer<CreatedApiKey>();
      when(() => remote.create(any())).thenAnswer((_) => answer.future);
      await showPushed(tester);
      // What a back swipe, and Android's back preview, ask the route before
      // they start.
      RoutePopDisposition disposition() => ModalRoute.of(
        tester.element(find.byType(BgePage)),
      )!.popDisposition;
      await enterName(tester);
      expect(disposition(), RoutePopDisposition.pop);

      await pressCreateHeld(tester);
      expect(disposition(), RoutePopDisposition.doNotPop);

      answer.complete(made);
      await tester.pumpAndSettle();
      expect(find.text(secret), findsOneWidget);
      expect(disposition(), RoutePopDisposition.doNotPop);
    });

    testWidgets('Stay hands focus back to where it was', (tester) async {
      captureClipboardCopies();
      await showPushed(tester);
      await createKey(tester);
      final copy = Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(SecretPanel.copyKey),
            matching: find.text('Copy key'),
          ),
        ),
      )..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(copy.hasPrimaryFocus, isTrue);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text(leaveQuestion), findsOneWidget);
      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
      await tester.pumpAndSettle();

      expect(copy.hasPrimaryFocus, isTrue);
    });

    testWidgets('Stay keeps the secret', (tester) async {
      await showPushed(tester);
      await createKey(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
      expect(find.text(secret), findsOneWidget);
      expect(find.text(pageBeneathCopy), findsNothing);

      // And Back asks again, as often as it is pressed.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text(leaveQuestion), findsOneWidget);
    });

    testWidgets('a tap outside the question stays, and Back on it closes '
        'only the question', (tester) async {
      await showPushed(tester);
      await createKey(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(secret), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text(leaveQuestion), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(secret), findsOneWidget);
    });

    testWidgets('a second Back while the question is being asked asks only '
        'once', (tester) async {
      await showPushed(tester);
      await createKey(tester);
      final navigator = Navigator.of(tester.element(find.byType(SecretPanel)));

      // Both in one turn, before the question has opened.
      final first = navigator.maybePop();
      final second = navigator.maybePop();
      await tester.pumpAndSettle();
      await Future.wait([first, second]);

      expect(find.text(leaveQuestion), findsOneWidget);
    });

    testWidgets('Leave leaves', (tester) async {
      await showPushed(tester);
      await createKey(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveConfirmKey));
      await tester.pumpAndSettle();

      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(find.text(pageBeneathCopy), findsOneWidget);
      expect(find.text(secret), findsNothing);
    });

    testWidgets('Done leaves without asking', (tester) async {
      await showPushed(tester);
      await createKey(tester);

      await tester.ensureVisible(find.byKey(SecretPanel.doneKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SecretPanel.doneKey));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(find.text(pageBeneathCopy), findsOneWidget);
    });

    testWidgets('once the question has said the key will not be shown '
        'again, the page beneath does not say so again', (tester) async {
      await showPushed(tester);
      await createKey(tester);
      BgeInlineBanner notice() =>
          tester.widget<BgeInlineBanner>(find.byKey(SecretPanel.noticeKey));
      expect(notice().announce, isTrue);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
      await tester.pumpAndSettle();

      // A live region that comes back from under a closed dialog is read
      // again, as news it no longer is.
      expect(notice().announce, isFalse);
    });

    testWidgets('the secret survives a rebuild', (tester) async {
      await show(tester);
      await createKey(tester);
      ApiKeyCreateBloc bloc() => BlocProvider.of<ApiKeyCreateBloc>(
        tester.element(find.byType(SecretPanel)),
      );
      final held = bloc();
      expect(
        BgeWindowClass.of(tester.element(find.byType(SecretPanel))),
        BgeWindowClass.medium,
      );

      // A window dragged wider, then down to a phone's width: another
      // window class each time.
      for (final (size, windowClass) in [
        (const Size(1280, 900), BgeWindowClass.expanded),
        (const Size(360, 640), BgeWindowClass.compact),
      ]) {
        useViewSize(tester, size);
        await tester.pumpAndSettle();

        expect(
          BgeWindowClass.of(tester.element(find.byType(SecretPanel))),
          windowClass,
        );
        expect(find.text(secret), findsOneWidget, reason: '$windowClass');
        expect(bloc(), same(held), reason: '$windowClass');
      }

      // And the page built again by whatever is above it.
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.pumpWidget(screen(offline: true));
      await tester.pumpAndSettle();

      expect(find.text(secret), findsOneWidget);
      expect(bloc(), same(held));
      expect(held.isClosed, isFalse);
      verify(() => remote.create(any())).called(1);
      verify(remote.fetchGrantable).called(1);
    });

    testWidgets('nothing takes it away while the user waits', (tester) async {
      await show(tester);
      await createKey(tester);

      await tester.pump(const Duration(hours: 8));
      await tester.pumpAndSettle();

      expect(find.text(secret), findsOneWidget);
    });

    testWidgets("another server's remote starts a new form, without this "
        "one's secret", (tester) async {
      await show(tester);
      await createKey(tester);
      final other = MockApiKeyRemoteDataSource();
      answerGrantable(other, [readGames]);

      await tester.pumpWidget(
        hostScreen(ApiKeyCreateScreen(remote: other)),
      );
      await tester.pumpAndSettle();

      expect(find.text(secret), findsNothing);
      expect(find.byType(SecretPanel), findsNothing);
      expect(nameField(), findsOneWidget);
      expect(nameInput(tester).controller.text, isEmpty);
      verify(other.fetchGrantable).called(1);
    });

    testWidgets('the page closing closes the bloc that held it', (
      tester,
    ) async {
      await showPushed(tester);
      await createKey(tester);
      final bloc = BlocProvider.of<ApiKeyCreateBloc>(
        tester.element(find.byType(SecretPanel)),
      );

      await tester.ensureVisible(find.byKey(SecretPanel.doneKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SecretPanel.doneKey));
      await tester.pumpAndSettle();

      expect(bloc.isClosed, isTrue);
    });
  });

  // A router takes a route away without popping it, for the browser's Back
  // and for a move to another location, and asks the page's guard first.
  // Here the test is the router: it asks the guard, and takes nothing.
  group("what takes the page's route without a pop", () {
    late ApiKeyCreateLeaveGuard guard;
    late FakeSessionLease lease;

    setUp(() {
      guard = ApiKeyCreateLeaveGuard();
      lease = FakeSessionLease();
    });

    Widget guarded({MockApiKeyRemoteDataSource? of}) => ApiKeyCreateScreen(
      remote: of ?? remote,
      leaveGuard: guard,
      sessionLease: lease,
    );

    Future<void> showGuarded(WidgetTester tester) async {
      await tester.pumpWidget(hostOverPage(guarded()));
      await tester.pumpAndSettle();
    }

    /// Asks the guard as a router does, and notes the answer when it comes.
    ({FutureOr<bool> asked, List<bool> answers}) ask() {
      final answers = <bool>[];
      final asked = guard.mayLeave();
      if (asked is bool) {
        answers.add(asked);
      } else {
        unawaited(asked.then(answers.add));
      }
      return (asked: asked, answers: answers);
    }

    testWidgets('the form, with nothing to lose, lets it go at once and '
        'asks nothing', (tester) async {
      await showGuarded(tester);
      await enterName(tester);

      // At once: a bool, so the router moves on in the same turn.
      expect(guard.mayLeave(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('while the key is on its way the route is held, and nothing '
        'is asked', (tester) async {
      final answer = Completer<CreatedApiKey>();
      when(() => remote.create(any())).thenAnswer((_) => answer.future);
      await showGuarded(tester);
      await enterName(tester);
      await pressCreateHeld(tester);

      expect(guard.mayLeave(), isFalse);
      await pumpEvent(tester);
      expect(find.byType(AlertDialog), findsNothing);

      // Its answer is not lost: the page is there to show it.
      answer.complete(made);
      await tester.pumpAndSettle();
      expect(find.text(secret), findsOneWidget);
    });

    testWidgets('a create that failed holds nothing', (tester) async {
      when(() => remote.create(any())).thenThrow(transient);
      await showGuarded(tester);
      await enterName(tester);
      await pressCreate(tester);
      expect(failureBanner(), findsOneWidget);

      expect(guard.mayLeave(), isTrue);
    });

    testWidgets('while the secret shows it asks, and Stay holds the route', (
      tester,
    ) async {
      await showGuarded(tester);
      await createKey(tester);

      final (:asked, :answers) = ask();
      await tester.pumpAndSettle();

      expect(asked, isA<Future<bool>>());
      expect(find.text(leaveQuestion), findsOneWidget);
      expect(find.text("You won't see this key again."), findsOneWidget);
      expect(answers, isEmpty, reason: 'held until the user answers');

      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
      await tester.pumpAndSettle();

      expect(answers, [false]);
      expect(find.text(secret), findsOneWidget);

      // And asked again the next time, as often as something tries.
      ask();
      await tester.pumpAndSettle();
      expect(find.text(leaveQuestion), findsOneWidget);
    });

    testWidgets('a tap outside the question holds the route, as Stay does', (
      tester,
    ) async {
      await showGuarded(tester);
      await createKey(tester);
      final (asked: _, :answers) = ask();
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(answers, [false]);
      expect(find.text(secret), findsOneWidget);
    });

    testWidgets('Leave lets the route go, and the page leaves the going to '
        'whoever asked', (tester) async {
      await showGuarded(tester);
      await createKey(tester);
      final (asked: _, :answers) = ask();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveConfirmKey));
      await tester.pumpAndSettle();

      expect(answers, [true]);
      // The router takes the route. The page pops nothing of its own, or a
      // move elsewhere would also take the page beneath.
      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);
      expect(find.text(pageBeneathCopy), findsNothing);
    });

    testWidgets('asked again while the question is open, it asks once, and '
        'both hear the one answer', (tester) async {
      await showGuarded(tester);
      await createKey(tester);

      final first = ask();
      await tester.pumpAndSettle();
      final second = ask();
      await tester.pumpAndSettle();

      expect(find.text(leaveQuestion), findsOneWidget);
      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
      await tester.pumpAndSettle();

      expect(first.answers, [false]);
      expect(second.answers, [false]);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a pop the page refused and the route being taken share one '
        'question', (tester) async {
      await showGuarded(tester);
      await createKey(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text(leaveQuestion), findsOneWidget);

      final (asked: _, :answers) = ask();
      await tester.pumpAndSettle();

      expect(find.text(leaveQuestion), findsOneWidget);
      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveConfirmKey));
      await tester.pumpAndSettle();

      expect(answers, [true]);
      expect(find.byType(AlertDialog), findsNothing);
      // The refused pop is carried out.
      expect(find.byType(ApiKeyCreateScreen), findsNothing);
      expect(find.text(pageBeneathCopy), findsOneWidget);
    });

    testWidgets('Done has answered already: what carries its pop out is not '
        'asked', (tester) async {
      await showGuarded(tester);
      await createKey(tester);
      await tester.ensureVisible(find.byKey(SecretPanel.doneKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(SecretPanel.doneKey));
      // The page is on its way out, and still mounted: a router that asks
      // about a pop asks now.
      await tester.pump();
      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);

      expect(guard.mayLeave(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(pageBeneathCopy), findsOneWidget);
    });

    testWidgets('Leave after a refused pop has answered already too', (
      tester,
    ) async {
      await showGuarded(tester);
      await createKey(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveConfirmKey));
      // The question is closing and the page has started its own pop.
      await tester.pump();
      await tester.pump();
      expect(find.byType(ApiKeyCreateScreen), findsOneWidget);

      expect(guard.mayLeave(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text(leaveQuestion), findsNothing);
      expect(find.text(pageBeneathCopy), findsOneWidget);
    });

    testWidgets('once its session has ended the route goes unasked, with '
        'the secret showing or a key on its way', (tester) async {
      await showGuarded(tester);
      await createKey(tester);

      lease.isLive = false;

      expect(guard.mayLeave(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('once its session has ended a create on its way holds '
        'nothing', (tester) async {
      final answer = Completer<CreatedApiKey>();
      when(() => remote.create(any())).thenAnswer((_) => answer.future);
      await showGuarded(tester);
      await enterName(tester);
      await pressCreateHeld(tester);
      expect(guard.mayLeave(), isFalse);

      lease.isLive = false;

      expect(guard.mayLeave(), isTrue);
      answer.complete(made);
      await tester.pumpAndSettle();
    });

    testWidgets('the Critical question being open holds nothing, and stacks '
        'no second question', (tester) async {
      await showGuarded(tester);
      await enterName(tester);
      await switchEverything(tester);
      await pressCreate(tester);
      expect(find.text(criticalQuestion), findsOneWidget);

      // Nothing has been sent, so there is nothing to lose.
      expect(guard.mayLeave(), isTrue);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(leaveQuestion), findsNothing);
    });

    testWidgets('a page that has gone answers no more', (tester) async {
      await showGuarded(tester);
      await createKey(tester);
      expect(guard.mayLeave(), isA<Future<bool>>());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ApiKeyCreateScreen.leaveStayKey));
      await tester.pumpAndSettle();

      // The whole app goes, and the page with it.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      expect(guard.mayLeave(), isTrue);
    });

    testWidgets("another server's page takes the guard over", (tester) async {
      final answer = Completer<CreatedApiKey>();
      final other = MockApiKeyRemoteDataSource();
      answerGrantable(other, [readGames]);
      when(() => other.create(any())).thenAnswer((_) => answer.future);
      await tester.pumpWidget(hostScreen(guarded()));
      await tester.pumpAndSettle();
      await createKey(tester);

      // The new page is mounted in the frame the old one goes in.
      await tester.pumpWidget(hostScreen(guarded(of: other)));
      await tester.pumpAndSettle();

      // The new page's answer: its form has nothing to lose, where the old
      // page's secret would have asked.
      expect(guard.mayLeave(), isTrue);
      await enterName(tester);
      await pressCreateHeld(tester);
      expect(guard.mayLeave(), isFalse);

      answer.complete(made);
      await tester.pumpAndSettle();
    });
  });

  group('small and large', () {
    Future<void> at320x2(WidgetTester tester) async {
      useViewSize(tester, const Size(320, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    testWidgets('320dp at 2.0 lays out the form and a refusal without '
        'overflow', (tester) async {
      await at320x2(tester);
      when(() => remote.create(any())).thenThrow(
        const ApiKeyScopeNotGrantableException('no', slug: 'collection:read'),
      );
      await show(tester);
      await enterName(tester, 'A rather long name of 32 chars!!');
      await tick(tester, readGames.description);

      await pressCreate(tester);

      expect(tester.takeException(), isNull);
      expect(failureBanner(), findsOneWidget);
    });

    testWidgets('320dp at 2.0 lays out Create while it is busy without '
        'overflow', (tester) async {
      await at320x2(tester);
      final answer = Completer<CreatedApiKey>();
      when(() => remote.create(any())).thenAnswer((_) => answer.future);
      await show(tester);
      await enterName(tester);

      await pressCreateHeld(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Creating key…'), findsOneWidget);
      answer.complete(made);
      await tester.pumpAndSettle();
    });

    testWidgets('320dp at 2.0 lays out the secret and the question over it '
        'without overflow', (tester) async {
      await at320x2(tester);
      when(() => remote.create(any())).thenAnswer(
        (_) async => CreatedApiKey(
          apiKey: apiKey('k_new', name: 'A rather long name of 32 chars!!'),
          secret: 'bge_${'a1B2c3D4' * 8}',
        ),
      );
      await showPushed(tester);
      await enterName(tester, 'A rather long name of 32 chars!!');
      await pressCreate(tester);
      expect(tester.takeException(), isNull);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(leaveQuestion), findsOneWidget);
      final leave = find.byKey(ApiKeyCreateScreen.leaveConfirmKey);
      expect(tester.getRect(leave).bottom, lessThanOrEqualTo(800));
      expect(tester.getRect(leave).right, lessThanOrEqualTo(320));
    });
  });

  group('accessibility audit', () {
    // Names the screen for tool/check_a11y_audit.dart: ApiKeyCreateScreen.
    //
    // The form and the secret panel run below the fold at 320dp × 2.0, and
    // a scroll to their end leaves a control cut by the top edge, which the
    // tap-target check fails at its cut size. Each is audited whole instead,
    // in a view tall enough to hold it.
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

    auditScreen(
      'form, as it opens',
      build: screenWith(nothing),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(nameField(), findsOneWidget);
      },
    );

    auditScreen(
      'form, whole, with Everything on and a custom expiry',
      build: screenWith(nothing),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await enterName(tester);
        await switchEverything(tester);
        await tester.tap(find.text('Custom'));
        await tester.pumpAndSettle();
        expect(find.text('Number of days'), findsOneWidget);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'form, with a name and a custom expiry refused',
      build: screenWith(nothing),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await tester.tap(find.text('Custom'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.ancestor(
            of: find.text('Number of days'),
            matching: find.byType(BgeTextField),
          ),
          '0',
        );
        await tester.pumpAndSettle();
        await pressCreate(tester);
        expect(find.text('Enter a name for the key.'), findsOneWidget);
        expect(
          find.text('Enter a whole number of days from 1 to 365.'),
          findsOneWidget,
        );
        expectWholePage(tester);
      },
    );

    auditScreen(
      'failure banner, with the refused permission named on its row',
      build: screenWith(
        () => when(() => remote.create(any())).thenThrow(
          const ApiKeyScopeNotGrantableException('no', slug: 'collection:read'),
        ),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await enterName(tester);
        await tick(tester, readGames.description);
        await pressCreate(tester);
        expect(failureBanner(), findsOneWidget);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'creating',
      build: screenWith(
        () => when(
          () => remote.create(any()),
        ).thenAnswer((_) => Completer<CreatedApiKey>().future),
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await enterName(tester);
        await tick(tester, readGames.description);
        await pressCreateHeld(tester);
        expect(find.text('Creating key…'), findsOneWidget);
      },
    );

    auditScreen(
      'Critical confirmation',
      build: screenWith(nothing),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        await enterName(tester);
        await switchEverything(tester);
        await pressCreate(tester);
        expect(find.text(criticalQuestion), findsOneWidget);
        expectWholePage(tester, within: find.byType(AlertDialog));
      },
    );

    auditScreen(
      'secret panel, as it arrives',
      build: screenWith(nothing),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await createKey(tester);
      },
    );

    auditScreen(
      'secret panel, whole, after a copy',
      build: screenWith(nothing),
      arrange: (tester) async {
        captureClipboardCopies();
        await tester.pumpAndSettle();
        await createKey(tester);
        await whole(tester);
        await tester.tap(find.byKey(SecretPanel.copyKey));
        await tester.pumpAndSettle();
        expect(find.text('Key copied'), findsOneWidget);
      },
    );

    auditScreen(
      'leave question',
      pump: (tester, theme) => tester.pumpWidget(
        hostOverPage(ApiKeyCreateScreen(remote: remote), theme: theme),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await createKey(tester);
        await whole(tester);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text(leaveQuestion), findsOneWidget);
        expectWholePage(tester, within: find.byType(AlertDialog));
      },
    );

    auditScreen(
      'offline',
      build: screenWith(nothing, offline: true),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await whole(tester);
        expect(find.text(onlineOnlyCopy), findsOneWidget);
      },
    );

    auditScreen(
      'permissions failed to load',
      build: screenWith(
        () => when(remote.fetchGrantable).thenThrow(transient),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(ApiKeyCreateScreen.failedKey), findsOneWidget);
      },
    );

    auditScreen(
      'loading',
      build: screenWith(
        () => when(remote.fetchGrantable).thenAnswer(
          (_) => Completer<List<GrantablePermission>>().future,
        ),
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pump();
        expect(find.byKey(ApiKeyCreateScreen.loadingKey), findsOneWidget);
      },
    );
  });
}
