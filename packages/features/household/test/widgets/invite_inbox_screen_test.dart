import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_household_invite_remote.dart';

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

  Widget harness({
    void Function(BuildContext context)? onOpenSent,
    TextScaler textScaler = TextScaler.noScaling,
  }) => MaterialApp(
    theme: BgeTheme.light(),
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
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
}
