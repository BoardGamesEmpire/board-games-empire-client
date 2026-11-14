import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_admin_household_remote.dart';

const _gone = AdminHouseholdNotFoundException('gone', statusCode: 404);
const _forbidden = AdminHouseholdForbiddenException('no', statusCode: 403);
const _transient = AdminHouseholdTransientException('unreachable');

void main() {
  late FakeAdminHouseholdRemote remote;
  late FakeCallerAccessRepository access;

  setUp(() {
    remote = FakeAdminHouseholdRemote();
    access = FakeCallerAccessRepository(
      FakeCallerAccessRepository.of({ResourceType.household: AccessExtent.all}),
    );
  });

  Widget harness({ThemeData? theme, String id = 'h_1'}) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    home: AdminHouseholdDetailScreen(remote: remote, access: access, id: id),
  );

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
  }

  Finder inAppBar(String text) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(text));

  group('ready', () {
    testWidgets('shows every fact and titles the page with the name', (
      tester,
    ) async {
      remote.onFetchDetail = (_) async => adminDetail();
      await pumpScreen(tester);

      expect(inAppBar("Ada's table"), findsOneWidget);
      expect(find.text('Friday board games'), findsOneWidget);
      expect(find.text("Visible to: Members' friends"), findsOneWidget);
      expect(find.text('Language: English'), findsOneWidget);
      expect(find.text('Created Mar 14, 2026'), findsOneWidget);
      expect(remote.calls, ['fetchDetail(h_1)']);
    });

    testWidgets('sets its facts an intra-control step apart, not the label '
        'to helper step', (tester) async {
      remote.onFetchDetail = (_) async => adminDetail();
      await pumpScreen(tester);

      final lines = [
        'Friday board games',
        "Visible to: Members' friends",
        'Language: English',
        'Created Mar 14, 2026',
      ];
      for (var i = 1; i < lines.length; i++) {
        expect(
          tester.getTopLeft(find.text(lines[i])).dy -
              tester.getBottomLeft(find.text(lines[i - 1])).dy,
          BgeTokens.standard.spaceSm,
          reason: lines[i],
        );
      }
    });

    testWidgets('titles the page Household while it loads', (tester) async {
      final pending = Completer<AdminHouseholdDetail>();
      remote.onFetchDetail = (_) => pending.future;
      await tester.pumpWidget(harness());
      await tester.pump();

      expect(inAppBar('Household'), findsOneWidget);
      expect(find.byKey(AdminHouseholdDetailScreen.loadingKey), findsOneWidget);
      pending.complete(adminDetail());
      await tester.pumpAndSettle();
      expect(inAppBar("Ada's table"), findsOneWidget);
    });

    for (final (reach, label) in [
      (Reach.private, 'Only members'),
      (Reach.friends, "Members' friends"),
      (Reach.friendsOfFriends, 'Friends of friends'),
      (Reach.extendedNetwork, 'Extended network'),
      (Reach.public, 'Everyone on the server'),
    ]) {
      testWidgets('names $reach as "$label"', (tester) async {
        remote.onFetchDetail = (_) async => adminDetail(reach: reach);
        await pumpScreen(tester);
        expect(find.text('Visible to: $label'), findsOneWidget);
      });
    }

    testWidgets('omits the reach, description and language when unknown or '
        'absent', (tester) async {
      remote.onFetchDetail = (_) async => adminDetail(
        reach: Reach.unknown,
        description: null,
        languageName: null,
      );
      await pumpScreen(tester);

      expect(find.textContaining('Visible to'), findsNothing);
      expect(find.textContaining('Language'), findsNothing);
      expect(find.text('Friday board games'), findsNothing);
      expect(find.text('Created Mar 14, 2026'), findsOneWidget);
    });

    testWidgets('lists each member with their role', (tester) async {
      remote.onFetchDetail = (_) async => adminDetail(
        members: [
          adminMember('m1', name: 'Ada', role: HouseholdRole.householdOwner),
          adminMember('m2', name: 'Bea', role: HouseholdRole.householdAdmin),
          adminMember('m3', name: 'Cy', role: HouseholdRole.householdGuest),
          adminMember('m4', role: null),
        ],
      );
      await pumpScreen(tester);

      expect(find.text('4 members'), findsOneWidget);
      for (final (id, name, role) in [
        ('m1', 'Ada', 'Owner'),
        ('m2', 'Bea', 'Admin'),
        ('m3', 'Cy', 'Guest'),
      ]) {
        final row = find.byKey(AdminHouseholdDetailScreen.memberKey(id));
        expect(row, findsOneWidget);
        expect(
          find.descendant(of: row, matching: find.text(name)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.text(role)),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(
          of: find.byKey(AdminHouseholdDetailScreen.memberKey('m4')),
          matching: find.text('Member'),
        ),
        findsWidgets,
      );
    });

    testWidgets('counts the roster rows, not the facts or the heading, for '
        'a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      // Enough rows to scroll: a viewport that fits its content offers no
      // scroll action, and so carries no count.
      remote.onFetchDetail = (_) async => adminDetail(
        members: [
          for (var i = 1; i <= 30; i++) adminMember('m$i', name: 'M$i'),
        ],
      );
      await pumpScreen(tester);

      expect(scrollChildCountOnScrollingNode(tester), 30);
      handle.dispose();
    });

    testWidgets('offers no action', (tester) async {
      remote.onFetchDetail = (_) async => adminDetail();
      await pumpScreen(tester);

      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byType(PopupMenuButton<Object?>), findsNothing);
    });
  });

  group('failures', () {
    testWidgets('gone says so, with no retry', (tester) async {
      remote.onFetchDetail = (_) async => throw _gone;
      await pumpScreen(tester);

      expect(
        find.text('This household was deleted, or no longer exists'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsNothing);
      expect(inAppBar('Household'), findsOneWidget);
    });

    testWidgets('refused says so and asks the access again', (tester) async {
      remote.onFetchDetail = (_) async => throw _forbidden;
      await pumpScreen(tester);

      expect(
        find.text("You don't have access to this household"),
        findsOneWidget,
      );
      expect(access.refreshCount, 1);
    });

    testWidgets('failed says so, and Try again reads again', (tester) async {
      var reads = 0;
      remote.onFetchDetail = (_) async {
        if (reads++ == 0) throw _transient;
        return adminDetail();
      };
      await pumpScreen(tester);

      expect(find.text("Couldn't load this household"), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load this household"), findsNothing);
      expect(find.text('Friday board games'), findsOneWidget);
      expect(reads, 2);
    });

    testWidgets('Try again pressed from the keyboard goes as it reads, and '
        'hands its focus to the heading', (tester) async {
      final retried = Completer<AdminHouseholdDetail>();
      var reads = 0;
      remote.onFetchDetail = (_) async {
        if (reads++ == 0) throw _transient;
        return retried.future;
      };
      await pumpScreen(tester);
      Focus.of(tester.element(find.text('Try again'))).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(find.text('Try again'), findsNothing);
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNot(isA<FocusScopeNode>()));
      expect(
        focused,
        same(
          Focus.of(
            tester.element(inAppBar('Household')),
            createDependency: false,
          ),
        ),
      );

      retried.complete(adminDetail());
      await tester.pumpAndSettle();
      expect(find.text('Friday board games'), findsOneWidget);
      expect(reads, 2);
    });
  });

  group('another household', () {
    testWidgets('a new id reads that household, as a go to its detail from '
        "another's does", (tester) async {
      remote.onFetchDetail = (id) async =>
          id == 'h_1' ? adminDetail() : adminDetail(id: id, name: 'Bea games');
      await pumpScreen(tester);
      expect(inAppBar("Ada's table"), findsOneWidget);

      // The router keeps the page for a go to another id of the same route,
      // and builds the screen again with the new id.
      await tester.pumpWidget(harness(id: 'h_2'));
      await tester.pumpAndSettle();

      expect(inAppBar('Bea games'), findsOneWidget);
      expect(remote.calls, ['fetchDetail(h_1)', 'fetchDetail(h_2)']);
    });

    testWidgets("Try again after a new id reads the new one, not the old's", (
      tester,
    ) async {
      remote.onFetchDetail = (_) async => throw _transient;
      await pumpScreen(tester);
      await tester.pumpWidget(harness(id: 'h_2'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(remote.calls.last, 'fetchDetail(h_2)');
    });
  });

  group('accessibility audit', () {
    Future<void> Function(WidgetTester, ThemeData) screen(
      void Function() seed, {
      bool settle = true,
    }) => (tester, theme) async {
      seed();
      await tester.pumpWidget(harness(theme: theme));
      if (settle) await tester.pumpAndSettle();
    };

    auditScreen(
      'loading',
      pump: screen(
        () =>
            remote.onFetchDetail = (_) =>
                Completer<AdminHouseholdDetail>().future,
        settle: false,
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pump();
        expect(
          find.byKey(AdminHouseholdDetailScreen.loadingKey),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'ready',
      pump: screen(() => remote.onFetchDetail = (_) async => adminDetail()),
      arrange: (tester) async {
        expect(find.text('Friday board games'), findsOneWidget);
      },
    );

    auditScreen(
      'ready, sparse',
      pump: screen(
        () => remote.onFetchDetail = (_) async => adminDetail(
          reach: Reach.unknown,
          description: null,
          languageName: null,
          members: [adminMember('m1', role: null)],
        ),
      ),
      arrange: (tester) async {
        expect(find.text('1 member'), findsOneWidget);
      },
    );

    auditScreen(
      'gone',
      pump: screen(() => remote.onFetchDetail = (_) async => throw _gone),
      arrange: (tester) async {
        expect(find.byKey(AdminHouseholdDetailScreen.goneKey), findsOneWidget);
      },
    );

    auditScreen(
      'refused',
      pump: screen(() => remote.onFetchDetail = (_) async => throw _forbidden),
      arrange: (tester) async {
        expect(
          find.byKey(AdminHouseholdDetailScreen.refusedKey),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'failed, with retry',
      pump: screen(() => remote.onFetchDetail = (_) async => throw _transient),
      arrange: (tester) async {
        expect(find.byKey(AdminHouseholdDetailScreen.errorKey), findsOneWidget);
      },
    );
  });
}
