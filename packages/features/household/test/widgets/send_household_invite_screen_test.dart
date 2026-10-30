import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:user_search/user_search.dart';

import '../support/fake_household_invite_remote.dart';
import '../support/fake_user_remote.dart';

const _unknownCopy =
    "Can't tell yet whether you can invite people to this household.";

void main() {
  late FakeHouseholdInviteRemote remote;
  late FakeUserRemote users;
  late int sent;
  late int memberSent;
  late int refreshes;

  setUp(() {
    remote = FakeHouseholdInviteRemote();
    users = FakeUserRemote();
    sent = 0;
    memberSent = 0;
    refreshes = 0;
  });

  Widget harness({
    HouseholdRole? viewerRole = HouseholdRole.householdOwner,
    MemberInvitePolicy? policy,
    Future<void> Function()? onRefresh,
  }) => MaterialApp(
    theme: BgeTheme.light(),
    localizationsDelegates: [
      ...HouseholdLocalizations.localizationsDelegates,
      UserSearchLocalizations.delegate,
    ],
    supportedLocales: HouseholdLocalizations.supportedLocales,
    home: SendHouseholdInviteScreen(
      householdId: 'hh_1',
      viewerRole: viewerRole,
      memberInvitePolicy: policy,
      remote: remote,
      users: users,
      onSent: (_) => sent++,
      onMemberSent: (_) => memberSent++,
      onRefresh: onRefresh,
    ),
  );

  /// Counts a refresh that answers at once.
  Future<void> counted() async => refreshes++;

  /// [text] as the reason the form isn't shown.
  Finder notAllowed(String text) => find.descendant(
    of: find.byKey(SendHouseholdInviteScreen.notAllowedKey),
    matchRoot: true,
    matching: find.text(text),
  );

  ButtonStyleButton retryButton(WidgetTester tester) =>
      tester.widget<ButtonStyleButton>(
        find.descendant(
          of: find.byKey(SendHouseholdInviteScreen.refreshKey),
          matching: find.bySubtype<ButtonStyleButton>(),
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
        .widgetList<Text>(
          find.descendant(
            of: find.byType(MenuItemButton),
            matching: find.byType(Text),
          ),
        )
        .map((text) => text.data!)
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

    testWidgets('a viewer the cache cannot place gets no form, and may try '
        'again', (tester) async {
      await tester.pumpWidget(harness(viewerRole: null, onRefresh: counted));
      await tester.pumpAndSettle();

      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsNothing);
      expect(notAllowed(_unknownCopy), findsOneWidget);
      expect(find.byKey(SendHouseholdInviteScreen.refreshKey), findsOneWidget);
    });
  });

  group('a member, by the household policy (#569)', () {
    const member = HouseholdRole.householdMember;

    Future<void> sendOne(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(SendHouseholdInviteScreen.emailKey),
        'ana@example.com',
      );
      await submit(tester);
      await sentAndSpinning(tester);
    }

    testWidgets('a member under Direct gets the form with Member and Guest', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(viewerRole: member, policy: MemberInvitePolicy.direct),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsOneWidget);
      expect(
        find.byKey(SendHouseholdInviteScreen.approvalNoteKey),
        findsNothing,
      );
      expect(await roleChoices(tester), {'Member', 'Guest'});
    });

    testWidgets('a member under NeedsApproval sees the approval note', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(viewerRole: member, policy: MemberInvitePolicy.needsApproval),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(SendHouseholdInviteScreen.approvalNoteKey),
          matching: find.text(
            "An owner or admin has to approve this invite before the person "
            "you're inviting sees it.",
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an owner sees no approval note under NeedsApproval', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(policy: MemberInvitePolicy.needsApproval),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsOneWidget);
      expect(
        find.byKey(SendHouseholdInviteScreen.approvalNoteKey),
        findsNothing,
      );
      expect(await roleChoices(tester), {'Admin', 'Member', 'Guest'});
    });

    testWidgets('a member under Off gets the Off text, with nothing to press', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          viewerRole: member,
          policy: MemberInvitePolicy.off,
          onRefresh: counted,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsNothing);
      expect(
        notAllowed(
          "This household isn't taking invites from members right now. "
          'An owner or admin can still invite people.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(SendHouseholdInviteScreen.refreshKey), findsNothing);
    });

    testWidgets("a member whose household's policy isn't cached yet gets the "
        "can't-tell text, and may try again", (tester) async {
      await tester.pumpWidget(harness(viewerRole: member, onRefresh: counted));
      await tester.pumpAndSettle();

      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsNothing);
      expect(notAllowed(_unknownCopy), findsOneWidget);
      expect(find.byKey(SendHouseholdInviteScreen.refreshKey), findsOneWidget);
    });

    testWidgets('trying again reads the household, and says so until the read '
        'ends', (tester) async {
      final pass = Completer<void>();
      await tester.pumpWidget(
        harness(
          viewerRole: member,
          onRefresh: () {
            refreshes++;
            return pass.future;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(SendHouseholdInviteScreen.refreshKey));
      await tester.pump();

      expect(refreshes, 1);
      expect(find.text('Refreshing…'), findsWidgets);
      expect(retryButton(tester).onPressed, isNull);
      await tester.tap(
        find.byKey(SendHouseholdInviteScreen.refreshKey),
        warnIfMissed: false,
      );
      expect(refreshes, 1, reason: 'a second press queues nothing');

      pass.complete();
      await tester.pumpAndSettle();

      // Nothing the read brought changed the answer: the screen's caller
      // redraws it with a new policy when one arrives.
      expect(notAllowed(_unknownCopy), findsOneWidget);
      expect(retryButton(tester).onPressed, isNotNull);
    });

    testWidgets('a read that throws still ends the refreshing', (tester) async {
      await tester.pumpWidget(
        harness(
          viewerRole: member,
          onRefresh: () async => throw StateError('refresh failed'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(SendHouseholdInviteScreen.refreshKey));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(notAllowed(_unknownCopy), findsOneWidget);
      expect(retryButton(tester).onPressed, isNotNull);
    });

    testWidgets("without a way to read the household, the can't-tell text "
        'offers nothing to press', (tester) async {
      await tester.pumpWidget(harness(viewerRole: member));
      await tester.pumpAndSettle();

      expect(notAllowed(_unknownCopy), findsOneWidget);
      expect(find.byKey(SendHouseholdInviteScreen.refreshKey), findsNothing);
    });

    testWidgets("a member under a policy this app doesn't recognise is told "
        'so, with nothing to press', (tester) async {
      await tester.pumpWidget(
        harness(
          viewerRole: member,
          policy: MemberInvitePolicy.unknown,
          onRefresh: counted,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsNothing);
      expect(
        notAllowed(
          'This household uses an invite setting this version of the app '
          "doesn't recognise.",
        ),
        findsOneWidget,
      );
      expect(find.byKey(SendHouseholdInviteScreen.refreshKey), findsNothing);
    });

    testWidgets("a viewer whose role this app doesn't recognise is told so, "
        'with nothing to press', (tester) async {
      await tester.pumpWidget(
        harness(
          viewerRole: HouseholdRole.unknown,
          policy: MemberInvitePolicy.direct,
          onRefresh: counted,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsNothing);
      expect(
        notAllowed(
          "This version of the app doesn't recognise your role in this "
          "household, so it can't tell whether you can invite people.",
        ),
        findsOneWidget,
      );
      expect(find.byKey(SendHouseholdInviteScreen.refreshKey), findsNothing);
    });

    testWidgets('a guest gets the guest text, with nothing to press', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          viewerRole: HouseholdRole.householdGuest,
          policy: MemberInvitePolicy.direct,
          onRefresh: counted,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsNothing);
      expect(
        notAllowed("Guests can't invite people to this household."),
        findsOneWidget,
      );
      expect(find.byKey(SendHouseholdInviteScreen.refreshKey), findsNothing);
    });

    testWidgets("a member's send calls onMemberSent, not onSent", (
      tester,
    ) async {
      remote.onSend = (_, _) async => invite('i_1');
      await tester.pumpWidget(
        harness(viewerRole: member, policy: MemberInvitePolicy.direct),
      );
      await tester.pumpAndSettle();

      await sendOne(tester);

      expect(remote.sentDrafts.single.role, HouseholdRole.householdMember);
      expect(memberSent, 1);
      expect(sent, 0);
      expect(find.text('Invite sent.'), findsOneWidget);
    });

    testWidgets("an owner's send calls onSent", (tester) async {
      remote.onSend = (_, _) async => invite('i_1');
      await tester.pumpWidget(harness(policy: MemberInvitePolicy.off));
      await tester.pumpAndSettle();

      await sendOne(tester);

      expect(sent, 1);
      expect(memberSent, 0);
    });

    testWidgets('a send still on its way when the policy turns Off lands', (
      tester,
    ) async {
      final answer = Completer<HouseholdInvite>();
      remote.onSend = (_, _) => answer.future;
      await tester.pumpWidget(
        harness(viewerRole: member, policy: MemberInvitePolicy.direct),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(SendHouseholdInviteScreen.emailKey),
        'ana@example.com',
      );
      await submit(tester);

      await tester.pumpWidget(
        harness(viewerRole: member, policy: MemberInvitePolicy.off),
      );
      await tester.pump();
      expect(
        notAllowed(
          "This household isn't taking invites from members right now. "
          'An owner or admin can still invite people.',
        ),
        findsOneWidget,
      );

      answer.complete(invite('i_1'));
      await sentAndSpinning(tester);

      expect(memberSent, 1);
      expect(find.text('Invite sent.'), findsOneWidget);
    });

    for (final (label, role) in [
      ('a guest', HouseholdRole.householdGuest),
      ('a role the app doesn\'t know', HouseholdRole.unknown),
      ('a role the cache can\'t say', null),
    ]) {
      testWidgets('a send still on its way when the viewer becomes $label '
          'calls onMemberSent, not onSent', (tester) async {
        final answer = Completer<HouseholdInvite>();
        remote.onSend = (_, _) => answer.future;
        await tester.pumpWidget(
          harness(viewerRole: member, policy: MemberInvitePolicy.direct),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(SendHouseholdInviteScreen.emailKey),
          'ana@example.com',
        );
        await submit(tester);

        await tester.pumpWidget(
          harness(viewerRole: role, policy: MemberInvitePolicy.direct),
        );
        await tester.pump();

        answer.complete(invite('i_1'));
        await sentAndSpinning(tester);

        expect(memberSent, 1);
        expect(sent, 0);
      });
    }

    testWidgets('a policy back on while a send is on its way offers no '
        'second send', (tester) async {
      final answer = Completer<HouseholdInvite>();
      remote.onSend = (_, _) => answer.future;
      await tester.pumpWidget(
        harness(viewerRole: member, policy: MemberInvitePolicy.direct),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(SendHouseholdInviteScreen.emailKey),
        'ana@example.com',
      );
      await submit(tester);

      await tester.pumpWidget(
        harness(viewerRole: member, policy: MemberInvitePolicy.off),
      );
      await tester.pump();
      await tester.pumpWidget(
        harness(viewerRole: member, policy: MemberInvitePolicy.direct),
      );
      await tester.pump();

      expect(
        tester
            .widget<BgeSubmitButton>(
              find.byKey(SendHouseholdInviteScreen.submitKey),
            )
            .submitting,
        isTrue,
      );

      answer.complete(invite('i_1'));
      await sentAndSpinning(tester);
      expect(remote.sentDrafts, hasLength(1));
      expect(memberSent, 1);
    });

    testWidgets('a send awaiting approval says Sent for approval.', (
      tester,
    ) async {
      remote.onSend = (_, _) async =>
          invite('i_1', status: HouseholdInviteStatus.awaitingApproval);
      await tester.pumpWidget(
        harness(viewerRole: member, policy: MemberInvitePolicy.needsApproval),
      );
      await tester.pumpAndSettle();

      await sendOne(tester);

      expect(find.text('Sent for approval.'), findsOneWidget);
      expect(find.text('Invite sent.'), findsNothing);
      expect(memberSent, 1);
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
    expect(memberSent, 0);
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
    users.onSearchUsers = (_, _, _) async => pageOf(const [
      UserSummary(id: 'u_2', username: 'ana', displayName: 'Ana B'),
    ]);
    remote.onSend = (_, _) async => invite('i_1');
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
    expect(users.calls, ['searchUsers(ana)']);

    await tester.tap(find.byKey(SendHouseholdInviteScreen.resultKey('u_2')));
    await tester.pumpAndSettle();
    await submit(tester);
    await sentAndSpinning(tester);

    expect((remote.sentDrafts.single.invitee as InviteeUser).userId, 'u_2');
  });

  testWidgets("the last query's results cannot be picked while a new one "
      'waits out its pause', (tester) async {
    users.onSearchUsers = (query, _, _) async => pageOf([
      if (query == 'ana')
        const UserSummary(id: 'u_2', username: 'ana', displayName: 'Ana B')
      else
        const UserSummary(id: 'u_3', username: 'bo'),
    ]);
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
    expect(find.byKey(SendHouseholdInviteScreen.resultKey('u_2')), findsOne);

    await tester.enterText(
      find.byKey(SendHouseholdInviteScreen.searchKey),
      'bo',
    );
    await tester.pump();

    expect(
      find.byKey(SendHouseholdInviteScreen.resultKey('u_2')),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byKey(SendHouseholdInviteScreen.resultKey('u_3')), findsOne);
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

  testWidgets("person mode's search field takes its label and hint from the "
      'shared user search', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Person'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(SendHouseholdInviteScreen.searchKey),
        matching: find.byType(TextField),
      ),
    );
    expect(field.decoration!.labelText, 'Search by name or username');
    expect(field.decoration!.helperText, 'Type at least 2 characters');
  });

  testWidgets('only the person picked is marked in the results', (
    tester,
  ) async {
    users.onSearchUsers = (_, _, _) async => pageOf(const [
      UserSummary(id: 'u_2', username: 'ana', displayName: 'Ana B'),
      UserSummary(id: 'u_3', username: 'anna'),
    ]);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Person'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(SendHouseholdInviteScreen.searchKey),
      'an',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    bool marked(String userId) => tester
        .widget<ListTile>(
          find.byKey(SendHouseholdInviteScreen.resultKey(userId)),
        )
        .selected;
    expect([marked('u_2'), marked('u_3')], [false, false]);

    await tester.tap(find.byKey(SendHouseholdInviteScreen.resultKey('u_2')));
    await tester.pumpAndSettle();
    expect([marked('u_2'), marked('u_3')], [true, false]);

    await tester.tap(find.byKey(SendHouseholdInviteScreen.resultKey('u_3')));
    await tester.pumpAndSettle();
    expect([marked('u_2'), marked('u_3')], [false, true]);
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
