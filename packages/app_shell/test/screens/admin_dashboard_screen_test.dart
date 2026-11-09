import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/access.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A repository whose asks answer only when the test says so.
///
/// Each [refresh] counts, as the plain fake's does, and stays out until
/// [answerAsk], so a test can see the dashboard while it waits.
class _HeldAccess extends FakeCallerAccessRepository {
  Completer<void> _ask = Completer<void>();

  @override
  Future<void> refresh() {
    unawaited(super.refresh());
    return (_ask = Completer<void>()).future;
  }

  /// Answers the ask that is out, with [answer] kept first when one is
  /// given, as the session's reader keeps it before its ask completes.
  void answerAsk([CallerAccess? answer]) {
    if (answer != null) current = answer;
    _ask.complete();
  }
}

const _gatewaysTitle = 'Data gateways';
const _householdsTitle = 'Households';

/// The sections the composition gives the dashboard, in its order. Titles
/// are literal, so the suite stays clear of the feature ARBs.
List<AdminSection> _sections({List<String>? opened}) => [
  AdminSection(
    id: 'data_gateways',
    icon: Icons.hub_outlined,
    title: _gatewaysTitle,
    summary: 'Where the server finds its games',
    resourceType: ResourceType.dataGateway,
    onOpen: (_) => opened?.add('data_gateways'),
  ),
  AdminSection(
    id: 'households',
    icon: Icons.groups_outlined,
    title: _householdsTitle,
    summary: 'Every household on the server, deleted ones too',
    resourceType: ResourceType.household,
    onOpen: (_) => opened?.add('households'),
  ),
];

/// A known answer reading DataGateways and households as given.
CallerAccess _reads({
  AccessExtent gateways = AccessExtent.none,
  AccessExtent households = AccessExtent.none,
}) => FakeCallerAccessRepository.of({
  ResourceType.dataGateway: gateways,
  ResourceType.household: households,
});

Widget _app({
  required CallerAccessRepository? access,
  List<AdminSection>? sections,
  void Function(BuildContext context)? onGoHome,
  ThemeData? theme,
}) => MaterialApp(
  theme: theme ?? BgeTheme.light(),
  localizationsDelegates: ShellLocalizations.localizationsDelegates,
  supportedLocales: ShellLocalizations.supportedLocales,
  home: AdminDashboardScreen(
    sections: sections ?? _sections(),
    access: access,
    onGoHome: onGoHome ?? (_) {},
  ),
);

