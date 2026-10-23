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

  Widget harness() => MaterialApp(
    theme: BgeTheme.light(),
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    home: InviteInboxScreen(
      remote: remote,
      onJoined: (_) async {},
      onOpenHousehold: (_, householdId) => opened.add(householdId),
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
}
