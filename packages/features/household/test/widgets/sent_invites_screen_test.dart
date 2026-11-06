import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_household_invite_remote.dart';

HouseholdInvite _sent(
  String id, {
  HouseholdInviteStatus status = HouseholdInviteStatus.pending,
  String? inviteeEmail,
  String householdName = 'Sunday Crew',
}) => invite(
  id,
  status: status,
  inviterId: 'u_me',
  inviteeEmail: inviteeEmail,
  householdId: 'hh_9',
  householdName: householdName,
);

const _onlineOnlyCopy = "Available when you're online";

void main() {
  late FakeHouseholdInviteRemote remote;

  setUp(() => remote = FakeHouseholdInviteRemote());

  Widget harness({
    TextScaler textScaler = TextScaler.noScaling,
    ValueListenable<bool>? offline,
    ThemeData? theme,
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    builder: (context, child) {
      final app = MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      );
      if (offline == null) return app;
      return ValueListenableBuilder<bool>(
        valueListenable: offline,
        child: app,
        builder: (context, isOffline, app) => BgeConnectivityScope(
          offline: isOffline,
          noticeShowing: isOffline,
          onlineOnlyReason: _onlineOnlyCopy,
          child: app!,
        ),
      );
    },
    home: SentInvitesScreen(remote: remote),
  );

  /// Answers every read with [rows], whatever the filter.
  void listing(List<HouseholdInvite> rows) =>
      remote.onFetchSent = (_, _, _) async => pageOf(rows);

  /// [matching] within the row for the invite [id].
  Finder inRow(String id, Finder matching) => find.descendant(
    of: find.byKey(SentInvitesScreen.rowKey(id)),
    matching: matching,
  );

  /// What the filter control says is chosen.
  String chosen(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(SentInvitesScreen.filterKey),
          matching: find.byType(Text),
        ),
      )
      .data!;

  /// Opens the filter menu and picks [label] from it.
  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(SentInvitesScreen.filterKey));
    await tester.pumpAndSettle();
    // The menu builds its entries only while it is open, so this fails if
    // the tap did not open it.
    await tester.tap(find.widgetWithText(MenuItemButton, label).hitTestable());
    await tester.pumpAndSettle();
  }

  testWidgets("shows each row's household, invitee and expiry", (tester) async {
    listing([
      _sent('i_1').copyWith(message: 'Bring snacks'),
      _sent(
        'i_2',
        status: HouseholdInviteStatus.awaitingApproval,
        householdName: 'Game Night',
      ).copyWith(role: HouseholdRole.householdGuest),
    ]);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(inRow('i_1', find.text('Sunday Crew')), findsOneWidget);
    expect(inRow('i_1', find.text('For Invitee i_1')), findsOneWidget);
    expect(inRow('i_1', find.text('Member')), findsOneWidget);
    expect(inRow('i_1', find.text('Expires Oct 26, 2026')), findsOneWidget);
    expect(inRow('i_1', find.text('Bring snacks')), findsOneWidget);
    expect(
      tester.widget<Text>(inRow('i_1', find.text('Bring snacks'))).style,
      isA<TextStyle>().having(
        (s) => s.fontStyle,
        'fontStyle',
        FontStyle.italic,
      ),
    );
    expect(
      inRow('i_1', find.byKey(SentInvitesScreen.withdrawKey('i_1'))),
      findsOneWidget,
    );

    expect(inRow('i_2', find.text('Game Night')), findsOneWidget);
    expect(inRow('i_2', find.text('For Invitee i_2')), findsOneWidget);
    expect(inRow('i_2', find.text('Guest')), findsOneWidget);
    expect(inRow('i_2', find.text('Awaiting approval')), findsOneWidget);
    expect(inRow('i_2', find.text('Expires Oct 26, 2026')), findsOneWidget);
    expect(inRow('i_1', find.text('Awaiting approval')), findsNothing);
  });

  testWidgets('Withdraw is disabled offline and says why, and the filter '
      'button stays enabled', (tester) async {
    final offline = ValueNotifier(true);
    addTearDown(offline.dispose);
    listing([_sent('i_1')]);
    await tester.pumpWidget(harness(offline: offline));
    await tester.pumpAndSettle();

    final withdraw = find.byKey(SentInvitesScreen.withdrawKey('i_1'));
    expect(tester.widget<ButtonStyleButton>(withdraw).onPressed, isNull);
    expect(
      tester.getSemantics(withdraw),
      matchesSemantics(
        label: 'Withdraw',
        hint: _onlineOnlyCopy,
        isButton: true,
        hasEnabledState: true,
      ),
    );
    expect(find.text(_onlineOnlyCopy), findsOneWidget);
    // Choosing what to list is no write.
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(SentInvitesScreen.filterKey))
          .onPressed,
      isNotNull,
    );

    offline.value = false;
    await tester.pumpAndSettle();

    expect(find.text(_onlineOnlyCopy), findsNothing);
    expect(tester.widget<ButtonStyleButton>(withdraw).onPressed, isNotNull);
  });

  testWidgets('an expired row offers no withdraw', (tester) async {
    listing([_sent('i_1', status: HouseholdInviteStatus.expired)]);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(SentInvitesScreen.withdrawKey('i_1')), findsNothing);
    expect(find.text('Expired Oct 26, 2026'), findsOneWidget);
  });

  testWidgets('a settled row shows its status, not an expiry', (tester) async {
    remote.onFetchSent = (status, _, _) async => pageOf([
      if (status == HouseholdInviteStatus.accepted)
        _sent('i_1', status: HouseholdInviteStatus.accepted),
    ]);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await choose(tester, 'Accepted');

    expect(remote.calls.last, 'fetchSent(accepted, 1, 25)');
    expect(inRow('i_1', find.text('Accepted')), findsOneWidget);
    expect(inRow('i_1', find.textContaining('Expires')), findsNothing);
    expect(inRow('i_1', find.textContaining('Expired')), findsNothing);
    expect(find.byKey(SentInvitesScreen.withdrawKey('i_1')), findsNothing);
  });

  testWidgets('withdraw removes the row and says so', (tester) async {
    // The server's list, as it stands.
    var rows = [_sent('i_1'), _sent('i_2')];
    remote
      ..onFetchSent = ((_, _, _) async => pageOf(rows))
      ..onWithdraw = (id) async {
        rows = [_sent('i_2')];
        return _sent(id, status: HouseholdInviteStatus.withdrawn);
      };
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(SentInvitesScreen.withdrawKey('i_1')));
    await tester.pumpAndSettle();

    expect(remote.calls, contains('withdraw(i_1)'));
    expect(find.byKey(SentInvitesScreen.rowKey('i_1')), findsNothing);
    expect(find.byKey(SentInvitesScreen.rowKey('i_2')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(SentInvitesScreen.outcomeKey),
        matching: find.text('Invite withdrawn.'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.byKey(SentInvitesScreen.outcomeKey), findsNothing);
  });

  testWidgets('a refused withdraw says why', (tester) async {
    // The invite ran out while the screen sat open: the server refuses the
    // withdraw, and lists it as expired when read again.
    var rows = [_sent('i_1')];
    remote
      ..onFetchSent = ((_, _, _) async => pageOf(rows))
      ..onWithdraw = (_) async {
        rows = [_sent('i_1', status: HouseholdInviteStatus.expired)];
        throw refused(410);
      };
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(SentInvitesScreen.withdrawKey('i_1')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(SentInvitesScreen.outcomeKey),
        matching: find.text('This invite has expired.'),
      ),
      findsOneWidget,
    );
    expect(remote.calls.last, 'fetchSent(null, 1, 25)');
    expect(find.byKey(SentInvitesScreen.withdrawKey('i_1')), findsNothing);
    expect(inRow('i_1', find.text('Expired Oct 26, 2026')), findsOneWidget);
  });

  testWidgets('choosing a filter reads that status', (tester) async {
    listing(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await choose(tester, 'Revoked');

    expect(remote.calls.last, 'fetchSent(revoked, 1, 25)');
    expect(chosen(tester), 'Show: Revoked');
  });

  testWidgets('choosing the filter already chosen reads nothing', (
    tester,
  ) async {
    listing(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    final reads = remote.calls.length;

    await choose(tester, 'Open and expired');

    expect(remote.calls.length, reads);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(chosen(tester), 'Show: Open and expired');
  });

  testWidgets('the open menu tells assistive tech which filter is chosen', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    listing(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(SentInvitesScreen.filterKey));
    await tester.pumpAndSettle();

    SemanticsNode entry(String label) => tester.getSemantics(
      find.widgetWithText(MenuItemButton, label).hitTestable(),
    );
    expect(
      entry('Open and expired'),
      isSemantics(
        label: 'Open and expired',
        hasSelectedState: true,
        isSelected: true,
      ),
    );
    expect(
      entry('Revoked'),
      isSemantics(label: 'Revoked', hasSelectedState: true, isSelected: false),
    );

    // Dispose inline: flutter_test checks for an open SemanticsHandle when
    // the body ends, before tearDown callbacks run.
    handle.dispose();
  });

  testWidgets('the menu shows a filter chosen before its read answers', (
    tester,
  ) async {
    listing(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await choose(tester, 'Revoked');

    final read = Completer<PaginatedResult<HouseholdInvite>>();
    remote.onFetchSent = (_, _, _) => read.future;
    await tester.tap(find.byKey(SentInvitesScreen.filterKey));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(MenuItemButton, 'Accepted').hitTestable(),
    );
    // Not settled: the spinner turns while the read is out. The menu hands
    // over its choice after the first frame, and the bloc's spinner draws
    // in the next.
    await tester.pump();
    await tester.pump();

    expect(find.byKey(SentInvitesScreen.loadingKey), findsOneWidget);
    expect(remote.calls.last, 'fetchSent(accepted, 1, 25)');
    expect(chosen(tester), 'Show: Accepted');

    read.complete(
      pageOf([_sent('i_1', status: HouseholdInviteStatus.accepted)]),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(SentInvitesScreen.rowKey('i_1')), findsOneWidget);
    expect(chosen(tester), 'Show: Accepted');
  });

  testWidgets('the filter tells assistive tech whether its menu is open', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    listing(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    final control = find.byKey(SentInvitesScreen.filterKey);

    expect(
      tester.getSemantics(control),
      isSemantics(
        label: 'Show: Open and expired',
        isButton: true,
        hasExpandedState: true,
        isExpanded: false,
      ),
    );

    await tester.tap(control);
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(control),
      isSemantics(hasExpandedState: true, isExpanded: true),
    );

    // Dispose inline: flutter_test checks for an open SemanticsHandle when
    // the body ends, before tearDown callbacks run.
    handle.dispose();
  });

  testWidgets('the empty list says so for its filter', (tester) async {
    listing(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(SentInvitesScreen.emptyKey),
        matching: find.text('You have no open or expired invites.'),
      ),
      findsOneWidget,
    );

    await choose(tester, 'Declined');

    expect(
      find.descendant(
        of: find.byKey(SentInvitesScreen.emptyKey),
        matching: find.text('No invites you sent have this status.'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a failed read offers to try again, and still filters', (
    tester,
  ) async {
    remote.onFetchSent = (_, _, _) async => throw offline();
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(SentInvitesScreen.failedKey), findsOneWidget);
    expect(find.text("Couldn't load the invites you sent"), findsOneWidget);

    listing([_sent('i_1', status: HouseholdInviteStatus.revoked)]);
    await choose(tester, 'Revoked');

    expect(remote.calls.last, 'fetchSent(revoked, 1, 25)');
    expect(find.byKey(SentInvitesScreen.rowKey('i_1')), findsOneWidget);
  });

  testWidgets('a row with no household name says a household', (tester) async {
    listing([_sent('i_1').copyWith(householdName: null)]);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(inRow('i_1', find.text('A household')), findsOneWidget);
  });

  testWidgets('a row with no invitee name says a user account', (tester) async {
    listing([_sent('i_1').copyWith(inviteeName: null)]);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(inRow('i_1', find.text('For a user account')), findsOneWidget);
  });

  testWidgets('tells a screen reader how many rows there are', (tester) async {
    listing([_sent('i_1'), _sent('i_2')]);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(SentInvitesScreen.rowKey('i_1')), findsOneWidget);
    expect(find.byKey(SentInvitesScreen.rowKey('i_2')), findsOneWidget);
    final scrollable = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scrollable.semanticChildCount, equals(2));
  });

  // At the default text scale, and at BgeTextScale.maxScaleFactor, the
  // largest the shell lets through.
  for (final scale in [1.0, BgeTextScale.maxScaleFactor]) {
    testWidgets('fits a 320-wide screen at text scale $scale', (tester) async {
      useViewSize(tester, const Size(320, 640));
      const household =
          'The Saturday Afternoon Cooperative and Strategy Game Society';
      const address =
          'saturday.afternoon.cooperative.strategy.gaming@example.co.uk';
      expect(household.length, 60);
      expect(address.length, 60);
      listing([
        _sent(
          'i_1',
          status: HouseholdInviteStatus.awaitingApproval,
          inviteeEmail: address,
          householdName: household,
        ).copyWith(inviteeName: null),
      ]);
      await tester.pumpWidget(harness(textScaler: TextScaler.linear(scale)));
      await tester.pumpAndSettle();

      expect(inRow('i_1', find.text('For $address')), findsOneWidget);

      // The chosen filter wraps inside the control. A single-line field cut
      // it to "Open and exp" here, and clipping is not an overflow, so
      // takeException never saw it.
      final control = tester.getRect(find.byKey(SentInvitesScreen.filterKey));
      final label = find.descendant(
        of: find.byKey(SentInvitesScreen.filterKey),
        matching: find.text('Show: Open and expired'),
      );
      expect(
        tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
        isFalse,
      );
      expect(control.intersect(tester.getRect(label)), tester.getRect(label));

      await tester.tap(find.byKey(SentInvitesScreen.filterKey));
      await tester.pumpAndSettle();
      final awaiting = find.widgetWithText(MenuItemButton, 'Awaiting approval');
      expect(awaiting.hitTestable(), findsOneWidget);
      // Its entries wrap within the control's width too, rather than
      // widening the menu past the screen's edge, where it clips them.
      final entry = tester.getRect(
        find.descendant(of: awaiting, matching: find.text('Awaiting approval')),
      );
      expect(entry.left, greaterThanOrEqualTo(control.left));
      expect(entry.right, lessThanOrEqualTo(control.right));

      expect(tester.takeException(), isNull);
    });
  }

  group('accessibility audit', () {
    /// The screen over the fake as [seed] leaves it; `build` runs before the
    /// first read, so the state is chosen here.
    Widget Function(ThemeData, TextScaler) screenWith(
      void Function() seed, {
      ValueListenable<bool>? offline,
    }) => (theme, textScaler) {
      seed();
      return harness(theme: theme, textScaler: textScaler, offline: offline);
    };

    /// A pending row, an awaiting-approval one, an expired one and a settled
    /// one, so every row shape is on the page.
    void rows() => listing([
      _sent('i_1').copyWith(message: 'Bring snacks'),
      _sent(
        'i_2',
        status: HouseholdInviteStatus.awaitingApproval,
        householdName: 'Game Night',
      ).copyWith(role: HouseholdRole.householdGuest),
      _sent('i_3', status: HouseholdInviteStatus.expired),
      _sent('i_4', status: HouseholdInviteStatus.declined),
    ]);

    Future<void> withdrawOne(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SentInvitesScreen.withdrawKey('i_1')));
      await tester.pumpAndSettle();
      expect(find.byKey(SentInvitesScreen.outcomeKey), findsOneWidget);
    }

    testWidgets('the harness applies the theme and the text scale', (
      tester,
    ) async {
      rows();
      await tester.pumpWidget(
        harness(theme: BgeTheme.dark(), textScaler: const TextScaler.linear(2)),
      );
      await tester.pumpAndSettle();

      final screen = find.byType(SentInvitesScreen);
      expect(MediaQuery.textScalerOf(tester.element(screen)).scale(10), 20);
      expect(Theme.of(tester.element(screen)).brightness, Brightness.dark);
    });

    auditScreen(
      'ready',
      build: screenWith(rows),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(
          find.byKey(SentInvitesScreen.withdrawKey('i_1')),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'ready, scrolled to the end',
      build: screenWith(rows),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await scrollPageToEnd(tester);
      },
    );

    auditScreen(
      'filter menu open',
      build: screenWith(rows),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(SentInvitesScreen.filterKey));
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsWidgets);
      },
    );

    auditScreen(
      'offline',
      build: screenWith(rows, offline: ValueNotifier(true)),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.text(_onlineOnlyCopy), findsWidgets);
      },
      // The failing nodes are the disabled Withdraw buttons, drawn dimmed by
      // design; WCAG 1.4.3 exempts inactive controls, and the enabled ones
      // pass in 'ready'.
      textContrast: false,
    );

    auditScreen(
      'withdrawn',
      build: screenWith(() {
        var current = [_sent('i_1'), _sent('i_2')];
        remote
          ..onFetchSent = ((_, _, _) async => pageOf(current))
          ..onWithdraw = (id) async {
            current = [_sent('i_2')];
            return _sent(id, status: HouseholdInviteStatus.withdrawn);
          };
      }),
      arrange: withdrawOne,
    );

    auditScreen(
      'withdraw refused',
      build: screenWith(() {
        var current = [_sent('i_1')];
        remote
          ..onFetchSent = ((_, _, _) async => pageOf(current))
          ..onWithdraw = (_) async {
            current = [_sent('i_1', status: HouseholdInviteStatus.expired)];
            throw refused(410);
          };
      }),
      arrange: withdrawOne,
    );

    auditScreen(
      'more to load',
      build: screenWith(
        () => remote.onFetchSent = (_, _, _) async =>
            pageOf([for (var i = 0; i < 25; i++) _sent('i_$i')], hasMore: true),
      ),
      arrange: (tester) =>
          scrollListToEnd(tester, find.byKey(SentInvitesScreen.moreKey)),
    );

    auditScreen(
      'empty',
      build: screenWith(() => listing(const [])),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(SentInvitesScreen.emptyKey), findsOneWidget);
      },
    );

    auditScreen(
      'failure',
      build: screenWith(
        () => remote.onFetchSent = (_, _, _) async => throw offline(),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(SentInvitesScreen.failedKey), findsOneWidget);
      },
    );

    // The first read never answers, so the spinner never stops.
    auditScreen(
      'loading',
      build: screenWith(() {
        final read = Completer<PaginatedResult<HouseholdInvite>>();
        addTearDown(() => read.complete(pageOf(const <HouseholdInvite>[])));
        remote.onFetchSent = (_, _, _) => read.future;
      }),
      arrange: (tester) async {
        await tester.pump();
        expect(find.byKey(SentInvitesScreen.loadingKey), findsOneWidget);
      },
      settle: false,
    );
  });
}