void main() {
  group('visibleAdminSections (#684)', () {
    final gateways = _sections()[0];
    final households = _sections()[1];
    final moreHouseholds = AdminSection(
      id: 'more_households',
      icon: Icons.groups_outlined,
      title: 'More households',
      summary: 'A second section on the same type',
      resourceType: ResourceType.household,
      onOpen: (_) {},
    );

    test('keeps the sections whose read is all, in the order given, and '
        'drops one whose read is some', () {
      final shown = visibleAdminSections(
        _reads(gateways: AccessExtent.some, households: AccessExtent.all),
        [households, gateways, moreHouseholds],
      );

      expect(shown, [households, moreHouseholds]);
    });

    test('drops a section whose read is none', () {
      final shown = visibleAdminSections(_reads(gateways: AccessExtent.all), [
        gateways,
        households,
      ]);

      expect(shown, [gateways]);
    });

    test('drops a section whose type the answer leaves out', () {
      final shown = visibleAdminSections(
        FakeCallerAccessRepository.of({
          ResourceType.household: AccessExtent.all,
        }),
        [gateways, households],
      );

      expect(shown, [households]);
    });

    test('shows none while the answer is unknown', () {
      expect(
        visibleAdminSections(const CallerAccess.unknown(), [
          gateways,
          households,
        ]),
        isEmpty,
      );
    });
  });

  group('AdminDashboardScreen (#684)', () {
    group('while access is unknown', () {
      testWidgets('shows loading, and asks the access again once', (
        tester,
      ) async {
        final access = _HeldAccess();
        await tester.pumpWidget(_app(access: access));
        await tester.pump();

        expect(find.byKey(AdminDashboardScreen.loadingKey), findsOneWidget);
        expect(find.bySemanticsLabel('Checking your access…'), findsOneWidget);
        expect(access.refreshCount, 1);

        await tester.pump(const Duration(seconds: 1));
        expect(access.refreshCount, 1);
      });

      testWidgets('an answer that lands while it asks shows the sections', (
        tester,
      ) async {
        final access = _HeldAccess();
        await tester.pumpWidget(_app(access: access));
        await tester.pump();

        access.answerAsk(_reads(gateways: AccessExtent.all));
        await tester.pumpAndSettle();

        expect(find.byKey(AdminDashboardScreen.loadingKey), findsNothing);
        expect(
          find.byKey(AdminDashboardScreen.entryKey('data_gateways')),
          findsOneWidget,
        );
      });

      testWidgets('still unknown after the ask, it says it could not check, '
          'and Retry shows loading and asks again', (tester) async {
        final access = _HeldAccess();
        await tester.pumpWidget(_app(access: access));
        await tester.pump();

        access.answerAsk();
        await tester.pumpAndSettle();

        expect(find.byKey(AdminDashboardScreen.failedKey), findsOneWidget);
        expect(find.text("Couldn't check your access"), findsOneWidget);
        expect(access.refreshCount, 1);

        await tester.tap(find.text('Try again'));
        await tester.pump();

        expect(find.byKey(AdminDashboardScreen.loadingKey), findsOneWidget);
        expect(find.byKey(AdminDashboardScreen.failedKey), findsNothing);
        expect(access.refreshCount, 2);

        access.answerAsk();
        await tester.pumpAndSettle();

        expect(find.byKey(AdminDashboardScreen.failedKey), findsOneWidget);
      });

      testWidgets('Try again goes as it asks again, and hands its focus to '
          'the heading', (tester) async {
        final access = _HeldAccess();
        await tester.pumpWidget(_app(access: access));
        await tester.pump();
        access.answerAsk();
        await tester.pumpAndSettle();

        Focus.of(tester.element(find.text('Try again'))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();

        expect(find.byKey(AdminDashboardScreen.loadingKey), findsOneWidget);
        final focused = FocusManager.instance.primaryFocus;
        expect(focused, isNot(isA<FocusScopeNode>()));
        expect(
          focused,
          same(
            Focus.of(
              tester.element(find.text('Admin')),
              createDependency: false,
            ),
          ),
        );
      });

      testWidgets('an ask that finds the answer after a Retry shows the '
          'sections', (tester) async {
        final access = FakeCallerAccessRepository();
        await tester.pumpWidget(_app(access: access));
        await tester.pumpAndSettle();
        expect(find.byKey(AdminDashboardScreen.failedKey), findsOneWidget);

        // The plain fake's ask answers at once, with whatever it holds.
        access.current = _reads(households: AccessExtent.all);
        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();

        expect(access.refreshCount, 2);
        expect(
          find.byKey(AdminDashboardScreen.entryKey('households')),
          findsOneWidget,
        );
      });
    });

    group('once access is known', () {
      testWidgets('with no section to show, it is refused, and Go home calls '
          'back', (tester) async {
        var homes = 0;
        final access = FakeCallerAccessRepository(
          _reads(gateways: AccessExtent.some),
        );
        await tester.pumpWidget(_app(access: access, onGoHome: (_) => homes++));
        await tester.pumpAndSettle();

        expect(find.byKey(AdminDashboardScreen.refusedKey), findsOneWidget);
        expect(
          find.text(
            "You don't have access to any admin sections on this server",
          ),
          findsOneWidget,
        );
        // A known answer needs no asking.
        expect(access.refreshCount, 0);

        await tester.tap(find.text('Go home'));
        await tester.pump();

        expect(homes, 1);
      });

      testWidgets('with no access to ask, it is refused', (tester) async {
        await tester.pumpWidget(_app(access: null));
        await tester.pumpAndSettle();

        expect(find.byKey(AdminDashboardScreen.refusedKey), findsOneWidget);
      });

      testWidgets('lists each section it shows, with its title and summary, '
          'and tells a screen reader how many', (tester) async {
        await tester.pumpWidget(
          _app(
            access: FakeCallerAccessRepository(
              _reads(gateways: AccessExtent.all, households: AccessExtent.all),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(AdminDashboardScreen.entryKey('data_gateways')),
          findsOneWidget,
        );
        expect(
          find.byKey(AdminDashboardScreen.entryKey('households')),
          findsOneWidget,
        );
        expect(find.text('Where the server finds its games'), findsOneWidget);
        expect(
          find.text('Every household on the server, deleted ones too'),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.hub_outlined), findsOneWidget);
        expect(find.byIcon(Icons.groups_outlined), findsOneWidget);
        expect(
          tester
              .widget<CustomScrollView>(find.byType(CustomScrollView))
              .semanticChildCount,
          2,
        );
        // In the order the composition gave.
        expect(
          tester.getTopLeft(find.text(_gatewaysTitle)).dy,
          lessThan(tester.getTopLeft(find.text(_householdsTitle)).dy),
        );
      });

      testWidgets('leaves out a section whose read is not all', (tester) async {
        await tester.pumpWidget(
          _app(
            access: FakeCallerAccessRepository(
              _reads(gateways: AccessExtent.some, households: AccessExtent.all),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text(_gatewaysTitle), findsNothing);
        expect(find.text(_householdsTitle), findsOneWidget);
        expect(
          tester
              .widget<CustomScrollView>(find.byType(CustomScrollView))
              .semanticChildCount,
          1,
        );
      });

      testWidgets('an entry opens its section', (tester) async {
        final opened = <String>[];
        await tester.pumpWidget(
          _app(
            access: FakeCallerAccessRepository(
              _reads(gateways: AccessExtent.all, households: AccessExtent.all),
            ),
            sections: _sections(opened: opened),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text(_householdsTitle));
        await tester.pump();

        expect(opened, ['households']);
      });

      testWidgets('follows the access: a section comes with its read, and '
          'the last to go leaves the refused state', (tester) async {
        final access = FakeCallerAccessRepository(
          _reads(gateways: AccessExtent.all),
        );
        await tester.pumpWidget(_app(access: access));
        await tester.pumpAndSettle();
        expect(find.text(_householdsTitle), findsNothing);

        access.current = _reads(
          gateways: AccessExtent.all,
          households: AccessExtent.all,
        );
        await tester.pumpAndSettle();
        expect(find.text(_householdsTitle), findsOneWidget);

        access.current = _reads();
        await tester.pumpAndSettle();
        expect(find.byKey(AdminDashboardScreen.refusedKey), findsOneWidget);
        expect(access.refreshCount, 0);
      });
    });

    group('keeping keyboard focus when access takes an entry away', () {
      /// Puts keyboard focus on the entry titled [title], as a Tab would.
      void focusOn(WidgetTester tester, String title) =>
          Focus.of(tester.element(find.text(title))).requestFocus();

      /// Expects keyboard focus on the nearest node above the text [label]:
      /// an entry by its title, or the heading. Not on the page's scope,
      /// where focus falls when the control that had it goes.
      void expectFocusOn(WidgetTester tester, String label) {
        final focused = FocusManager.instance.primaryFocus;
        expect(focused, isNot(isA<FocusScopeNode>()));
        expect(
          focused,
          same(
            Focus.of(tester.element(find.text(label)), createDependency: false),
          ),
        );
      }

      late FakeCallerAccessRepository access;

      Future<void> pumpBoth(WidgetTester tester) async {
        access = FakeCallerAccessRepository(
          _reads(gateways: AccessExtent.all, households: AccessExtent.all),
        );
        await tester.pumpWidget(_app(access: access));
        await tester.pumpAndSettle();
      }

      testWidgets('an entry that leaves with focus hands it to the next '
          'entry', (tester) async {
        await pumpBoth(tester);
        focusOn(tester, _gatewaysTitle);
        await tester.pump();
        expectFocusOn(tester, _gatewaysTitle);

        access.current = _reads(
          gateways: AccessExtent.some,
          households: AccessExtent.all,
        );
        await tester.pumpAndSettle();

        expect(find.text(_gatewaysTitle), findsNothing);
        expectFocusOn(tester, _householdsTitle);
      });

      testWidgets('the last entry leaving with focus hands it to the one '
          'before it', (tester) async {
        await pumpBoth(tester);
        focusOn(tester, _householdsTitle);
        await tester.pump();

        access.current = _reads(
          gateways: AccessExtent.all,
          households: AccessExtent.some,
        );
        await tester.pumpAndSettle();

        expect(find.text(_householdsTitle), findsNothing);
        expectFocusOn(tester, _gatewaysTitle);
      });

      testWidgets('the only entry leaving with focus leaves the refused '
          'state, with focus on the heading', (tester) async {
        access = FakeCallerAccessRepository(
          _reads(households: AccessExtent.all),
        );
        await tester.pumpWidget(_app(access: access));
        await tester.pumpAndSettle();
        focusOn(tester, _householdsTitle);
        await tester.pump();

        access.current = _reads(households: AccessExtent.some);
        await tester.pumpAndSettle();

        expect(find.byKey(AdminDashboardScreen.refusedKey), findsOneWidget);
        expectFocusOn(tester, 'Admin');
      });

      testWidgets('focus on an entry that stays is left where it is', (
        tester,
      ) async {
        await pumpBoth(tester);
        focusOn(tester, _householdsTitle);
        await tester.pump();

        access.current = _reads(households: AccessExtent.all);
        await tester.pumpAndSettle();

        expect(find.text(_gatewaysTitle), findsNothing);
        expectFocusOn(tester, _householdsTitle);
      });

      testWidgets('an entry whose read falls and comes back before the next '
          'frame keeps its focus', (tester) async {
        await pumpBoth(tester);
        final both = access.current;
        focusOn(tester, _gatewaysTitle);
        await tester.pump();

        // Each answer reaches the screen, but no frame is drawn between them.
        access.current = _reads(households: AccessExtent.all);
        await tester.binding.delayed(Duration.zero);
        access.current = both;
        await tester.binding.delayed(Duration.zero);
        await tester.pumpAndSettle();

        expectFocusOn(tester, _gatewaysTitle);
      });

      testWidgets('focus the user moves before the entry goes stays where '
          'they put it', (tester) async {
        await pumpBoth(tester);
        focusOn(tester, _gatewaysTitle);
        await tester.pump();

        // The answer reaches the screen, and the user moves on before the
        // frame that takes the entry away.
        access.current = _reads(households: AccessExtent.all);
        await tester.binding.delayed(Duration.zero);
        focusOn(tester, _householdsTitle);
        await tester.binding.delayed(Duration.zero);
        await tester.pumpAndSettle();

        expectFocusOn(tester, _householdsTitle);
      });

      testWidgets('the heading is not a Tab stop', (tester) async {
        await pumpBoth(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();

        expectFocusOn(tester, _gatewaysTitle);
      });

      group('while a section covers the dashboard', () {
        const moreTitle = 'More households';

        /// The sections, and a third on households, each opening a page of
        /// its own over the dashboard, as the app's do.
        List<AdminSection> pushing() => [
          for (final section in [
            ..._sections(),
            AdminSection(
              id: 'more_households',
              icon: Icons.groups_outlined,
              title: moreTitle,
              summary: 'A second section on the same type',
              resourceType: ResourceType.household,
              onOpen: (_) {},
            ),
          ])
            AdminSection(
              id: section.id,
              icon: section.icon,
              title: section.title,
              summary: section.summary,
              resourceType: section.resourceType,
              onOpen: (context) => unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: Text('${section.title} section')),
                    ),
                  ),
                ),
              ),
            ),
        ];

        Future<void> pumpWith(WidgetTester tester, CallerAccess answer) async {
          access = FakeCallerAccessRepository(answer);
          await tester.pumpWidget(_app(access: access, sections: pushing()));
          await tester.pumpAndSettle();
        }

        /// Opens the entry titled [title] from the keyboard, so the page
        /// gives focus back to it on return.
        Future<void> openByKeyboard(WidgetTester tester, String title) async {
          focusOn(tester, title);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(find.text('$title section'), findsOneWidget);
        }

        void popSection(WidgetTester tester) =>
            tester.state<NavigatorState>(find.byType(Navigator)).pop();

        testWidgets('the entry opened leaves: back on the dashboard, focus '
            'is on the next entry', (tester) async {
          await pumpWith(
            tester,
            _reads(gateways: AccessExtent.all, households: AccessExtent.all),
          );
          await openByKeyboard(tester, _gatewaysTitle);

          // The section is refused, asks the access again, and the answer
          // takes its entry away underneath.
          access.current = _reads(households: AccessExtent.all);
          await tester.pumpAndSettle();
          popSection(tester);
          await tester.pumpAndSettle();

          expect(find.text(_gatewaysTitle), findsNothing);
          expectFocusOn(tester, _householdsTitle);
        });

        testWidgets('the entry opened leaves after the page had other focus: '
            'focus is on the next entry, not the one focused before', (
          tester,
        ) async {
          await pumpWith(
            tester,
            _reads(gateways: AccessExtent.all, households: AccessExtent.all),
          );
          // The pop gives focus back to the page's last focus still there.
          focusOn(tester, moreTitle);
          await tester.pump();
          await openByKeyboard(tester, _gatewaysTitle);

          access.current = _reads(households: AccessExtent.all);
          await tester.pumpAndSettle();
          popSection(tester);
          await tester.pumpAndSettle();

          expectFocusOn(tester, _householdsTitle);
        });

        testWidgets('the entry opened leaves, then the one focused before it, '
            'and the one opened comes back: focus is on the one opened', (
          tester,
        ) async {
          await pumpWith(
            tester,
            _reads(gateways: AccessExtent.all, households: AccessExtent.all),
          );
          focusOn(tester, _gatewaysTitle);
          await tester.pump();
          await openByKeyboard(tester, _householdsTitle);

          access.current = _reads(gateways: AccessExtent.all);
          await tester.pumpAndSettle();
          access.current = _reads();
          await tester.pumpAndSettle();
          access.current = _reads(households: AccessExtent.all);
          await tester.pumpAndSettle();
          popSection(tester);
          await tester.pumpAndSettle();

          expectFocusOn(tester, _householdsTitle);
        });

        testWidgets('the last entry opened leaves: focus is on the one '
            'before it', (tester) async {
          await pumpWith(
            tester,
            _reads(gateways: AccessExtent.all, households: AccessExtent.all),
          );
          await openByKeyboard(tester, moreTitle);

          access.current = _reads(gateways: AccessExtent.all);
          await tester.pumpAndSettle();
          popSection(tester);
          await tester.pumpAndSettle();

          expect(find.text(moreTitle), findsNothing);
          expectFocusOn(tester, _gatewaysTitle);
        });

        testWidgets('the only entry opened leaves: the refused state, with '
            'focus on the heading', (tester) async {
          await pumpWith(tester, _reads(gateways: AccessExtent.all));
          await openByKeyboard(tester, _gatewaysTitle);

          access.current = _reads();
          await tester.pumpAndSettle();
          popSection(tester);
          await tester.pumpAndSettle();

          expect(find.byKey(AdminDashboardScreen.refusedKey), findsOneWidget);
          expectFocusOn(tester, 'Admin');
        });

        testWidgets('another entry leaving gives focus back to the one '
            'opened', (tester) async {
          await pumpWith(
            tester,
            _reads(gateways: AccessExtent.all, households: AccessExtent.all),
          );
          await openByKeyboard(tester, _householdsTitle);

          access.current = _reads(households: AccessExtent.all);
          await tester.pumpAndSettle();
          popSection(tester);
          await tester.pumpAndSettle();

          expect(find.text(_gatewaysTitle), findsNothing);
          expectFocusOn(tester, _householdsTitle);
        });

        testWidgets('focus the user moves on the way back stays where they '
            'put it', (tester) async {
          await pumpWith(
            tester,
            _reads(gateways: AccessExtent.all, households: AccessExtent.all),
          );
          await openByKeyboard(tester, _gatewaysTitle);

          access.current = _reads(households: AccessExtent.all);
          await tester.pumpAndSettle();
          popSection(tester);
          // The section is still on its way out.
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          focusOn(tester, moreTitle);
          await tester.pumpAndSettle();

          expectFocusOn(tester, moreTitle);
        });
      });
    });
  });

  group('accessibility audit', () {
    // AdminDashboardScreen, in each state it can show.
    auditScreen(
      'sections',
      build: (theme) => _app(
        access: FakeCallerAccessRepository(
          _reads(gateways: AccessExtent.all, households: AccessExtent.all),
        ),
        theme: theme,
      ),
    );

    auditScreen(
      'loading',
      build: (theme) => _app(access: _HeldAccess(), theme: theme),
      settle: false,
    );

    // The plain fake's ask answers at once and leaves the answer unknown.
    auditScreen(
      'failed',
      build: (theme) =>
          _app(access: FakeCallerAccessRepository(), theme: theme),
    );

    auditScreen(
      'refused',
      build: (theme) =>
          _app(access: FakeCallerAccessRepository(_reads()), theme: theme),
    );
  });
}
