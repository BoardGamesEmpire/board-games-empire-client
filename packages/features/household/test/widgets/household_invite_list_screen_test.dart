import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_household_invite_remote.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

const _me = 'u_me';
const _onlineOnlyCopy = "Available when you're online";

HouseholdMember _member(HouseholdRole role, {String householdId = 'hh_1'}) =>
    HouseholdMember(
      id: 'm_me',
      userId: _me,
      householdId: householdId,
      role: role,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

void main() {
  late FakeHouseholdInviteRemote remote;
  late _MockHouseholdRepository repository;

  setUp(() {
    remote = FakeHouseholdInviteRemote();
    repository = _MockHouseholdRepository();
    when(() => repository.getCurrentUserMember(any()))
        .thenAnswer((_) async => _member(HouseholdRole.householdOwner));
  });

  Widget harness({
    String householdId = 'hh_1',
    void Function(BuildContext context)? onInvite,
    ValueListenable<bool>? offline,
  }) => MaterialApp(
    theme: BgeTheme.light(),
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
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    home: HouseholdInviteListScreen(
      householdId: householdId,
      remote: remote,
      repository: repository,
      onInvite: onInvite,
    ),
  );

  testWidgets('a row shows who it is for, the role and who sent it', (
    tester,
  ) async {
    remote.listing([
      invite('i_1', inviteeName: 'Ana', role: HouseholdRole.householdGuest),
      invite('i_2', inviteeEmail: 'b@c.d').copyWith(inviteeName: null),
    ]);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('Guest'), findsOneWidget);
    expect(find.text('b@c.d'), findsOneWidget);
    expect(find.text('Invited by u_other'), findsNWidgets(2));
    expect(find.text('Expires Oct 26, 2026'), findsNWidgets(2));
  });

  testWidgets('Withdraw on your own invite withdraws it, unasked', (
    tester,
  ) async {
    remote
      ..listing([invite('i_1', inviterId: _me)])
      ..onWithdraw = (id) async =>
          invite(id, inviterId: _me, status: HouseholdInviteStatus.withdrawn);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        HouseholdInviteTile.actionKey(HouseholdInviteRowAction.withdraw, 'i_1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(remote.calls.last, 'withdraw(i_1)');
    expect(find.text('Invite withdrawn.'), findsOneWidget);
  });

  testWidgets('Turn down asks first, then revokes', (tester) async {
    remote
      ..listing([invite('i_1', status: HouseholdInviteStatus.awaitingApproval)])
      ..onRevoke = (_, id) async =>
          invite(id, status: HouseholdInviteStatus.revoked);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final turnDown = find.byKey(
      HouseholdInviteTile.actionKey(HouseholdInviteRowAction.revoke, 'i_1'),
    );
    expect(
      find.descendant(of: turnDown, matching: find.text('Turn down')),
      findsOneWidget,
    );
    await tester.tap(turnDown);
    await tester.pumpAndSettle();
    expect(find.text('Turn down this invite?'), findsOneWidget);
    expect(remote.calls.where((c) => c.startsWith('revoke')), isEmpty);

    await tester.tap(find.byKey(HouseholdInviteListScreen.confirmKey));
    await tester.pumpAndSettle();

    expect(remote.calls.last, 'revoke(hh_1, i_1)');
    expect(find.text('Invite revoked.'), findsOneWidget);
  });

  testWidgets('a refused action says why, in the banner', (tester) async {
    remote
      ..listing([invite('i_1', status: HouseholdInviteStatus.awaitingApproval)])
      ..onApprove = (_, _) async => throw refused(403);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        HouseholdInviteTile.actionKey(HouseholdInviteRowAction.approve, 'i_1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        "You can't do this any more. Your role in the household may have "
        'changed.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('online, each row keeps the padding its buttons had before the '
      'offline note', (tester) async {
    remote.listing([
      invite('i_1', status: HouseholdInviteStatus.awaitingApproval),
    ]);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final wrap = find.byType(Wrap);
    final padding = find
        .ancestor(of: wrap, matching: find.byType(Padding))
        .first;
    // Only the 8dp bottom inset, no gap for a note.
    expect(tester.getSize(padding).height - tester.getSize(wrap).height, 8.0);
  });

  testWidgets('Approve, Turn down, Revoke and Withdraw are disabled offline '
      'and say why', (tester) async {
    final offline = ValueNotifier(true);
    addTearDown(offline.dispose);
    remote.listing([
      invite('i_1', status: HouseholdInviteStatus.awaitingApproval),
      invite('i_2', inviterId: _me),
      invite('i_3'),
    ]);
    await tester.pumpWidget(harness(offline: offline));
    await tester.pumpAndSettle();

    final buttons = {
      HouseholdInviteTile.actionKey(HouseholdInviteRowAction.approve, 'i_1'):
          'Approve',
      HouseholdInviteTile.actionKey(HouseholdInviteRowAction.revoke, 'i_1'):
          'Turn down',
      HouseholdInviteTile.actionKey(HouseholdInviteRowAction.withdraw, 'i_2'):
          'Withdraw',
      HouseholdInviteTile.actionKey(HouseholdInviteRowAction.revoke, 'i_3'):
          'Revoke',
    };
    for (final MapEntry(key: key, value: label) in buttons.entries) {
      final button = find.byKey(key);
      expect(button, findsOneWidget, reason: label);
      await tester.ensureVisible(button);
      await tester.pump();
      expect(
        tester.widget<ButtonStyleButton>(button).onPressed,
        isNull,
        reason: label,
      );
      expect(
        tester.getSemantics(button),
        matchesSemantics(
          label: label,
          hint: _onlineOnlyCopy,
          isButton: true,
          hasEnabledState: true,
        ),
        reason: label,
      );
    }
    // Once under each row's buttons, not once a button.
    expect(find.text(_onlineOnlyCopy), findsNWidgets(3));

    offline.value = false;
    await tester.pumpAndSettle();

    expect(find.text(_onlineOnlyCopy), findsNothing);
    for (final key in buttons.keys) {
      expect(
        tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed,
        isNotNull,
      );
    }
  });

  testWidgets('the empty, denied and failed states', (tester) async {
    remote.listing(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.byKey(HouseholdInviteListScreen.emptyKey), findsOneWidget);

    remote.onFetchHouseholdInvites = (_, _, _, _) async => throw refused(403);
    await tester.pumpWidget(harness(householdId: 'hh_2'));
    await tester.pumpAndSettle();
    expect(find.byKey(HouseholdInviteListScreen.deniedKey), findsOneWidget);

    remote.onFetchHouseholdInvites = (_, _, _, _) async => throw offline();
    await tester.pumpWidget(harness(householdId: 'hh_3'));
    await tester.pumpAndSettle();
    expect(find.byKey(HouseholdInviteListScreen.failedKey), findsOneWidget);
  });

  testWidgets('the awaiting-approval filter reads that status', (tester) async {
    remote.listing(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Awaiting approval'));
    await tester.pumpAndSettle();

    expect(
      remote.calls.last,
      'fetchHouseholdInvites(hh_1, awaitingApproval, 1, 25)',
    );
    expect(find.text('No invites are awaiting approval.'), findsOneWidget);
  });

  testWidgets('Load more reads the next page', (tester) async {
    remote.onFetchHouseholdInvites = (_, _, page, limit) async => page == 1
        ? pageOf(
            [for (var i = 0; i < 25; i++) invite('i_$i')],
            limit: limit,
            hasMore: true,
          )
        : pageOf([invite('i_last')], page: page, limit: limit);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(HouseholdInviteListScreen.moreKey),
      200,
    );
    await tester.tap(find.byKey(HouseholdInviteListScreen.moreKey));
    await tester.pumpAndSettle();

    expect(remote.calls.last, 'fetchHouseholdInvites(hh_1, null, 2, 25)');
  });

  group('the invite button', () {
    testWidgets('shows for an owner when there is somewhere to go', (
      tester,
    ) async {
      remote.listing(const []);
      var opened = 0;
      await tester.pumpWidget(harness(onInvite: (_) => opened++));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(HouseholdInviteListScreen.inviteKey));
      expect(opened, 1);
    });

    testWidgets('is hidden with nowhere to go', (tester) async {
      remote.listing(const []);
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      expect(find.byKey(HouseholdInviteListScreen.inviteKey), findsNothing);
    });

    testWidgets('is hidden from a member', (tester) async {
      when(() => repository.getCurrentUserMember(any()))
          .thenAnswer((_) async => _member(HouseholdRole.householdMember));
      remote.listing(const []);
      await tester.pumpWidget(harness(onInvite: (_) {}));
      await tester.pumpAndSettle();

      expect(find.byKey(HouseholdInviteListScreen.inviteKey), findsNothing);
    });
  });

  testWidgets('a new household id reads the new household (#466)', (
    tester,
  ) async {
    remote.onFetchHouseholdInvites = (hh, _, _, _) async =>
        pageOf([invite('row_of_$hh', inviteeName: 'For $hh')]);
    await tester.pumpWidget(harness(householdId: 'hh_a'));
    await tester.pumpAndSettle();
    expect(find.text('For hh_a'), findsOneWidget);

    await tester.pumpWidget(harness(householdId: 'hh_b'));
    await tester.pumpAndSettle();

    expect(remote.calls.last, 'fetchHouseholdInvites(hh_b, null, 1, 25)');
    expect(find.text('For hh_b'), findsOneWidget);
    expect(find.text('For hh_a'), findsNothing);
  });
}
