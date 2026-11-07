import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_household_invite_remote.dart';

const _onlineOnlyCopy = "Available when you're online";

HouseholdInvite _received(
  String id, {
  HouseholdInviteStatus status = HouseholdInviteStatus.pending,
}) => invite(
  id,
  status: status,
  householdId: 'hh_9',
  householdName: 'Sunday Crew',
);

void main() {
  late FakeHouseholdInviteRemote remote;
  late List<String> opened;

  setUp(() {
    remote = FakeHouseholdInviteRemote();
    opened = [];
  });

  /// [textScaler], when given, overrides the scale the view gives the app.
  Widget harness({
    void Function(BuildContext context)? onOpenSent,
    TextScaler? textScaler,
    ValueListenable<bool>? offline,
    ThemeData? theme,
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    builder: (context, child) {
      final app = textScaler == null
          ? child!
          : MediaQuery(
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
    home: InviteInboxScreen(
      remote: remote,
      onJoined: (_) async {},
      onOpenHousehold: (_, householdId) => opened.add(householdId),
      onOpenSent: onOpenSent,
    ),
  );

  testWidgets('a row names the household and who sent it', (tester) async {
    remote.onFetchInbox = (_, _) async => pageOf([_received('i_1')]);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('Sunday Crew'), findsOneWidget);
    expect(find.text('Invited by u_other'), findsOneWidget);
    expect(find.text('Member'), findsOneWidget);
  });

  testWidgets('online, the buttons sit in the same padding as before the '
      'offline note', (tester) async {
    remote.onFetchInbox = (_, _) async => pageOf([_received('i_1')]);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final wrap = find.byType(Wrap);
    final padding = find
        .ancestor(of: wrap, matching: find.byType(Padding))
        .first;
    // Only the 8dp bottom inset, no gap for a note.
    expect(tester.getSize(padding).height - tester.getSize(wrap).height, 8.0);
  });

  testWidgets('Accept and Decline are disabled offline and say why', (
    tester,
  ) async {
    final offline = ValueNotifier(true);
    addTearDown(offline.dispose);
    remote.onFetchInbox = (_, _) async => pageOf([_received('i_1')]);
    await tester.pumpWidget(harness(offline: offline));
    await tester.pumpAndSettle();

    final accept = find.byKey(InviteInboxScreen.acceptKey('i_1'));
    final decline = find.byKey(InviteInboxScreen.declineKey('i_1'));
    for (final (button, label) in [(accept, 'Accept'), (decline, 'Decline')]) {
      expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
      expect(
        tester.getSemantics(button),
        matchesSemantics(
          label: label,
          hint: _onlineOnlyCopy,
          isButton: true,
          hasEnabledState: true,
        ),
      );
    }
    // Once under the pair, not once a button.
    expect(find.text(_onlineOnlyCopy), findsOneWidget);

    offline.value = false;
    await tester.pumpAndSettle();

    expect(find.text(_onlineOnlyCopy), findsNothing);
    expect(tester.widget<ButtonStyleButton>(accept).onPressed, isNotNull);
    expect(tester.widget<ButtonStyleButton>(decline).onPressed, isNotNull);
  });

  testWidgets('Accept joins, then offers to open the household', (
    tester,
  ) async {
    remote
      ..onFetchInbox = ((_, _) async => pageOf([_received('i_1')]))
      ..onAccept = (id) async => (
        invite: _received(id, status: HouseholdInviteStatus.accepted),
        householdId: 'hh_9',
      );
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(InviteInboxScreen.acceptKey('i_1')));
    await tester.pumpAndSettle();

    expect(remote.calls.last, 'accept(i_1)');
    expect(find.text('You joined Sunday Crew.'), findsOneWidget);

    await tester.tap(find.byKey(InviteInboxScreen.openHouseholdKey));
    expect(opened, ['hh_9']);
  });

  testWidgets("the joined outcome's two actions lay out at 320dp and 200% "
      '(#452)', (tester) async {
    // The outcome's action is two buttons, the widest action any banner
    // carries. At 200% on this window both together are wider than the
    // banner, so their right edges are what show whether they wrap inside
    // it or run off the window.
    const width = 320.0;
    remote
      ..onFetchInbox = ((_, _) async => pageOf([_received('i_1')]))
      ..onAccept = (id) async => (
        invite: _received(id, status: HouseholdInviteStatus.accepted),
        householdId: 'hh_9',
      );
    useViewSize(tester, const Size(width, 800));
    await tester.pumpWidget(
      harness(textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(InviteInboxScreen.acceptKey('i_1')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('You joined Sunday Crew.'), findsOneWidget);
    final dismiss = find.descendant(
      of: find.byKey(InviteInboxScreen.outcomeKey),
      matching: find.widgetWithText(TextButton, 'Dismiss'),
    );
    expect(dismiss, findsOneWidget);
    final open = find.byKey(InviteInboxScreen.openHouseholdKey);
    for (final button in [open, dismiss]) {
      expect(tester.getRect(button).right, lessThanOrEqualTo(width));
    }

    // On two lines, both buttons keep to the end edge, where the banner
    // puts its action.
    expect(
      tester.getRect(dismiss).top,
      greaterThanOrEqualTo(tester.getRect(open).bottom),
      reason: 'sanity: the buttons are on separate lines',
    );
    expect(
      tester.getRect(dismiss).right,
      moreOrLessEquals(tester.getRect(open).right),
    );
  });

  testWidgets('Decline asks first', (tester) async {
    remote
      ..onFetchInbox = ((_, _) async => pageOf([_received('i_1')]))
      ..onDecline = (id) async =>
          _received(id, status: HouseholdInviteStatus.declined);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(InviteInboxScreen.declineKey('i_1')));
    await tester.pumpAndSettle();
    expect(remote.calls.where((c) => c.startsWith('decline')), isEmpty);

    await tester.tap(find.byKey(InviteInboxScreen.declineConfirmKey));
    await tester.pumpAndSettle();

    expect(remote.calls.last, 'decline(i_1)');
    expect(find.text('Invite declined.'), findsOneWidget);
  });

  testWidgets('an empty inbox says so', (tester) async {
    remote.onFetchInbox = (_, _) async => pageOf(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(InviteInboxScreen.emptyKey), findsOneWidget);
    expect(find.text('You have no invites.'), findsOneWidget);
  });

  testWidgets('a failed read offers to try again', (tester) async {
    remote.onFetchInbox = (_, _) async => throw offline();
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(InviteInboxScreen.failedKey), findsOneWidget);
  });

  testWidgets('the sent action and empty link open the sent invites', (
    tester,
  ) async {
    remote.onFetchInbox = (_, _) async => pageOf(const []);
    var opens = 0;
    await tester.pumpWidget(harness(onOpenSent: (_) => opens++));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(InviteInboxScreen.sentKey));
    expect(opens, 1);
    expect(find.byTooltip('Sent invites'), findsOneWidget);

    expect(
      find.descendant(
        of: find.byKey(InviteInboxScreen.sentLinkKey),
        matching: find.text('See the invites you sent'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(InviteInboxScreen.sentLinkKey));
    expect(opens, 2);
  });

  testWidgets('without onOpenSent there is no way to the sent invites', (
    tester,
  ) async {
    remote.onFetchInbox = (_, _) async => pageOf(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(InviteInboxScreen.emptyKey), findsOneWidget);
    expect(find.byKey(InviteInboxScreen.sentKey), findsNothing);
    expect(find.byKey(InviteInboxScreen.sentLinkKey), findsNothing);
  });

  group('accessibility audit', () {
    /// The screen over the fake as [seed] leaves it; `build` runs before the
    /// first read, so the state is chosen here.
    Widget Function(ThemeData) screenWith(
      void Function() seed, {
      ValueListenable<bool>? offline,
      void Function(BuildContext)? onOpenSent,
    }) => (theme) {
      seed();
      return harness(theme: theme, offline: offline, onOpenSent: onOpenSent);
    };

    void rows() => remote.onFetchInbox = (_, _) async => pageOf([
      _received('i_1'),
      _received('i_2'),
      _received('i_3', status: HouseholdInviteStatus.accepted),
    ]);

    void accepting() {
      rows();
      remote.onAccept = (id) async => (
        invite: _received(id, status: HouseholdInviteStatus.accepted),
        householdId: 'hh_9',
      );
    }

    void declining() {
      rows();
      remote.onDecline = (id) async =>
          _received(id, status: HouseholdInviteStatus.declined);
    }

    void openSent(BuildContext _) {}

    Future<void> shown(WidgetTester tester) => tester.pumpAndSettle();

    Future<void> accept(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(InviteInboxScreen.acceptKey('i_1')));
      await tester.pumpAndSettle();
      expect(find.byKey(InviteInboxScreen.outcomeKey), findsOneWidget);
    }

    Future<void> decline(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(InviteInboxScreen.declineKey('i_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(InviteInboxScreen.declineConfirmKey));
      await tester.pumpAndSettle();
      expect(find.text('Invite declined.'), findsOneWidget);
    }

    auditScreen(
      'ready',
      build: screenWith(rows, onOpenSent: openSent),
      arrange: (tester) async {
        await shown(tester);
        expect(find.byKey(InviteInboxScreen.acceptKey('i_1')), findsOneWidget);
        expect(find.byKey(InviteInboxScreen.sentKey), findsOneWidget);
      },
    );

    auditScreen(
      'ready, scrolled to the end',
      build: screenWith(rows, onOpenSent: openSent),
      arrange: (tester) async {
        await shown(tester);
        await scrollPageToEnd(tester);
      },
    );

    auditScreen(
      'offline',
      build: screenWith(rows, offline: ValueNotifier(true)),
      arrange: (tester) async {
        await shown(tester);
        expect(find.text(_onlineOnlyCopy), findsWidgets);
      },
      // The failing nodes are the disabled Accept and Decline buttons, drawn
      // dimmed by design; WCAG 1.4.3 exempts inactive controls, and the
      // enabled buttons pass in 'ready'.
      textContrast: false,
    );

    auditScreen('joined', build: screenWith(accepting), arrange: accept);

    auditScreen(
      'joined, scrolled to the end',
      build: screenWith(accepting),
      arrange: (tester) async {
        await accept(tester);
        await scrollPageToEnd(tester);
      },
    );

    auditScreen('declined', build: screenWith(declining), arrange: decline);

    auditScreen(
      'more to load',
      build: screenWith(
        () => remote.onFetchInbox = (_, _) async => pageOf([
          for (var i = 0; i < 25; i++) _received('i_$i'),
        ], hasMore: true),
      ),
      arrange: (tester) =>
          scrollListToEnd(tester, find.byKey(InviteInboxScreen.moreKey)),
    );

    auditScreen(
      'empty',
      build: screenWith(
        () => remote.onFetchInbox = (_, _) async => pageOf(const []),
        onOpenSent: openSent,
      ),
      arrange: (tester) async {
        await shown(tester);
        expect(find.byKey(InviteInboxScreen.emptyKey), findsOneWidget);
        expect(find.byKey(InviteInboxScreen.sentLinkKey), findsOneWidget);
      },
    );

    auditScreen(
      'failure',
      build: screenWith(
        () => remote.onFetchInbox = (_, _) async => throw offline(),
      ),
      arrange: (tester) async {
        await shown(tester);
        expect(find.byKey(InviteInboxScreen.failedKey), findsOneWidget);
      },
    );

    // The first read never answers, so the spinner never stops.
    auditScreen(
      'loading',
      build: screenWith(() {
        final read = Completer<PaginatedResult<HouseholdInvite>>();
        addTearDown(() => read.complete(pageOf(const <HouseholdInvite>[])));
        remote.onFetchInbox = (_, _) => read.future;
      }),
      arrange: (tester) async {
        await tester.pump();
        expect(find.byKey(InviteInboxScreen.loadingKey), findsOneWidget);
      },
      settle: false,
    );
  });
}
