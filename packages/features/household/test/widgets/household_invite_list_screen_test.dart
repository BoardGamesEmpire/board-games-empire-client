import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import '../support/invite_filter_menu_support.dart';

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
    HouseholdInviteFilter initialFilter = HouseholdInviteFilter.open,
    void Function(BuildContext context)? onInvite,
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
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    home: HouseholdInviteListScreen(
      householdId: householdId,
      remote: remote,
      repository: repository,
      initialFilter: initialFilter,
      onInvite: onInvite,
    ),
  );

  /// What the filter control says is chosen.
  String chosen(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byKey(HouseholdInviteListScreen.filterKey),
          matching: find.byType(Text),
        ),
      )
      .data!;

  /// Opens the filter menu and picks [label] from it.
  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(HouseholdInviteListScreen.filterKey));
    await tester.pumpAndSettle();
    // The menu builds its entries only while it is open, so this fails if
    // the tap did not open it.
    await tester.tap(find.widgetWithText(MenuItemButton, label).hitTestable());
    await tester.pumpAndSettle();
  }

  testWidgets('every row is outlined (#647)', (tester) async {
    remote.listing([invite('i_1'), invite('i_2')]);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byType(BgeOutlinedRow), findsNWidgets(2));
  });

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
    for (final MapEntry(:key, value: label) in buttons.entries) {
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

    await choose(tester, 'Awaiting approval');

    expect(
      remote.calls.last,
      'fetchHouseholdInvites(hh_1, awaitingApproval, 1, 25)',
    );
    expect(chosen(tester), 'Show: Awaiting approval');
    expect(find.text('No invites are awaiting approval.'), findsOneWidget);
  });

  testWidgets('the declined filter reads that status (#475)', (tester) async {
    remote.listing(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await choose(tester, 'Declined');

    expect(remote.calls.last, 'fetchHouseholdInvites(hh_1, declined, 1, 25)');
    expect(chosen(tester), 'Show: Declined');
    expect(
      find.descendant(
        of: find.byKey(HouseholdInviteListScreen.emptyKey),
        matching: find.text('No declined invites.'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a declined row says so and offers no action (#475)', (
    tester,
  ) async {
    // An owner, and the viewer's own invite: either would be offered an
    // action on an outstanding one.
    remote.listing([
      invite('i_1', status: HouseholdInviteStatus.declined),
      invite('i_2', status: HouseholdInviteStatus.declined, inviterId: _me),
    ]);
    await tester.pumpWidget(
      harness(initialFilter: HouseholdInviteFilter.declined),
    );
    await tester.pumpAndSettle();

    for (final id in ['i_1', 'i_2']) {
      final row = find.byKey(HouseholdInviteListScreen.rowKey(id));
      expect(
        find.descendant(of: row, matching: find.text('Declined')),
        findsOneWidget,
        reason: id,
      );
      expect(
        find.descendant(of: row, matching: find.byType(ButtonStyleButton)),
        findsNothing,
        reason: id,
      );
    }
  });

  testWidgets('choosing the filter already chosen reads nothing', (
    tester,
  ) async {
    remote.listing(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    final reads = remote.calls.length;

    await choose(tester, 'Open');

    expect(remote.calls.length, reads);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(chosen(tester), 'Show: Open');
  });

  testWidgets('the open menu tells assistive tech which filter is chosen', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    remote.listing(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(HouseholdInviteListScreen.filterKey));
    await tester.pumpAndSettle();

    SemanticsNode entry(String label) => tester.getSemantics(
      find.widgetWithText(MenuItemButton, label).hitTestable(),
    );
    expect(
      entry('Open'),
      isSemantics(label: 'Open', hasSelectedState: true, isSelected: true),
    );
    for (final label in ['Awaiting approval', 'Declined']) {
      expect(
        entry(label),
        isSemantics(label: label, hasSelectedState: true, isSelected: false),
        reason: label,
      );
    }

    // Dispose inline: flutter_test checks for an open SemanticsHandle when
    // the body ends, before tearDown callbacks run.
    handle.dispose();
  });

  testWidgets('the filter tells assistive tech whether its menu is open', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    remote.listing(const []);
    await tester.pumpWidget(
      harness(initialFilter: HouseholdInviteFilter.declined),
    );
    await tester.pumpAndSettle();
    final control = find.byKey(HouseholdInviteListScreen.filterKey);

    expect(
      tester.getSemantics(control),
      isSemantics(
        label: 'Show: Declined',
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

  testWidgets('the filter menu works from the keyboard, over rows with '
      'actions (#475)', (tester) async {
    // An owner, so each row offers Revoke: the arrows must not reach them
    // under the open menu.
    remote.listing([invite('i_1'), invite('i_2')]);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    final button = find.byKey(HouseholdInviteListScreen.filterKey);
    Finder item(String label) => find.widgetWithText(MenuItemButton, label);
    await tabTo(tester, button);

    // Enter opens it, on the filter chosen now.
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.byType(MenuItemButton), findsNWidgets(3));
    expect(focusIn(item('Open')), isTrue);

    // Down moves through the choices, and Enter picks one and closes it,
    // with focus back on the button.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn(item('Awaiting approval')), isTrue);
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(
      remote.calls.last,
      'fetchHouseholdInvites(hh_1, awaitingApproval, 1, 25)',
    );
    expect(chosen(tester), 'Show: Awaiting approval');
    expect(focusIn(button), isTrue);

    // Open again: Tab stays in the menu, and Escape closes it, with focus
    // back on the button and nothing asked for.
    remote.listing([invite('i_1'), invite('i_2')]);
    await press(tester, LogicalKeyboardKey.enter);
    expect(focusIn(item('Awaiting approval')), isTrue);
    await press(tester, LogicalKeyboardKey.tab);
    expect(focusIn(find.byType(MenuItemButton)), isTrue);
    final reads = remote.calls.length;
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(focusIn(button), isTrue);
    expect(remote.calls.length, reads);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('the filter stays enabled offline', (tester) async {
    final offline = ValueNotifier(true);
    addTearDown(offline.dispose);
    remote.listing(const []);
    await tester.pumpWidget(harness(offline: offline));
    await tester.pumpAndSettle();

    // Choosing what to list is no write.
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(HouseholdInviteListScreen.filterKey),
          )
          .onPressed,
      isNotNull,
    );
  });

  // At the default text scale, and at BgeTextScale.maxScaleFactor, the
  // largest the shell lets through.
  for (final scale in [1.0, BgeTextScale.maxScaleFactor]) {
    testWidgets('the filter fits a 320-wide screen at text scale $scale '
        '(#475)', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      remote.listing(const []);
      await tester.pumpWidget(
        harness(initialFilter: HouseholdInviteFilter.awaitingApproval),
      );
      await tester.pumpAndSettle();

      final label = find.descendant(
        of: find.byKey(HouseholdInviteListScreen.filterKey),
        matching: find.text('Show: Awaiting approval'),
      );
      expect(
        MediaQuery.textScalerOf(tester.element(label)).scale(10),
        10 * scale,
        reason: 'the control is drawn at the scale under test',
      );
      // The chosen filter wraps inside the control rather than being cut.
      final control = tester.getRect(
        find.byKey(HouseholdInviteListScreen.filterKey),
      );
      expect(
        tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
        isFalse,
      );
      expect(control.intersect(tester.getRect(label)), tester.getRect(label));
      // Every glyph of the test font is an em wide, so whether a word
      // breaks is checked in the platform's own face, in
      // household_invite_list_screen_filter_fit_test.dart.

      await tester.tap(find.byKey(HouseholdInviteListScreen.filterKey));
      await tester.pumpAndSettle();
      // Its entries wrap within the control's width too, rather than
      // widening the menu past the screen's edge, where it clips them.
      for (final choice in ['Open', 'Awaiting approval', 'Declined']) {
        final entry = find.widgetWithText(MenuItemButton, choice);
        expect(entry.hitTestable(), findsOneWidget, reason: choice);
        final words = find.descendant(of: entry, matching: find.text(choice));
        final text = tester.getRect(words);
        expect(text.left, greaterThanOrEqualTo(control.left), reason: choice);
        expect(text.right, lessThanOrEqualTo(control.right), reason: choice);
      }

      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('starts on awaitingApproval when asked (#475)', (tester) async {
    remote.listing(const []);

    await tester.pumpWidget(
      harness(initialFilter: HouseholdInviteFilter.awaitingApproval),
    );
    await tester.pumpAndSettle();

    expect(remote.calls, [
      'fetchHouseholdInvites(hh_1, awaitingApproval, 1, 25)',
    ]);
    expect(chosen(tester), 'Show: Awaiting approval');
  });

  testWidgets('starts on declined when asked (#475)', (tester) async {
    remote.listing(const []);

    await tester.pumpWidget(
      harness(initialFilter: HouseholdInviteFilter.declined),
    );
    await tester.pumpAndSettle();

    expect(remote.calls, ['fetchHouseholdInvites(hh_1, declined, 1, 25)']);
    expect(chosen(tester), 'Show: Declined');
  });

  testWidgets('a different opening filter is a new list (#475)', (
    tester,
  ) async {
    // The route's page key is its path pattern, so a link to the same
    // household's other filter reuses this State; the filter keys the bloc.
    remote.listing(const []);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      harness(initialFilter: HouseholdInviteFilter.awaitingApproval),
    );
    await tester.pumpAndSettle();

    expect(
      remote.calls.last,
      'fetchHouseholdInvites(hh_1, awaitingApproval, 1, 25)',
    );
    expect(chosen(tester), 'Show: Awaiting approval');
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
    // Each row now takes 8dp more (#647), which leaves the button in the
    // cache extent, not on screen, where the scroll stops.
    await tester.ensureVisible(find.byKey(HouseholdInviteListScreen.moreKey));
    await tester.pumpAndSettle();
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
    /// first read, so the state is chosen here. With an Invite action, as the
    /// shell gives an owner, so its button is audited too.
    Widget Function(ThemeData) screenWith(
      void Function() seed, {
      ValueListenable<bool>? offline,
    }) => (theme) {
      seed();
      return harness(offline: offline, theme: theme, onInvite: (_) {});
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

    auditScreen(
      'ready',
      build: ready,
      arrange: (tester) async {
        await shown(tester);
        expect(find.byKey(HouseholdInviteListScreen.inviteKey), findsOneWidget);
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
    );

    auditScreen(
      'more to load',
      build: screenWith(
        () =>
            remote.onFetchHouseholdInvites = (_, _, page, limit) async =>
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
      'filter menu open',
      build: ready,
      arrange: (tester) async {
        await shown(tester);
        await tester.tap(find.byKey(HouseholdInviteListScreen.filterKey));
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNWidgets(3));
      },
    );

    auditScreen(
      'declined',
      build: screenWith(
        () => remote.listing([
          invite('i_1', status: HouseholdInviteStatus.declined),
        ]),
      ),
      arrange: (tester) async {
        await shown(tester);
        await choose(tester, 'Declined');
        expect(find.text('Show: Declined'), findsOneWidget);
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
        // At 320dp × 2.0 the row's Approve sits under the Invite button until
        // the page is scrolled to its end, which leaves the button room.
        await scrollPageToEnd(tester);
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
