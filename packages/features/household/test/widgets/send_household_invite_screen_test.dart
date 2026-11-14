import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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

const _onlineOnlyCopy = "Available when you're online";

void main() {
  late FakeHouseholdInviteRemote remote;
  late FakeUserRemote users;
  late int sent;
  late int memberSent;
  late int refreshes;
  late FakeSessionLease lease;

  setUp(() {
    remote = FakeHouseholdInviteRemote();
    users = FakeUserRemote();
    sent = 0;
    memberSent = 0;
    refreshes = 0;
    lease = FakeSessionLease();
  });

  Widget harness({
    HouseholdRole? viewerRole = HouseholdRole.householdOwner,
    MemberInvitePolicy? policy,
    Future<void> Function()? onRefresh,
    ValueListenable<bool>? offline,
    ThemeData? theme,
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    builder: offline == null
        ? null
        : (context, child) => ValueListenableBuilder<bool>(
            valueListenable: offline,
            child: child,
            builder: (context, isOffline, child) => BgeConnectivityScope(
              offline: isOffline,
              noticeShowing: isOffline,
              onlineOnlyReason: _onlineOnlyCopy,
              child: child!,
            ),
          ),
    localizationsDelegates: const [
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
      session: lease,
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

    testWidgets("a role no longer the viewer's to offer is unpicked when "
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
            'An owner or admin has to approve this invite before the person '
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
      ("a role the app doesn't know", HouseholdRole.unknown),
      ("a role the cache can't say", null),
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

  testWidgets('Send is disabled offline and says why, and offline leaves the '
      'form untouched', (tester) async {
    final offline = ValueNotifier(true);
    addTearDown(offline.dispose);
    await tester.pumpWidget(harness(offline: offline));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(SendHouseholdInviteScreen.emailKey),
      'not an address',
    );
    await tester.pump();

    final send = find.byKey(SendHouseholdInviteScreen.submitKey);
    await tester.ensureVisible(send);
    await tester.pump();
    expect(tester.widget<BgeSubmitButton>(send).onPressed, isNull);
    expect(
      tester.getSemantics(send),
      matchesSemantics(
        label: 'Send invite',
        hint: _onlineOnlyCopy,
        isButton: true,
        hasEnabledState: true,
      ),
    );
    expect(find.text(_onlineOnlyCopy), findsOneWidget);

    // A press sends nothing, and marks nothing touched, which would show
    // the address's error.
    await tester.tap(send, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(remote.sentDrafts, isEmpty);
    expect(find.text('Enter a valid email address.'), findsNothing);

    offline.value = false;
    await tester.pumpAndSettle();

    expect(tester.widget<BgeSubmitButton>(send).onPressed, isNotNull);
    expect(find.text(_onlineOnlyCopy), findsNothing);
    expect(find.text('Enter a valid email address.'), findsNothing);
    await submit(tester);
    await tester.pumpAndSettle();
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

  // #464: the send outlives the form. Left while it is under way, it still
  // says how it went, on the page the user went back to, and goes nowhere:
  // the user already has.
  group('left mid-send', () {
    late Completer<HouseholdInvite> answer;
    late SendHouseholdInviteBloc bloc;

    /// A page whose one button pushes the screen, as the household
    /// screen's Invite row does for a member whose household's invites
    /// await approval.
    Widget pushedHarness() => MaterialApp(
      theme: BgeTheme.light(),
      localizationsDelegates: const [
        ...HouseholdLocalizations.localizationsDelegates,
        UserSearchLocalizations.delegate,
      ],
      supportedLocales: HouseholdLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => SendHouseholdInviteScreen(
                  householdId: 'hh_1',
                  viewerRole: HouseholdRole.householdMember,
                  memberInvitePolicy: MemberInvitePolicy.needsApproval,
                  remote: remote,
                  users: users,
                  session: lease,
                  onSent: (_) => sent++,
                  onMemberSent: (_) => memberSent++,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    /// Sends an invite whose answer waits on [answer].
    Future<void> sendHeld(WidgetTester tester) async {
      answer = Completer<HouseholdInvite>();
      remote.onSend = (_, _) => answer.future;
      await tester.pumpWidget(pushedHarness());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      bloc = BlocProvider.of<SendHouseholdInviteBloc>(
        tester.element(find.byKey(SendHouseholdInviteScreen.submitKey)),
      );
      await tester.enterText(
        find.byKey(SendHouseholdInviteScreen.emailKey),
        'ana@example.com',
      );
      await submit(tester);
      expect(bloc.state, isA<SendHouseholdInviteSending>());
    }

    /// Sends an invite whose answer waits on [answer], then goes back while
    /// it is on its way.
    Future<void> sendThenLeave(WidgetTester tester) async {
      await sendHeld(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SendHouseholdInviteScreen), findsNothing);
    }

    Future<bool> closed(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      return bloc.isClosed;
    }

    Finder inSnackBar(String copy) =>
        find.descendant(of: find.byType(SnackBar), matching: find.text(copy));

    /// The page beneath is the only route: nothing was pushed or popped
    /// after the user went back.
    void expectStackUnchanged(WidgetTester tester) {
      expect(find.text('open'), findsOneWidget);
      expect(Navigator.of(tester.element(find.text('open'))).canPop(), false);
      expect(sent, 0);
      expect(memberSent, 0);
    }

    testWidgets('left mid-send, the outcome is still said', (tester) async {
      await sendThenLeave(tester);
      // Kept for the send still on its way.
      expect(await closed(tester), isFalse);

      answer.complete(
        invite('i_1', status: HouseholdInviteStatus.awaitingApproval),
      );
      await tester.pumpAndSettle();

      expect(inSnackBar('Sent for approval.'), findsOneWidget);
      expectStackUnchanged(tester);
      expect(await closed(tester), isTrue);
    });

    testWidgets('left mid-send, a failure is still said', (tester) async {
      await sendThenLeave(tester);

      answer.completeError(refused(409));
      await tester.pumpAndSettle();

      expect(inSnackBar("Couldn't send the invite"), findsOneWidget);
      expectStackUnchanged(tester);
      expect(await closed(tester), isTrue);
    });

    testWidgets('left mid-send, nothing is said once the session has ended', (
      tester,
    ) async {
      await sendThenLeave(tester);
      lease.isLive = false;

      answer.complete(invite('i_1'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expectStackUnchanged(tester);
      // Still closed: ending the session skips the message, not the close.
      expect(await closed(tester), isTrue);
    });

    // The shell ends a session in the same turn it routes away, and the
    // popped route stays mounted through its exit. A send that settles there
    // asks the lease (#694), is said as it would be once the form had gone,
    // and goes nowhere (#464).
    group("on the route's way out", () {
      /// Sends an invite whose answer waits on [answer], pops the form and,
      /// in the same turn when [endSession], ends the session, then pumps
      /// 50 ms into the exit.
      Future<void> sendThenPop(
        WidgetTester tester, {
        bool endSession = false,
      }) async {
        await sendHeld(tester);
        Navigator.of(
          tester.element(find.byKey(SendHouseholdInviteScreen.submitKey)),
        ).pop();
        if (endSession) lease.isLive = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(SendHouseholdInviteScreen), findsOneWidget);
      }

      /// Gives the answer, and lets it reach the form, still inside the exit.
      Future<void> settle(WidgetTester tester, {required bool fails}) async {
        if (fails) {
          answer.completeError(refused(409));
        } else {
          answer.complete(
            invite('i_1', status: HouseholdInviteStatus.awaitingApproval),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(SendHouseholdInviteScreen), findsOneWidget);
      }

      /// The keys of the bars showing: a bar said again is a new key.
      Set<Key?> barKeys(WidgetTester tester) => {
        for (final bar in tester.widgetList<SnackBar>(find.byType(SnackBar)))
          bar.key,
      };

      for (final (name, fails) in [('lands', false), ('fails', true)]) {
        testWidgets('a send that $name after the session ended says nothing, '
            'and the bloc still closes', (tester) async {
          await sendThenPop(tester, endSession: true);

          await settle(tester, fails: fails);
          expect(find.byType(SnackBar), findsNothing);
          await tester.pumpAndSettle();

          expect(find.byType(SnackBar), findsNothing);
          expectStackUnchanged(tester);
          expect(await closed(tester), isTrue);
        });
      }

      for (final (name, fails, copy) in [
        ('lands', false, 'Sent for approval.'),
        ('fails', true, "Couldn't send the invite"),
      ]) {
        testWidgets('a send that $name is said once, and goes nowhere', (
          tester,
        ) async {
          await sendThenPop(tester);

          await settle(tester, fails: fails);
          // One bar, drawn in both pages' scaffolds while the exit runs.
          expect(inSnackBar(copy), findsWidgets);
          final said = barKeys(tester);
          expect(said, hasLength(1));
          await tester.pumpAndSettle();

          expect(inSnackBar(copy), findsOneWidget);
          expect(barKeys(tester), said);
          expectStackUnchanged(tester);
          expect(await closed(tester), isTrue);
        });
      }
    });
  });

  group('accessibility audit', () {
    const member = HouseholdRole.householdMember;

    /// The screen as [viewerRole] and [policy] leave it, over the fakes as
    /// [seed] leaves them.
    Widget Function(ThemeData) screenWith({
      HouseholdRole? viewerRole = HouseholdRole.householdOwner,
      MemberInvitePolicy? policy,
      Future<void> Function()? onRefresh,
      ValueListenable<bool>? offline,
      void Function()? seed,
    }) => (theme) {
      seed?.call();
      return harness(
        viewerRole: viewerRole,
        policy: policy,
        onRefresh: onRefresh,
        offline: offline,
        theme: theme,
      );
    };

    final owner = screenWith();

    Future<void> typeEmail(WidgetTester tester, String email) async {
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(SendHouseholdInviteScreen.emailKey),
        email,
      );
      await tester.pumpAndSettle();
    }

    Future<void> rejectEmail(WidgetTester tester) async {
      await typeEmail(tester, 'not an address');
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      await scrollPageToTop(tester);
    }

    void refusing() => remote.onSend = (_, _) async => throw refused(409);

    Future<void> refusedSend(WidgetTester tester) async {
      await typeEmail(tester, 'ana@example.com');
      await submit(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(SendHouseholdInviteScreen.errorKey), findsOneWidget);
      await scrollPageToTop(tester);
    }

    Future<void> pickPerson(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await tester.tap(find.text('Person'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(SendHouseholdInviteScreen.searchKey),
        'ana',
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(SendHouseholdInviteScreen.resultKey('u_2')),
      );
      await tester.tap(find.byKey(SendHouseholdInviteScreen.resultKey('u_2')));
      await tester.pumpAndSettle();
    }

    void people() => users.onSearchUsers = (_, _, _) async => pageOf(const [
      UserSummary(id: 'u_2', username: 'ana', displayName: 'Ana B'),
      UserSummary(id: 'u_3', username: 'anabel'),
    ]);

    auditScreen(
      'ready',
      build: owner,
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsOneWidget);
      },
    );

    auditScreen(
      'member, needs approval',
      build: screenWith(
        viewerRole: member,
        policy: MemberInvitePolicy.needsApproval,
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(
          find.byKey(SendHouseholdInviteScreen.approvalNoteKey),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'person mode, picked',
      build: screenWith(seed: people),
      arrange: pickPerson,
    );

    auditScreen(
      'person mode, picked, scrolled to the end',
      build: screenWith(seed: people),
      arrange: (tester) async {
        await pickPerson(tester);
        await scrollPageToEnd(tester);
      },
    );

    auditScreen('rejected submit', build: owner, arrange: rejectEmail);

    auditScreen(
      'failure',
      build: screenWith(seed: refusing),
      arrange: refusedSend,
    );

    // The end of the page leaves the mode toggle or the address field half
    // under the top edge, which Flutter's tap-target check fails at its
    // clipped size (#50). These audit the states in a view with nothing below
    // the fold.
    auditScreen(
      'ready, whole page',
      build: owner,
      arrange: (tester) async {
        await useWholePage(tester);
        expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsOneWidget);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'rejected submit, whole page',
      build: owner,
      arrange: (tester) async {
        await useWholePage(tester);
        await rejectEmail(tester);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'failure, whole page',
      build: screenWith(seed: refusing),
      arrange: (tester) async {
        await useWholePage(tester);
        await refusedSend(tester);
        expectWholePage(tester);
      },
    );

    // The send never answers, so the button keeps spinning.
    auditScreen(
      'submitting',
      build: screenWith(
        seed: () {
          final answer = Completer<HouseholdInvite>();
          addTearDown(() => answer.complete(invite('i_1')));
          remote.onSend = (_, _) => answer.future;
        },
      ),
      arrange: (tester) async {
        await typeEmail(tester, 'ana@example.com');
        await submit(tester);
        await tester.pump();
        expect(
          tester
              .widget<BgeSubmitButton>(
                find.byKey(SendHouseholdInviteScreen.submitKey),
              )
              .submitting,
          isTrue,
        );
      },
      // The failing nodes are the mode segments and the Send button, all
      // disabled while the send is in flight and drawn dimmed by design;
      // WCAG 1.4.3 exempts inactive controls, and the enabled ones pass in
      // 'ready'.
      textContrast: false,
      settle: false,
    );

    auditScreen(
      'offline',
      build: screenWith(offline: ValueNotifier(true)),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.text(_onlineOnlyCopy), findsOneWidget);
      },
    );

    auditScreen(
      'not allowed, role unknown, with retry',
      build: screenWith(viewerRole: null, onRefresh: counted),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(notAllowed(_unknownCopy), findsOneWidget);
        expect(
          find.byKey(SendHouseholdInviteScreen.refreshKey),
          findsOneWidget,
        );
      },
    );

    // The read never ends, so the retry keeps saying it is refreshing.
    auditScreen(
      'not allowed, refreshing',
      build: screenWith(
        viewerRole: null,
        onRefresh: () => Completer<void>().future,
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(SendHouseholdInviteScreen.refreshKey));
        await tester.pump();
        expect(find.text('Refreshing\u{2026}'), findsWidgets);
      },
      settle: false,
    );

    auditScreen(
      'not allowed, members switched off',
      build: screenWith(viewerRole: member, policy: MemberInvitePolicy.off),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(
          find.byKey(SendHouseholdInviteScreen.notAllowedKey),
          findsOneWidget,
        );
        expect(find.byKey(SendHouseholdInviteScreen.submitKey), findsNothing);
      },
    );

    auditScreen(
      'not allowed, guest',
      build: screenWith(
        viewerRole: HouseholdRole.householdGuest,
        policy: MemberInvitePolicy.direct,
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(
          notAllowed("Guests can't invite people to this household."),
          findsOneWidget,
        );
      },
    );
  });
}
