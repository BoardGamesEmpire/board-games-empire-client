import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_household_invite_remote.dart';

void main() {
  late FakeHouseholdInviteRemote remote;
  late int sent;

  setUp(() {
    remote = FakeHouseholdInviteRemote();
    sent = 0;
  });

  Widget harness({HouseholdRole? viewerRole = HouseholdRole.householdOwner}) =>
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
        supportedLocales: HouseholdLocalizations.supportedLocales,
        home: SendHouseholdInviteScreen(
          householdId: 'hh_1',
          viewerRole: viewerRole,
          remote: remote,
          onSent: (_) => sent++,
        ),
      );

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(SendHouseholdInviteScreen.submitKey));
    await tester.tap(find.byKey(SendHouseholdInviteScreen.submitKey));
    await tester.pump();
  }

  /// Lets a successful send land. Not a settle: the button spins until the
  /// route closes, and this harness's `onSent` leaves it open.
  Future<void> sentAndSpinning(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<Set<String>> roleChoices(WidgetTester tester) async {
    await tester.tap(find.byKey(SendHouseholdInviteScreen.roleKey));
    await tester.pumpAndSettle();
    final items = tester
        .widgetList<DropdownMenuItem<HouseholdRole>>(
          find.byType(DropdownMenuItem<HouseholdRole>),
        )
        .map((item) => (item.child as Text).data!)
        .toSet();
    return items;
  }

  group('roles', () {
    testWidgets('an owner may offer Admin, Member or Guest, Member first '
        'chosen', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(SendHouseholdInviteScreen.roleKey),
          matching: find.text('Member'),
        ),
        findsOneWidget,
      );
      expect(await roleChoices(tester), {'Admin', 'Member', 'Guest'});
    });

    testWidgets('an admin may offer only Member or Guest', (tester) async {
      await tester.pumpWidget(
        harness(viewerRole: HouseholdRole.householdAdmin),
      );
      await tester.pumpAndSettle();

      expect(await roleChoices(tester), {'Member', 'Guest'});
    });

    testWidgets('a role no longer the viewer\'s to offer is unpicked when '
        'their role changes', (tester) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SendHouseholdInviteScreen.roleKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Admin').last);
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        harness(viewerRole: HouseholdRole.householdAdmin),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byKey(SendHouseholdInviteScreen.roleKey),
          matching: find.text('Member'),
        ),
        findsOneWidget,
      );
      expect(await roleChoices(tester), {'Member', 'Guest'});
    });

    testWidgets('anyone else gets no form', (tester) async {
      await tester.pumpWidget(
        harness(viewerRole: HouseholdRole.householdMember),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsNothing);
      expect(
        find.text("Only this household's owners and admins can invite people."),
        findsOneWidget,
      );
    });
  });

  testWidgets('an address typed with spaces around it is sent trimmed', (
    tester,
  ) async {
    remote.onSend = (_, _) async => invite('i_1');
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(SendHouseholdInviteScreen.emailKey),
      '  ana@example.com  ',
    );
    await tester.enterText(
      find.byKey(SendHouseholdInviteScreen.nameKey),
      'Ana',
    );
    await submit(tester);
    await sentAndSpinning(tester);

    final draft = remote.sentDrafts.single;
    expect((draft.invitee as InviteeEmail).email, 'ana@example.com');
    expect(draft.inviteeName, 'Ana');
    expect(draft.role, HouseholdRole.householdMember);
    expect(sent, 1);
    expect(find.text('Invite sent.'), findsOneWidget);
  });

  testWidgets('an address that is not one is not sent', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(SendHouseholdInviteScreen.emailKey),
      'not an address',
    );
    await submit(tester);
    await tester.pumpAndSettle();

    expect(remote.sentDrafts, isEmpty);
    expect(find.text('Enter a valid email address.'), findsOneWidget);
  });

  testWidgets('picking someone from the search invites their account', (
    tester,
  ) async {
    remote
      ..onSearchUsers = ((_, _, _) async => pageOf(const [
        UserSummary(id: 'u_2', username: 'ana', displayName: 'Ana B'),
      ]))
      ..onSend = (_, _) async => invite('i_1');
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Person'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(SendHouseholdInviteScreen.searchKey),
      'ana',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(remote.calls, ['searchUsers(ana)']);

    await tester.tap(find.byKey(SendHouseholdInviteScreen.resultKey('u_2')));
    await tester.pumpAndSettle();
    await submit(tester);
    await sentAndSpinning(tester);

    expect((remote.sentDrafts.single.invitee as InviteeUser).userId, 'u_2');
  });

  testWidgets('person mode with no one picked is not sent', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Person'));
    await tester.pumpAndSettle();
    await submit(tester);
    await tester.pumpAndSettle();

    expect(remote.sentDrafts, isEmpty);
    expect(find.text('Pick someone to invite.'), findsOneWidget);
  });

  testWidgets('a refusal says why, and the form stays filled in', (
    tester,
  ) async {
    remote.onSend = (_, _) async => throw refused(409);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(SendHouseholdInviteScreen.emailKey),
      'ana@example.com',
    );
    await submit(tester);
    await tester.pumpAndSettle();

    expect(
      find.text("They're already a member, or already have an open invite."),
      findsOneWidget,
    );
    expect(find.text("Couldn't send the invite"), findsOneWidget);
    expect(find.text('ana@example.com'), findsOneWidget);
    expect(sent, 0);
  });

  testWidgets('editing after a refusal retires it', (tester) async {
    remote.onSend = (_, _) async => throw refused(409);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(SendHouseholdInviteScreen.emailKey),
      'ana@example.com',
    );
    await submit(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(SendHouseholdInviteScreen.errorKey), findsOneWidget);

    await tester.enterText(
      find.byKey(SendHouseholdInviteScreen.emailKey),
      'bo@example.com',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(SendHouseholdInviteScreen.errorKey), findsNothing);
  });

  testWidgets('the submit is disabled while sending, so a second tap sends '
      'nothing', (tester) async {
    final answer = Completer<HouseholdInvite>();
    remote.onSend = (_, _) => answer.future;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(SendHouseholdInviteScreen.emailKey),
      'ana@example.com',
    );
    await submit(tester);

    expect(
      tester
          .widget<BgeSubmitButton>(
            find.byKey(SendHouseholdInviteScreen.submitKey),
          )
          .submitting,
      isTrue,
    );
    await tester.tap(
      find.byKey(SendHouseholdInviteScreen.submitKey),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(remote.sentDrafts, hasLength(1));

    answer.complete(invite('i_1'));
    await sentAndSpinning(tester);
    expect(sent, 1);
  });
}
