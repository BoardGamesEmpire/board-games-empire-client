import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
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
    ThemeData? theme,
    TextScaler? textScaler,
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    builder: offline == null && textScaler == null
        ? null
        : (context, child) {
            var app = child!;
            if (offline != null) {
              final screen = app;
              app = ValueListenableBuilder<bool>(
                valueListenable: offline,
                child: screen,
                builder: (context, isOffline, child) => BgeConnectivityScope(
                  offline: isOffline,
                  noticeShowing: isOffline,
                  onlineOnlyReason: _onlineOnlyCopy,
                  child: child!,
                ),
              );
            }
            // Null leaves the scale to the test.
            if (textScaler == null) return app;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: app,
            );
          },
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

  group('accessibility audit', () {
    /// The screen over the fake as [seed] leaves it; `build` runs before the
    /// first read, so the state is chosen here.
    Widget Function(ThemeData, TextScaler) screenWith(
      void Function() seed, {
      ValueListenable<bool>? offline,
    }) => (theme, textScaler) {
      seed();
      return harness(offline: offline, theme: theme, textScaler: textScaler);
    };

    /// One of each row shape: pending, awaiting approval (Approve and Turn
    /// down), the viewer's own (Withdraw), and a settled one.
    void rows() => remote.listing([
      invite('i_1', inviteeName: 'Ana', role: HouseholdRole.householdGuest),
      invite('i_2', status: HouseholdInviteStatus.awaitingApproval),
      invite('i_3', inviterId: _me, inviteeEmail: 'b@c.d'),
      invite('i_4', status: HouseholdInviteStatus.accepted),
    ]);

    final ready = screenWith(rows);

    Future<void> shown(WidgetTester tester) async {
      await tester.pumpAndSettle();
    }

    testWidgets('the harness applies the theme and the text scale', (
      tester,
    ) async {
      rows();
      await tester.pumpWidget(
        harness(theme: BgeTheme.dark(), textScaler: const TextScaler.linear(2)),
      );
      await tester.pumpAndSettle();

      final screen = find.byType(HouseholdInviteListScreen);
      expect(MediaQuery.textScalerOf(tester.element(screen)).scale(10), 20);
      expect(Theme.of(tester.element(screen)).brightness, Brightness.dark);
    });

    auditScreen(
      'ready',
      build: ready,
      arrange: (tester) async {
        await shown(tester);
        expect(find.text('Ana'), findsOneWidget);
        expect(
          find.byKey(
            HouseholdInviteTile.actionKey(
              HouseholdInviteRowAction.approve,
              'i_2',
            ),
          ),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'ready, scrolled to the end',
      build: ready,
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
      // The nodes that fail are the disabled row buttons, whose label is
      // drawn dimmed by design; WCAG 1.4.3 exempts inactive controls, and the
      // enabled buttons pass in 'ready'.
      textContrast: false,
    );

    auditScreen(
      'more to load',
      build: screenWith(
        () => remote.onFetchHouseholdInvites = (_, _, page, limit) async =>
            pageOf(
              [for (var i = 0; i < 25; i++) invite('i_$i')],
              limit: limit,
              hasMore: true,
            ),
      ),
      arrange: (tester) async {
        await shown(tester);
        await scrollListToEnd(
          tester,
          find.byKey(HouseholdInviteListScreen.moreKey),
        );
      },
    );

    auditScreen(
      'empty',
      build: screenWith(() => remote.listing(const [])),
      arrange: (tester) async {
        await shown(tester);
        expect(find.byKey(HouseholdInviteListScreen.emptyKey), findsOneWidget);
      },
    );

    auditScreen(
      'denied',
      build: screenWith(
        () =>
            remote.onFetchHouseholdInvites = (_, _, _, _) async =>
                throw refused(403),
      ),
      arrange: (tester) async {
        await shown(tester);
        expect(find.byKey(HouseholdInviteListScreen.deniedKey), findsOneWidget);
      },
    );

    auditScreen(
      'failure',
      build: screenWith(
        () =>
            remote.onFetchHouseholdInvites = (_, _, _, _) async =>
                throw offline(),
      ),
      arrange: (tester) async {
        await shown(tester);
        expect(find.byKey(HouseholdInviteListScreen.failedKey), findsOneWidget);
      },
    );

    auditScreen(
      'refused action',
      build: screenWith(() {
        remote
          ..listing([
            invite('i_1', status: HouseholdInviteStatus.awaitingApproval),
          ])
          ..onApprove = (_, _) async => throw refused(403);
      }),
      arrange: (tester) async {
        await shown(tester);
        await tester.tap(
          find.byKey(
            HouseholdInviteTile.actionKey(
              HouseholdInviteRowAction.approve,
              'i_1',
            ),
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
      },
    );

    // The first read never answers, so the spinner never stops.
    auditScreen(
      'loading',
      build: screenWith(() {
        final read = Completer<PaginatedResult<HouseholdInvite>>();
        addTearDown(() => read.complete(pageOf(const <HouseholdInvite>[])));
        remote.onFetchHouseholdInvites = (_, _, _, _) => read.future;
      }),
      arrange: (tester) async {
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsWidgets);
      },
      settle: false,
    );
  });
}
