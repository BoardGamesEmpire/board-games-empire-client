import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:profile/profile.dart';
import 'package:profile/src/form/profile_controls.dart';
import 'package:profile/src/form/profile_form.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'support/fake_user_profile_remote.dart';
import 'support/harness.dart';

const _title = 'Your profile';

Widget _app(Widget home, {ThemeData? theme, bool offline = false}) =>
    MaterialApp(
      theme: theme ?? BgeTheme.light(),
      localizationsDelegates: ProfileLocalizations.localizationsDelegates,
      supportedLocales: ProfileLocalizations.supportedLocales,
      builder: (context, child) => BgeConnectivityScope(
        offline: offline,
        noticeShowing: offline,
        onlineOnlyReason: onlineOnlyCopy,
        child: child!,
      ),
      home: home,
    );

void main() {
  late FakeUserProfileRemote remote;

  setUp(() => remote = FakeUserProfileRemote());

  Widget screen() => ProfileScreen(remote: remote);

  /// Pumps the screen and answers its read with [profile].
  Future<void> pumpScreen(
    WidgetTester tester, {
    UserProfile? profile,
    ThemeData? theme,
    bool offline = false,
  }) async {
    await tester.pumpWidget(_app(screen(), theme: theme, offline: offline));
    await tester.pump();
    remote.fetches.single.complete(profile ?? profileFixture());
    await tester.pumpAndSettle();
  }

  bool focusIsOn(WidgetTester tester, Finder finder) => tester
      .widget<Focus>(
        find.ancestor(of: finder, matching: find.byType(Focus)).first,
      )
      .focusNode!
      .hasPrimaryFocus;

  group('loading', () {
    testWidgets('shows loading, then the form', (tester) async {
      await tester.pumpWidget(_app(screen()));
      await tester.pump();

      expect(find.text(_title), findsOneWidget);
      expect(find.byKey(ProfileScreen.loadingKey), findsOneWidget);
      expect(find.byType(ProfileForm), findsNothing);

      remote.fetches.single.complete(profileFixture());
      await tester.pumpAndSettle();

      expect(find.byKey(ProfileScreen.loadingKey), findsNothing);
      expect(find.byType(ProfileForm), findsOneWidget);
    });

    testWidgets('a failed load shows the error with Try again, which reads '
        'again and keeps focus on the title', (tester) async {
      await tester.pumpWidget(_app(screen()));
      await tester.pump();
      remote.fetches.single.completeError(
        const UserProfileTransientException('down', statusCode: 503),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ProfileScreen.errorKey), findsOneWidget);
      expect(find.text("Couldn't load your profile."), findsOneWidget);
      expect(find.byType(ProfileForm), findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();

      expect(remote.fetches, hasLength(2));
      expect(find.byKey(ProfileScreen.loadingKey), findsOneWidget);
      expect(focusIsOn(tester, find.text(_title)), isTrue);

      remote.fetches.last.complete(profileFixture());
      await tester.pumpAndSettle();

      expect(find.byType(ProfileForm), findsOneWidget);
      expect(focusIsOn(tester, find.text(_title)), isTrue);
    });

    testWidgets('not ready is an empty state, not a failure, with Try '
        'again, which reads again and keeps focus on the title', (
      tester,
    ) async {
      await tester.pumpWidget(_app(screen()));
      await tester.pump();
      remote.fetches.single.completeError(
        const UserProfileNotFoundException('none', statusCode: 404),
      );
      await tester.pumpAndSettle();

      final notReady = find.byKey(ProfileScreen.notReadyKey);
      expect(tester.widget(notReady), isA<BgeEmptyState>());
      expect(find.byType(BgeErrorState), findsNothing);
      expect(find.byKey(ProfileScreen.errorKey), findsNothing);
      expect(
        find.descendant(
          of: notReady,
          matching: find.text('Your profile is not ready yet.'),
        ),
        findsOneWidget,
      );
      final retry = find.descendant(
        of: notReady,
        matching: find.widgetWithText(FilledButton, 'Try again'),
      );
      expect(retry, findsOneWidget);

      await tester.tap(retry);
      await tester.pump();
      await tester.pump();
      expect(remote.fetches, hasLength(2));
      expect(find.byKey(ProfileScreen.loadingKey), findsOneWidget);
      expect(focusIsOn(tester, find.text(_title)), isTrue);
    });

    testWidgets('a save the server answers with no profile shows not ready, '
        'not a failed save, and hands focus from the form to the title', (
      tester,
    ) async {
      await pumpScreen(tester);

      final location = ProfileForm.fieldKey(ProfileControls.location);
      await tester.ensureVisible(find.byKey(location));
      await tester.enterText(find.byKey(location), 'York');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(ProfileForm.saveKey));
      await tester.pumpAndSettle();
      final save = Focus.of(tester.element(find.text('Save profile')))
        ..requestFocus();
      await tester.pump();
      expect(save.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(remote.updateCalls, hasLength(1));
      remote.updates.single.completeError(
        const UserProfileNotFoundException('gone', statusCode: 404),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ProfileScreen.notReadyKey), findsOneWidget);
      expect(find.byKey(ProfileForm.failureKey), findsNothing);
      expect(find.byType(ProfileForm), findsNothing);
      expect(focusIsOn(tester, find.text(_title)), isTrue);
    });

    testWidgets('a save stored but answered unreadably offers to read again, '
        'not to save again, and hands focus from the form to the title', (
      tester,
    ) async {
      await pumpScreen(tester);

      final location = ProfileForm.fieldKey(ProfileControls.location);
      await tester.ensureVisible(find.byKey(location));
      await tester.enterText(find.byKey(location), 'York');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(ProfileForm.saveKey));
      await tester.pumpAndSettle();
      final save = Focus.of(tester.element(find.text('Save profile')))
        ..requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      remote.updates.single.completeError(
        const UserProfilePermanentException('no profile', statusCode: 200),
      );
      await tester.pumpAndSettle();

      expect(save.hasFocus, isFalse);
      expect(find.byKey(ProfileScreen.errorKey), findsOneWidget);
      expect(find.byKey(ProfileForm.failureKey), findsNothing);
      expect(find.byType(ProfileForm), findsNothing);
      expect(focusIsOn(tester, find.text(_title)), isTrue);
    });
  });

  group('header', () {
    testWidgets('shows the avatar, the name and the username', (tester) async {
      await pumpScreen(tester, profile: profileFixture(displayName: 'Ada L'));

      expect(
        find.descendant(of: find.byType(Row), matching: find.text('Ada L')),
        findsOneWidget,
      );
      expect(find.text('@ada'), findsOneWidget);
      final avatar = tester.widget<BgeAvatar>(find.byType(BgeAvatar));
      expect(avatar.initials, 'AL');
      expect(avatar.size, 64);
      expect(avatar.imageUrl, isNull);
    });

    testWidgets('names the user by username, once, without a display name', (
      tester,
    ) async {
      await pumpScreen(tester, profile: profileFixture(displayName: null));

      expect(find.text('ada'), findsOneWidget);
      // Not said twice.
      expect(find.text('@ada'), findsNothing);
    });

    testWidgets('an avatar with a URL builds the image', (tester) async {
      await tester.pumpWidget(_app(screen()));
      await tester.pump();
      final base = profileFixture();
      remote.fetches.single.complete(
        base.copyWith(avatarUrl: 'https://example.com/ada.png'),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(BgeAvatar.imageKey), findsOneWidget);
    });

    testWidgets('the avatar is read-only, with no tap target', (tester) async {
      await pumpScreen(tester);

      expect(
        find.ancestor(
          of: find.byType(BgeAvatar),
          matching: find.byWidgetPredicate(
            (w) => w is InkWell || w is GestureDetector || w is IconButton,
          ),
        ),
        findsNothing,
      );
    });

    testWidgets('a long name fits at 320dp and 200% text', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpScreen(
        tester,
        profile: profileFixture(
          displayName: 'Maximilian Bartholomew Featherstonehaugh-Cholmondeley',
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });

  group('titles', () {
    testWidgets('the title and the form headings are announced as headers', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(tester);

      for (final heading in [
        _title,
        'About you',
        'Playing',
        'Practical details',
        'Who can see your profile',
        'Search',
      ]) {
        expect(
          tester.getSemantics(find.text(heading)),
          isSemantics(isHeader: true, label: heading),
          reason: heading,
        );
      }
      handle.dispose();
    });
  });

  group('saving', () {
    testWidgets("after a save the form shows the server's values", (
      tester,
    ) async {
      await pumpScreen(tester, profile: profileFixture(bio: 'old'));

      final bio = ProfileForm.fieldKey(ProfileControls.bio);
      await tester.ensureVisible(find.byKey(bio));
      await tester.enterText(find.byKey(bio), '<b>Hello</b> there, world');
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(ProfileForm.saveKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ProfileForm.saveKey));
      await tester.pump();
      await tester.pump();
      expect(remote.updateCalls, hasLength(1));

      remote.updates.single.complete(
        profileFixture(bio: 'Hello'),
      );
      await tester.pumpAndSettle();

      final text = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(bio),
          matching: find.byType(EditableText),
        ),
      );
      expect(text.controller.text, 'Hello');
      expect(find.byKey(ProfileForm.savedKey), findsOneWidget);
      final save = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(ProfileForm.saveKey),
          matching: find.byType(FilledButton),
        ),
      );
      expect(save.onPressed, isNull);
    });
  });

  group('accessibility audit', () {
    Future<void> Function(WidgetTester, ThemeData) loaded({
      bool offline = false,
    }) =>
        (tester, theme) => pumpScreen(tester, theme: theme, offline: offline);

    // The form runs several screens tall, so it is audited at the top, as a
    // user first sees it, and in a view tall enough for the whole page.
    Future<void> wholePage(WidgetTester tester) async {
      await useWholePage(tester);
      expect(find.byType(ProfileForm), findsOneWidget);
      expectWholePage(tester);
    }

    auditScreen(
      'loaded',
      pump: loaded(),
      arrange: (tester) async {
        expect(find.byType(ProfileForm), findsOneWidget);
      },
    );

    // Save is on screen, disabled until something changes and dimmed by
    // design: WCAG 1.4.3 exempts inactive controls. Online, its
    // `BgeOnlineOnly` merge has no disabled state of its own, which is what
    // the guideline reads, so it measures the label. The page's other text,
    // and Save enabled, are measured in 'edited, whole page'.
    auditScreen(
      'loaded, whole page',
      pump: loaded(),
      arrange: wholePage,
      textContrast: false,
    );

    auditScreen(
      'edited, whole page',
      pump: loaded(),
      arrange: (tester) async {
        await wholePage(tester);
        await tester.enterText(
          find.byKey(ProfileForm.fieldKey(ProfileControls.location)),
          'York',
        );
        await tester.pumpAndSettle();
        final save = tester.widget<FilledButton>(
          find.descendant(
            of: find.byKey(ProfileForm.saveKey),
            matching: find.byType(FilledButton),
          ),
        );
        expect(save.onPressed, isNotNull);
        expectWholePage(tester);
      },
    );

    // Offline: every field read-only, and Save disabled with its reason
    // under it.
    auditScreen(
      'offline, whole page',
      pump: loaded(offline: true),
      arrange: (tester) async {
        await wholePage(tester);
        expect(find.text(onlineOnlyCopy), findsOneWidget);
      },
    );

    auditScreen(
      'loading',
      pump: (tester, theme) async {
        await tester.pumpWidget(_app(screen(), theme: theme));
      },
      settle: false,
      arrange: (tester) async {
        await tester.pump();
        expect(find.byKey(ProfileScreen.loadingKey), findsOneWidget);
      },
    );

    auditScreen(
      'failed to load',
      pump: (tester, theme) async {
        await tester.pumpWidget(_app(screen(), theme: theme));
        await tester.pump();
        remote.fetches.single.completeError(
          const UserProfileTransientException('down'),
        );
        await tester.pumpAndSettle();
      },
      arrange: (tester) async {
        expect(find.byKey(ProfileScreen.errorKey), findsOneWidget);
      },
    );

    auditScreen(
      'not ready',
      pump: (tester, theme) async {
        await tester.pumpWidget(_app(screen(), theme: theme));
        await tester.pump();
        remote.fetches.single.completeError(
          const UserProfileNotFoundException('none', statusCode: 404),
        );
        await tester.pumpAndSettle();
      },
      arrange: (tester) async {
        expect(find.byKey(ProfileScreen.notReadyKey), findsOneWidget);
      },
    );
  });
}
