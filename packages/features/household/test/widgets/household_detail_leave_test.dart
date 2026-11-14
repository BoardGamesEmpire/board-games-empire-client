import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockMemberRemote extends Mock
    implements HouseholdMemberRemoteDataSource {}

const _id = 'h-1';

Household _household(
  String id, {
  String name = 'Sunday Crew',
  String? description,
}) => Household(
  id: id,
  name: name,
  description: description,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

HouseholdMember _member(
  String userId, {
  HouseholdRole? role = HouseholdRole.householdMember,
  String? username,
  String? displayName,
}) => HouseholdMember(
  id: 'm-$userId',
  userId: userId,
  householdId: _id,
  role: role,
  username: username,
  displayName: displayName,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

const _onlineOnlyCopy = "Available when you're online";
const _leaveCopy = 'Leave household';
const _leavingCopy = 'Leaving\u{2026}';
const _lastOwnerCopy = 'Make another member the owner first.';
const _onlyMemberCopy = "You're the only member.";
const _beneathCopy = 'The page beneath';

final HouseholdMember _owner = _member(
  'u-me',
  role: HouseholdRole.householdOwner,
);
final HouseholdMember _coOwner = _member(
  'u-2',
  role: HouseholdRole.householdOwner,
  displayName: 'Zed',
);
final HouseholdMember _zed = _member('u-2', displayName: 'Zed');

/// Pins the Leave row on the household detail screen (#479): who is offered
/// it, why it is disabled, its confirmation, the request it sends, and what
/// the screen does with each answer.
void main() {
  late _MockHouseholdRepository repository;
  late _MockMemberRemote remote;
  late StreamController<List<Household>> households;
  late StreamController<List<HouseholdMember>> members;
  late HouseholdHydrationStatus status;
  late int backs;
  late int refreshes;
  late FakeSessionLease lease;

  setUp(() {
    repository = _MockHouseholdRepository();
    remote = _MockMemberRemote();
    households = StreamController<List<Household>>.broadcast();
    members = StreamController<List<HouseholdMember>>.broadcast();
    status = HouseholdHydrationStatus();
    backs = 0;
    refreshes = 0;
    lease = FakeSessionLease();
    when(repository.watchHouseholds).thenAnswer((_) => households.stream);
    when(() => repository.watchMembers(any()))
        .thenAnswer((_) => members.stream);
    when(() => repository.getCurrentUserMember(any()))
        .thenAnswer((_) async => _member('u-me'));
    when(() => repository.removeCachedMember(any(), any()))
        .thenAnswer((_) async {});
  });

  tearDown(() {
    unawaited(households.close());
    unawaited(members.close());
    unawaited(status.close());
  });

  Widget harness({
    void Function(BuildContext context)? onBack,
    TextScaler? textScaler,
    ThemeData? theme,
    void Function(BuildContext context, String householdId)? onNewEvent,
    HouseholdMemberRemoteDataSource? members,
    Future<void> Function()? onMembershipChanged,
    ValueListenable<bool>? offline,
    bool pushed = false,
  }) {
    final detail = HouseholdDetailScreen(
      householdId: _id,
      repository: repository,
      session: lease,
      hydration: status.watch(),
      onBack: onBack,
      onNewEvent: onNewEvent,
      members: members,
      onMembershipChanged: onMembershipChanged,
    );
    return MaterialApp(
      theme: theme ?? BgeTheme.light(),
      localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
      supportedLocales: HouseholdLocalizations.supportedLocales,
      builder: (context, child) {
        // No scale of its own unless asked: an audit cell sets the view's.
        final app = textScaler == null
            ? child!
            : MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: child!,
              );
        if (offline == null) return app;
        // As the shell hosts it, above the navigator, so dialogs read it too.
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
      // Pushed, the screen is a route of its own over a page, as the app has
      // it over the household list.
      home: pushed ? null : detail,
      routes: pushed
          ? {
              '/': (_) => const Scaffold(body: Text(_beneathCopy)),
              '/household': (_) => detail,
            }
          : const {},
      initialRoute: pushed ? '/household' : null,
    );
  }

  /// Everything Leave needs: a member client, its refresh, and a way back.
  Widget withLeave({
    TextScaler? textScaler,
    ThemeData? theme,
    ValueListenable<bool>? offline,
    void Function(BuildContext context, String householdId)? onNewEvent,
  }) => harness(
    onBack: (_) => backs++,
    textScaler: textScaler,
    theme: theme,
    onNewEvent: onNewEvent,
    members: remote,
    onMembershipChanged: () async => refreshes++,
    offline: offline,
  );

  /// Lands the household plus its roster and lets the identity future
  /// resolve, which is the ordinary "screen has loaded" position.
  Future<void> settleWith(
    WidgetTester tester, {
    Household? household,
    List<HouseholdMember>? roster,
  }) async {
    households.add([household ?? _household(_id)]);
    members.add(roster ?? [_member('u-me')]);
    await tester.pumpAndSettle();
  }

  Finder leaveRow() => find.byKey(HouseholdDetailScreen.leaveKey);

  ListTile leaveTile(WidgetTester tester) =>
      tester.widget<ListTile>(leaveRow());

  Finder inRow(String text) =>
      find.descendant(of: leaveRow(), matching: find.text(text));

  Finder confirm() => find.byKey(HouseholdDetailScreen.leaveConfirmKey);

  Finder failure() => find.byKey(HouseholdDetailScreen.leaveFailureKey);

  Finder inFailure(String text) =>
      find.descendant(of: failure(), matching: find.text(text));

  BgeBannerTone toneOf(WidgetTester tester) =>
      tester.widget<BgeInlineBanner>(failure()).tone;

  Future<void> openLeave(WidgetTester tester) async {
    await tester.ensureVisible(leaveRow());
    await tester.pumpAndSettle();
    await tester.tap(leaveRow());
    await tester.pumpAndSettle();
  }

  /// Confirms against a request that has not answered. It cannot settle: the
  /// row's spinner animates until the reply lands.
  Future<void> confirmPending(WidgetTester tester) async {
    await openLeave(tester);
    await tester.tap(confirm());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> confirmLeave(WidgetTester tester) async {
    await openLeave(tester);
    await tester.tap(confirm());
    await tester.pumpAndSettle();
  }

  /// Pumps past a 200's pop. It cannot settle: a counting `onBack` never
  /// takes the route away, and the held row's spinner animates until it
  /// goes.
  Future<void> pumpPastLeft(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Whether the primary focus is inside [finder].
  bool focusedIn(Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    return find
        .descendant(
          of: finder,
          matching: find.byElementPredicate((e) => identical(e, focused)),
        )
        .evaluate()
        .isNotEmpty;
  }

  /// Whether the primary focus is the row's own.
  bool rowFocused() => focusedIn(leaveRow());

  /// From the keyboard alone: Tabs to the Leave row, presses it and
  /// confirms.
  Future<void> leaveFromKeyboard(WidgetTester tester) async {
    for (var i = 0; i < 5 && !rowFocused(); i++) {
      await press(tester, LogicalKeyboardKey.tab);
    }
    expect(rowFocused(), isTrue);
    await press(tester, LogicalKeyboardKey.enter);
    expect(confirm(), findsOneWidget);
    // The first Tab lands on Cancel, the second on the confirm button.
    await press(tester, LogicalKeyboardKey.tab);
    await press(tester, LogicalKeyboardKey.tab);
    await press(tester, LogicalKeyboardKey.enter);
    expect(confirm(), findsNothing);
  }

  group('who is offered Leave', () {
    testWidgets('every role is offered Leave', (tester) async {
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_owner, _coOwner]);

      for (final role in [
        HouseholdRole.householdOwner,
        HouseholdRole.householdAdmin,
        HouseholdRole.householdMember,
        HouseholdRole.householdGuest,
      ]) {
        // Beside another owner, so even an owner may go.
        members.add([_member('u-me', role: role), _coOwner]);
        await tester.pumpAndSettle();

        expect(leaveRow(), findsOneWidget, reason: role.name);
        expect(leaveTile(tester).enabled, isTrue, reason: role.name);
        expect(inRow(_leaveCopy), findsOneWidget, reason: role.name);
        expect(leaveTile(tester).subtitle, isNull, reason: role.name);
      }
    });

    testWidgets('the row comes last, after New event, in the error colour', (
      tester,
    ) async {
      await tester.pumpWidget(withLeave(onNewEvent: (_, _) {}));
      await settleWith(tester, roster: [_member('u-me'), _coOwner]);

      final newEvent = find.byKey(HouseholdDetailScreen.newEventKey);
      expect(newEvent, findsOneWidget);
      expect(
        tester.getTopLeft(leaveRow()).dy,
        greaterThan(tester.getBottomLeft(newEvent).dy),
      );

      final error = BgeTheme.light().colorScheme.error;
      final icon = find.descendant(
        of: leaveRow(),
        matching: find.byIcon(Icons.logout),
      );
      expect(icon, findsOneWidget);
      expect(IconTheme.of(tester.element(icon)).color, error);
      expect(
        tester
            .renderObject<RenderParagraph>(inRow(_leaveCopy))
            .text
            .style
            ?.color,
        error,
      );
    });

    testWidgets(
      'no Leave without a member client, without onBack, or for a local-only '
      'household',
      (tester) async {
        final roster = [_member('u-me'), _coOwner];

        // No member client, so no bloc to leave with.
        await tester.pumpWidget(harness(onBack: (_) => backs++));
        await settleWith(tester, roster: roster);
        expect(find.text('Sunday Crew'), findsOneWidget);
        expect(leaveRow(), findsNothing);

        // A member client without its refresh is no member client.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          harness(onBack: (_) => backs++, members: remote),
        );
        await settleWith(tester, roster: roster);
        expect(find.text('Sunday Crew'), findsOneWidget);
        expect(leaveRow(), findsNothing);

        // Nowhere to go once it has left.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          harness(members: remote, onMembershipChanged: () async {}),
        );
        await settleWith(tester, roster: roster);
        expect(find.text('Sunday Crew'), findsOneWidget);
        expect(leaveRow(), findsNothing);

        // The server does not know the household yet.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(withLeave());
        await settleWith(
          tester,
          household: _household(_id).copyWith(isLocalOnly: true),
          roster: roster,
        );
        expect(find.text('Sunday Crew'), findsOneWidget);
        expect(leaveRow(), findsNothing);
      },
    );
  });

  group('why Leave is disabled', () {
    testWidgets('the last owner sees Leave disabled with the reason', (
      tester,
    ) async {
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_owner, _zed]);

      expect(leaveTile(tester).enabled, isFalse);
      expect(inRow(_leaveCopy), findsOneWidget);
      expect(inRow(_lastOwnerCopy), findsOneWidget);
      // One node, read with its reason, that doesn't offer a focus it can't
      // take.
      expect(
        tester.getSemantics(leaveRow()),
        isSemantics(
          label: '$_leaveCopy\n$_lastOwnerCopy',
          hasEnabledState: true,
          isEnabled: false,
          isFocusable: false,
          hasFocusAction: false,
        ),
      );

      // The tile's own disabled look, not the error colour, for the title.
      expect(
        tester
            .renderObject<RenderParagraph>(inRow(_leaveCopy))
            .text
            .style
            ?.color,
        BgeTheme.light().disabledColor,
      );
      // The reason stays legible on the disabled row, at the online-only
      // reason's size.
      final reasonStyle = tester
          .renderObject<RenderParagraph>(inRow(_lastOwnerCopy))
          .text
          .style;
      expect(reasonStyle?.color, BgeTheme.light().colorScheme.onSurfaceVariant);
      expect(
        reasonStyle?.fontSize,
        Theme.of(tester.element(leaveRow())).textTheme.bodySmall?.fontSize,
      );

      await tester.tap(leaveRow(), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(confirm(), findsNothing);
    });

    testWidgets("an owner alone sees You're the only member", (tester) async {
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_owner]);

      expect(leaveTile(tester).enabled, isFalse);
      expect(inRow(_onlyMemberCopy), findsOneWidget);
      expect(inRow(_lastOwnerCopy), findsNothing);
    });

    testWidgets('a co-owner leaving elsewhere disables Leave live', (
      tester,
    ) async {
      final amy = _member('u-3', displayName: 'Amy');
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_owner, _coOwner, amy]);
      expect(leaveTile(tester).enabled, isTrue);
      expect(inRow(_lastOwnerCopy), findsNothing);

      // Zed leaves on another device, and the next hydrate says so.
      members.add([_owner, amy]);
      await tester.pumpAndSettle();

      expect(leaveTile(tester).enabled, isFalse);
      expect(inRow(_lastOwnerCopy), findsOneWidget);
    });

    group('offline (#49)', () {
      late ValueNotifier<bool> offline;

      setUp(() => offline = ValueNotifier(true));

      tearDown(() => offline.dispose());

      testWidgets('offline, Leave is disabled with the online-only reason', (
        tester,
      ) async {
        await tester.pumpWidget(withLeave(offline: offline));
        await settleWith(tester, roster: [_member('u-me'), _coOwner]);

        expect(leaveTile(tester).enabled, isFalse);
        expect(inRow(_onlineOnlyCopy), findsOneWidget);
        expect(
          tester.getSemantics(leaveRow()),
          isSemantics(
            label: '$_leaveCopy\n$_onlineOnlyCopy',
            hasEnabledState: true,
            isEnabled: false,
            isFocusable: false,
            hasFocusAction: false,
          ),
        );

        offline.value = false;
        await tester.pumpAndSettle();

        expect(leaveTile(tester).enabled, isTrue);
        expect(inRow(_onlineOnlyCopy), findsNothing);
      });

      testWidgets('a connection that drops and comes back keeps the row, and '
          'its semantics node', (tester) async {
        // One shape online and offline (STYLE_GUIDE, Online-only controls):
        // only the online-only note comes and goes.
        offline.value = false;
        await tester.pumpWidget(withLeave(offline: offline));
        await settleWith(tester, roster: [_member('u-me'), _coOwner]);
        final element = tester.element(leaveRow());
        final node = tester.getSemantics(leaveRow()).id;

        offline.value = true;
        await tester.pumpAndSettle();
        expect(leaveTile(tester).enabled, isFalse);
        expect(inRow(_onlineOnlyCopy), findsOneWidget);
        expect(tester.element(leaveRow()), same(element));
        expect(tester.getSemantics(leaveRow()).id, node);

        offline.value = false;
        await tester.pumpAndSettle();
        expect(leaveTile(tester).enabled, isTrue);
        expect(inRow(_onlineOnlyCopy), findsNothing);
        expect(tester.element(leaveRow()), same(element));
        expect(tester.getSemantics(leaveRow()).id, node);
      });

      testWidgets('offline and last owner, only the last-owner reason shows', (
        tester,
      ) async {
        await tester.pumpWidget(withLeave(offline: offline));
        await settleWith(tester, roster: [_owner, _zed]);

        expect(leaveTile(tester).enabled, isFalse);
        expect(inRow(_lastOwnerCopy), findsOneWidget);
        expect(inRow(_onlineOnlyCopy), findsNothing);
      });
    });
  });

  group('the confirmation', () {
    testWidgets('asks first, in the error colour', (tester) async {
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_member('u-me'), _coOwner]);

      await openLeave(tester);

      expect(find.text('Leave Sunday Crew?'), findsOneWidget);
      expect(
        find.text(
          'You lose access to the household and its events. To come back, '
          'you need a new invite.',
        ),
        findsOneWidget,
      );
      expect(find.text('Cancel'), findsOneWidget);
      expect(
        find.descendant(of: confirm(), matching: find.text('Leave')),
        findsOneWidget,
      );
      final style = tester.widget<TextButton>(confirm()).style;
      expect(
        style?.foregroundColor?.resolve(const {}),
        BgeTheme.light().colorScheme.error,
      );
      verifyNever(() => remote.leave(any()));
    });

    testWidgets('confirming sends one leave', (tester) async {
      final reply = Completer<HouseholdMember>();
      when(() => remote.leave(any())).thenAnswer((_) => reply.future);
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_member('u-me'), _coOwner]);

      // A double tap on the row asks once.
      await tester.ensureVisible(leaveRow());
      await tester.pumpAndSettle();
      await tester.tap(leaveRow());
      await tester.tap(leaveRow(), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      // A double tap on the confirm: the second lands while the dialog is on
      // its way out.
      await tester.tap(confirm());
      await tester.tap(confirm(), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      verify(() => remote.leave(_id)).called(1);
      // The second tap took nothing else with it, the page included.
      expect(confirm(), findsNothing);
      expect(find.text('Sunday Crew'), findsOneWidget);
      expect(tester.takeException(), isNull);

      reply.complete(_member('u-me'));
      await pumpPastLeft(tester);

      verifyNoMoreInteractions(remote);
      expect(backs, 1);
    });

    testWidgets('cancelling sends nothing', (tester) async {
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_member('u-me'), _coOwner]);

      await openLeave(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Leave Sunday Crew?'), findsNothing);
      verifyNever(() => remote.leave(any()));
      expect(failure(), findsNothing);
      expect(leaveTile(tester).enabled, isTrue);
      expect(backs, 0);
    });
  });

  group('while a leave is on its way', () {
    testWidgets(
      'while sending, Leave stays enabled and reads Leaving\u{2026}',
      (tester) async {
        final reply = Completer<HouseholdMember>();
        when(() => remote.leave(any())).thenAnswer((_) => reply.future);
        await tester.pumpWidget(withLeave());
        await settleWith(tester, roster: [_member('u-me'), _coOwner]);

        await confirmPending(tester);

        // Enabled so it can hold focus (#607); a press does nothing.
        expect(leaveTile(tester).enabled, isTrue);
        expect(tester.getSemantics(leaveRow()).label, contains(_leavingCopy));
        // Said to a screen reader to be unavailable, with nothing to press.
        expect(
          tester.getSemantics(leaveRow()),
          isSemantics(
            label: _leavingCopy,
            isButton: true,
            hasEnabledState: true,
            isEnabled: false,
            hasTapAction: false,
          ),
        );
        expect(
          find.descendant(
            of: leaveRow(),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );

        await tester.tap(leaveRow());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(confirm(), findsNothing);
        verify(() => remote.leave(_id)).called(1);

        reply.completeError(
          const HouseholdMemberRefusedException('no', statusCode: 400),
        );
        await tester.pumpAndSettle();

        expect(inRow(_leaveCopy), findsOneWidget);
        expect(inRow(_leavingCopy), findsNothing);
      },
    );

    testWidgets('from the keyboard, Leave keeps focus while its request runs '
        'and after', (tester) async {
      final reply = Completer<HouseholdMember>();
      when(() => remote.leave(any())).thenAnswer((_) => reply.future);
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_member('u-me'), _coOwner]);

      await leaveFromKeyboard(tester);

      expect(inRow(_leavingCopy), findsOneWidget);
      expect(rowFocused(), isTrue);
      expect(tester.getSemantics(leaveRow()), isSemantics(isFocused: true));

      reply.completeError(const HouseholdMemberTransientException('down'));
      await tester.pumpAndSettle();

      expect(
        inFailure("Couldn't reach the server. Try again."),
        findsOneWidget,
      );
      expect(rowFocused(), isTrue);
      expect(tester.getSemantics(leaveRow()), isSemantics(isFocused: true));
    });
  });

  group('the answer', () {
    testWidgets(
      'a 200 keeps the household on screen, pops once, and says so in a '
      'SnackBar',
      (tester) async {
        when(() => remote.leave(any()))
            .thenAnswer((_) async => _member('u-me'));
        // As the cache does: the person's own row goes, and the membership
        // gate then hides the household.
        when(() => repository.removeCachedMember(any(), any()))
            .thenAnswer((_) async {
              members.add([_coOwner]);
              households.add(const []);
            });
        await tester.pumpWidget(withLeave());
        await settleWith(tester, roster: [_member('u-me'), _coOwner]);

        await openLeave(tester);
        await tester.tap(confirm());
        await pumpPastLeft(tester);

        verify(() => repository.removeCachedMember(_id, 'u-me')).called(1);
        expect(backs, 1);
        expect(find.text('You left Sunday Crew.'), findsOneWidget);
        // Held: the last ready page, not the not-found one the gate gives.
        expect(find.text('Sunday Crew'), findsOneWidget);
        expect(find.byKey(HouseholdDetailScreen.notFoundKey), findsNothing);
        expect(find.byKey(HouseholdDetailScreen.memberKey('u-me')), findsOne);
        // Nothing flashes on the way out.
        expect(inRow(_leavingCopy), findsOneWidget);
        expect(leaveTile(tester).enabled, isTrue);
        expect(refreshes, 1);
      },
    );

    testWidgets('an enveloped 404 stays, with the gone banner', (tester) async {
      when(() => remote.leave(any())).thenThrow(
        const HouseholdMemberRefusedException('gone', statusCode: 404),
      );
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_member('u-me'), _coOwner]);

      await confirmLeave(tester);

      expect(
        inFailure("You're no longer in this household. It's being read again."),
        findsOneWidget,
      );
      expect(toneOf(tester), BgeBannerTone.warning);
      expect(backs, 0);
      expect(find.text('Sunday Crew'), findsOneWidget);
      expect(leaveTile(tester).enabled, isTrue);
      expect(refreshes, 1);
      verifyNever(() => repository.removeCachedMember(any(), any()));
      // Directly above the row.
      expect(
        tester.getBottomLeft(failure()).dy,
        lessThanOrEqualTo(tester.getTopLeft(leaveRow()).dy),
      );

      await tester.tap(
        find.descendant(of: failure(), matching: find.text('Dismiss')),
      );
      await tester.pumpAndSettle();
      expect(failure(), findsNothing);
    });

    testWidgets('a 400 shows the last-owner banner', (tester) async {
      when(
        () => remote.leave(any()),
      ).thenThrow(const HouseholdMemberRefusedException('no', statusCode: 400));
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_owner, _coOwner]);

      await confirmLeave(tester);

      expect(
        inFailure(
          "You're the household's only owner. Make another member the owner "
          'first.',
        ),
        findsOneWidget,
      );
      expect(toneOf(tester), BgeBannerTone.warning);
      expect(backs, 0);
    });

    group('offline (#49)', () {
      late ValueNotifier<bool> offline;

      setUp(() => offline = ValueNotifier(false));

      tearDown(() => offline.dispose());

      testWidgets(
        'a connection lost after confirming shows the offline banner and '
        'removes nothing',
        (tester) async {
          when(() => remote.leave(any()))
              .thenThrow(const HouseholdMemberTransientException('down'));
          await tester.pumpWidget(withLeave(offline: offline));
          await settleWith(tester, roster: [_member('u-me'), _coOwner]);

          await openLeave(tester);
          // The connection drops with the dialog open, which is not gated.
          offline.value = true;
          await tester.pumpAndSettle();
          await tester.tap(confirm());
          await tester.pumpAndSettle();

          verify(() => remote.leave(_id)).called(1);
          expect(
            inFailure("Couldn't reach the server. Try again."),
            findsOneWidget,
          );
          expect(toneOf(tester), BgeBannerTone.error);
          verifyNever(() => repository.removeCachedMember(any(), any()));
          expect(backs, 0);
          expect(refreshes, 0);
          expect(find.text('Sunday Crew'), findsOneWidget);
        },
      );
    });
  });

  group('the Leave row and its confirmation fit at 320dp and 2.0 text', () {
    Future<void> pumpNarrow(
      WidgetTester tester, {
      required Household household,
      required List<HouseholdMember> roster,
      ValueListenable<bool>? offline,
    }) async {
      useViewSize(tester, const Size(320, 640));
      await tester.pumpWidget(
        withLeave(textScaler: const TextScaler.linear(2), offline: offline),
      );
      await settleWith(tester, household: household, roster: roster);
      await tester.ensureVisible(leaveRow());
      await tester.pumpAndSettle();
    }

    void expectWithinWidth(WidgetTester tester, Finder finder) {
      final rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
    }

    testWidgets('the reason line', (tester) async {
      await pumpNarrow(
        tester,
        household: _household(_id),
        roster: [_owner, _zed],
      );

      expect(tester.takeException(), isNull);
      expect(inRow(_lastOwnerCopy), findsOneWidget);
      expectWithinWidth(tester, inRow(_lastOwnerCopy));
      expectWithinWidth(tester, leaveRow());
    });

    testWidgets('the online-only reason', (tester) async {
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      await pumpNarrow(
        tester,
        offline: offline,
        household: _household(_id),
        roster: [_member('u-me'), _coOwner],
      );

      expect(tester.takeException(), isNull);
      expect(inRow(_onlineOnlyCopy), findsOneWidget);
      expectWithinWidth(tester, inRow(_onlineOnlyCopy));
      expectWithinWidth(tester, leaveRow());
    });

    testWidgets('the confirmation', (tester) async {
      const name = 'Maximiliana Theodora Wolfeschlegelsteinhausen-Bergdorff';
      await pumpNarrow(
        tester,
        household: _household(_id, name: name),
        roster: [_member('u-me'), _coOwner],
      );
      expect(tester.takeException(), isNull);

      await tester.tap(leaveRow());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Leave $name?'), findsOneWidget);
      // The dialog scrolls rather than pushing its buttons off the screen.
      await tester.ensureVisible(confirm());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(confirm().hitTestable(), findsOneWidget);
    });
  });

  group("focus on a member's menu while the page is held (#478)", () {
    FocusNode menuFocus(WidgetTester tester, String userId) => tester
        .widget<IconButton>(
          find.byKey(HouseholdDetailScreen.memberActionsKey(userId)),
        )
        .focusNode!;

    testWidgets('stays on the menu, not the member count, once a leave is '
        'accepted', (tester) async {
      when(() => remote.leave(any())).thenAnswer((_) async => _member('u-me'));
      // The roster drops the viewer, which takes every menu away from what
      // the bloc now holds, while the page still draws them.
      when(() => repository.removeCachedMember(any(), any()))
          .thenAnswer((_) async => members.add([_coOwner]));
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_owner, _coOwner]);

      // From the keyboard, onto Zed's menu.
      for (var i = 0; i < 5 && !menuFocus(tester, 'u-2').hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(menuFocus(tester, 'u-2').hasPrimaryFocus, isTrue);

      BlocProvider.of<LeaveHouseholdBloc>(
        tester.element(find.byKey(HouseholdDetailScreen.memberCountKey)),
      ).add(const LeaveHouseholdRequested(_id));
      await pumpPastLeft(tester);

      expect(backs, 1);
      final count = find.byKey(HouseholdDetailScreen.memberCountKey);
      expect(Focus.of(tester.element(count)).hasFocus, isFalse);
      expect(menuFocus(tester, 'u-2').hasPrimaryFocus, isTrue);

      // The membership gate then hides the household: still held.
      households.add(const []);
      await pumpPastLeft(tester);

      expect(find.text('Sunday Crew'), findsOneWidget);
      expect(Focus.of(tester.element(count)).hasFocus, isFalse);
      expect(menuFocus(tester, 'u-2').hasPrimaryFocus, isTrue);
    });
  });

  group('a 200 pops the screen as a real route', () {
    /// The detail screen pushed over [_beneathCopy], with an `onBack` that
    /// pops, as the app's does.
    Widget pushedOver({
      void Function(BuildContext context, String householdId)? onNewEvent,
    }) => harness(
      onBack: (context) {
        backs++;
        Navigator.of(context).pop();
      },
      onNewEvent: onNewEvent,
      members: remote,
      onMembershipChanged: () async => refreshes++,
      pushed: true,
    );

    void expectBackBeneath() {
      expect(find.byType(HouseholdDetailScreen), findsNothing);
      expect(find.text(_beneathCopy), findsOneWidget);
      expect(find.text('You left Sunday Crew.'), findsOneWidget);
      expect(backs, 1);
    }

    testWidgets('the screen goes, and the SnackBar shows on the page beneath', (
      tester,
    ) async {
      when(() => remote.leave(any())).thenAnswer((_) async => _member('u-me'));
      await tester.pumpWidget(pushedOver());
      await settleWith(tester, roster: [_member('u-me'), _coOwner]);
      expect(find.text(_beneathCopy), findsNothing);

      await confirmLeave(tester);

      expectBackBeneath();
    });

    testWidgets('a dialog open over the screen closes first, so the screen '
        'still goes', (tester) async {
      final reply = Completer<HouseholdMember>();
      when(() => remote.leave(any())).thenAnswer((_) => reply.future);
      await tester.pumpWidget(pushedOver());
      await settleWith(tester, roster: [_owner, _coOwner]);

      await confirmPending(tester);
      // The page stays live while the leave is on its way: Zed's menu opens
      // the remove dialog.
      await tester.tap(
        find.byKey(HouseholdDetailScreen.memberActionsKey('u-2')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(HouseholdDetailScreen.removeKey));
      // A menu item's onPressed runs after the frame, so two pumps.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final removeConfirm = find.byKey(HouseholdDetailScreen.removeConfirmKey);
      expect(removeConfirm, findsOneWidget);

      reply.complete(_member('u-me'));
      await pumpPastLeft(tester);

      expect(removeConfirm, findsNothing);
      expectBackBeneath();
      verifyNever(() => remote.remove(any(), any()));
    });

    testWidgets('a route pushed over the screen goes first, so the screen '
        'still goes', (tester) async {
      const form = 'The new event form';
      final reply = Completer<HouseholdMember>();
      when(() => remote.leave(any())).thenAnswer((_) => reply.future);
      await tester.pumpWidget(
        pushedOver(
          onNewEvent: (context, _) => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text(form)),
            ),
          ),
        ),
      );
      await settleWith(tester, roster: [_member('u-me'), _coOwner]);

      await confirmPending(tester);
      final newEvent = find.byKey(HouseholdDetailScreen.newEventKey);
      await tester.ensureVisible(newEvent);
      await tester.pump();
      await tester.tap(newEvent);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(form), findsOneWidget);

      reply.complete(_member('u-me'));
      await pumpPastLeft(tester);

      expect(find.text(form), findsNothing);
      expectBackBeneath();
    });

    testWidgets('a household gone from the cache while the leave is on its '
        'way still goes, named as it was', (tester) async {
      final reply = Completer<HouseholdMember>();
      when(() => remote.leave(any())).thenAnswer((_) => reply.future);
      await tester.pumpWidget(pushedOver());
      await settleWith(tester, roster: [_member('u-me'), _coOwner]);

      await confirmPending(tester);
      // A hydrate that read the list after the server let the person go
      // takes the household, and the Leave row with it, off the page.
      households.add(const []);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(leaveRow(), findsNothing);

      reply.complete(_member('u-me'));
      await pumpPastLeft(tester);
      // The pop starts after the first frame here, so the exit's first tick
      // is the second one: one more interval lets it finish.
      await tester.pump(const Duration(seconds: 1));

      expectBackBeneath();
    });

    testWidgets('a screen already on its way out is not popped again', (
      tester,
    ) async {
      final reply = Completer<HouseholdMember>();
      when(() => remote.leave(any())).thenAnswer((_) => reply.future);
      await tester.pumpWidget(pushedOver());
      await settleWith(tester, roster: [_member('u-me'), _coOwner]);

      await confirmPending(tester);
      // Back while the leave is on its way, and the answer lands during the
      // screen's exit.
      Navigator.of(tester.element(leaveRow())).pop();
      await tester.pump();
      reply.complete(_member('u-me'));
      await pumpPastLeft(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(HouseholdDetailScreen), findsNothing);
      expect(find.text(_beneathCopy), findsOneWidget);
      expect(find.text('You left Sunday Crew.'), findsOneWidget);
      expect(backs, 0);
    });

    // #464: the leave outlives the screen. Gone before the answer lands, it
    // still says how it went, on the page beneath, and goes nowhere: the
    // user already has.
    group('left mid-leave', () {
      late Completer<HouseholdMember> reply;
      late LeaveHouseholdBloc bloc;

      /// Confirms a leave whose answer waits on [reply], then goes back to
      /// the page beneath. When [endSession], the session ends in the same
      /// turn. Pumps 50 ms into the exit, with the screen still leaving.
      Future<void> confirmThenPop(
        WidgetTester tester, {
        bool endSession = false,
      }) async {
        reply = Completer<HouseholdMember>();
        when(() => remote.leave(any())).thenAnswer((_) => reply.future);
        await tester.pumpWidget(pushedOver());
        await settleWith(tester, roster: [_member('u-me'), _coOwner]);
        bloc = BlocProvider.of<LeaveHouseholdBloc>(tester.element(leaveRow()));

        await confirmPending(tester);
        expect(bloc.state.busy, isTrue);
        Navigator.of(tester.element(leaveRow())).pop();
        if (endSession) lease.isLive = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(HouseholdDetailScreen), findsOneWidget);
      }

      /// Confirms a leave whose answer waits on [reply], then goes back to
      /// the page beneath, and lets the screen go, while it is on its way.
      Future<void> confirmThenGo(WidgetTester tester) async {
        await confirmThenPop(tester);
        await tester.pumpAndSettle();
        expect(find.byType(HouseholdDetailScreen), findsNothing);
      }

      Future<bool> closed(WidgetTester tester) async {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        return bloc.isClosed;
      }

      /// The page beneath is the only route: nothing was pushed or popped
      /// after the user went back.
      void expectStackUnchanged(WidgetTester tester) {
        expect(find.text(_beneathCopy), findsOneWidget);
        expect(
          Navigator.of(tester.element(find.text(_beneathCopy))).canPop(),
          false,
        );
        expect(backs, 0);
      }

      Finder inSnackBar(String copy) =>
          find.descendant(of: find.byType(SnackBar), matching: find.text(copy));

      testWidgets('left mid-leave, the outcome is still said', (tester) async {
        await confirmThenGo(tester);
        // Kept for the leave still on its way.
        expect(await closed(tester), isFalse);

        reply.complete(_member('u-me'));
        await tester.pumpAndSettle();

        expect(inSnackBar('You left Sunday Crew.'), findsOneWidget);
        expectStackUnchanged(tester);
        expect(await closed(tester), isTrue);
      });

      testWidgets('left mid-leave, a failure is still said', (tester) async {
        await confirmThenGo(tester);

        reply.completeError(
          const HouseholdMemberRefusedException('no', statusCode: 400),
        );
        await tester.pumpAndSettle();

        expect(
          inSnackBar(
            "You're the household's only owner. Make another member the "
            'owner first.',
          ),
          findsOneWidget,
        );
        expectStackUnchanged(tester);
        expect(await closed(tester), isTrue);
      });

      testWidgets('left mid-leave, nothing is said once the session has '
          'ended', (tester) async {
        await confirmThenGo(tester);
        lease.isLive = false;

        reply.complete(_member('u-me'));
        await tester.pumpAndSettle();

        expect(find.byType(SnackBar), findsNothing);
        expectStackUnchanged(tester);
        // Still closed: ending the session skips the message, not the close.
        expect(await closed(tester), isTrue);
      });

      // The shell ends a session in the same turn it routes away, and the
      // popped route stays mounted through its exit. A leave that settles
      // there asks the lease (#694), is said as it would be once the screen
      // had gone, and goes nowhere (#464).
      group("on the route's way out", () {
        /// Gives the answer, and lets it reach the screen, still inside the
        /// exit.
        Future<void> settle(WidgetTester tester, {required bool fails}) async {
          if (fails) {
            reply.completeError(
              const HouseholdMemberRefusedException('no', statusCode: 400),
            );
          } else {
            reply.complete(_member('u-me'));
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(find.byType(HouseholdDetailScreen), findsOneWidget);
        }

        /// The keys of the bars showing: a bar said again is a new key.
        Set<Key?> barKeys(WidgetTester tester) => {
          for (final bar in tester.widgetList<SnackBar>(find.byType(SnackBar)))
            bar.key,
        };

        for (final (name, fails) in [('lands', false), ('fails', true)]) {
          testWidgets('a leave that $name after the session ended says '
              'nothing, and the bloc still closes', (tester) async {
            await confirmThenPop(tester, endSession: true);

            await settle(tester, fails: fails);
            expect(find.byType(SnackBar), findsNothing);
            await tester.pumpAndSettle();

            expect(find.byType(SnackBar), findsNothing);
            expectStackUnchanged(tester);
            expect(await closed(tester), isTrue);
          });
        }

        for (final (name, fails, copy) in [
          ('lands', false, 'You left Sunday Crew.'),
          (
            'fails',
            true,
            "You're the household's only owner. Make another member the "
                'owner first.',
          ),
        ]) {
          testWidgets('a leave that $name is said once, and goes nowhere', (
            tester,
          ) async {
            await confirmThenPop(tester);

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
  });

  group('focus when a failure leaves the Leave row disabled', () {
    Finder dismiss() => find.descendant(
      of: failure(),
      matching: find.widgetWithText(TextButton, 'Dismiss'),
    );

    void expectFocusOnDismiss(WidgetTester tester) {
      expect(
        focusedIn(dismiss()),
        isTrue,
        reason: 'primary focus: ${FocusManager.instance.primaryFocus}',
      );
      expect(
        tester.getSemantics(dismiss()),
        isSemantics(label: 'Dismiss', isButton: true, isFocused: true),
      );
    }

    testWidgets('offline by the time a transient failure lands, focus moves '
        'to Dismiss', (tester) async {
      final offline = ValueNotifier(false);
      addTearDown(offline.dispose);
      final reply = Completer<HouseholdMember>();
      when(() => remote.leave(any())).thenAnswer((_) => reply.future);
      await tester.pumpWidget(withLeave(offline: offline));
      await settleWith(tester, roster: [_member('u-me'), _coOwner]);

      await leaveFromKeyboard(tester);
      // The connection drops while the request is on its way. The busy row
      // stays enabled, so it keeps focus.
      offline.value = true;
      await tester.pump();
      expect(rowFocused(), isTrue);

      reply.completeError(const HouseholdMemberTransientException('down'));
      await tester.pumpAndSettle();

      // Idle and offline: disabled, which takes its focus node away.
      expect(leaveTile(tester).enabled, isFalse);
      expect(inRow(_onlineOnlyCopy), findsOneWidget);
      expect(
        inFailure("Couldn't reach the server. Try again."),
        findsOneWidget,
      );
      expectFocusOnDismiss(tester);
    });

    testWidgets('a roster without the co-owner while the leave is on its way '
        'keeps the row inert and focused, and the 400 then moves focus to '
        'Dismiss', (tester) async {
      final reply = Completer<HouseholdMember>();
      when(() => remote.leave(any())).thenAnswer((_) => reply.future);
      final amy = _member('u-3', displayName: 'Amy');
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_owner, _coOwner, amy]);

      await leaveFromKeyboard(tester);
      // Zed leaves elsewhere, and the hydrate says so before the answer.
      members.add([_owner, amy]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Busy outranks the block: the row stays as it was, so it keeps focus.
      expect(leaveTile(tester).enabled, isTrue);
      expect(inRow(_leavingCopy), findsOneWidget);
      expect(inRow(_lastOwnerCopy), findsNothing);
      expect(
        tester.getSemantics(leaveRow()),
        isSemantics(
          label: _leavingCopy,
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
          isFocused: true,
        ),
      );
      expect(rowFocused(), isTrue);

      reply.completeError(
        const HouseholdMemberRefusedException('no', statusCode: 400),
      );
      await tester.pumpAndSettle();

      expect(leaveTile(tester).enabled, isFalse);
      expect(inRow(_lastOwnerCopy), findsOneWidget);
      expect(
        inFailure(
          "You're the household's only owner. Make another member the owner "
          'first.',
        ),
        findsOneWidget,
      );
      expectFocusOnDismiss(tester);
    });

    testWidgets('a 400, then a roster without the co-owner, moves focus to '
        'Dismiss', (tester) async {
      when(
        () => remote.leave(any()),
      ).thenThrow(const HouseholdMemberRefusedException('no', statusCode: 400));
      final amy = _member('u-3', displayName: 'Amy');
      await tester.pumpWidget(withLeave());
      await settleWith(tester, roster: [_owner, _coOwner, amy]);

      await leaveFromKeyboard(tester);
      await tester.pumpAndSettle();
      // The cached roster still has Zed, so the row is still enabled.
      expect(
        inFailure(
          "You're the household's only owner. Make another member the owner "
          'first.',
        ),
        findsOneWidget,
      );
      expect(rowFocused(), isTrue);

      // The refresh the refusal started drops Zed, who left elsewhere.
      members.add([_owner, amy]);
      await tester.pumpAndSettle();

      expect(leaveTile(tester).enabled, isFalse);
      expect(inRow(_lastOwnerCopy), findsOneWidget);
      expectFocusOnDismiss(tester);
    });
  });

  group('accessibility audit', () {
    /// The screen in [theme]. [offline] holds the connection down through a
    /// notifier of the cell's own, which goes with it.
    Widget Function(ThemeData) screen({bool offline = false}) => (theme) {
      final notifier = offline ? ValueNotifier(true) : null;
      if (notifier != null) addTearDown(notifier.dispose);
      return withLeave(theme: theme, offline: notifier);
    };

    /// Brings the Leave row, which ends the page, on screen, and checks it got
    /// there: at 320dp × 2.0 it can sit below the fold.
    Future<void> toLeaveRow(WidgetTester tester) async {
      await tester.ensureVisible(leaveRow());
      await tester.pumpAndSettle();
      expect(leaveRow().hitTestable(), findsOneWidget);
    }

    auditScreen(
      'Leave disabled, the last owner',
      build: screen(),
      arrange: (tester) async {
        await settleWith(tester, roster: [_owner, _zed]);
        await toLeaveRow(tester);
        expect(leaveTile(tester).enabled, isFalse);
        expect(inRow(_lastOwnerCopy), findsOneWidget);
      },
    );

    auditScreen(
      'Leave disabled, the only member',
      build: screen(),
      arrange: (tester) async {
        await settleWith(tester, roster: [_owner]);
        await toLeaveRow(tester);
        expect(leaveTile(tester).enabled, isFalse);
        expect(inRow(_onlyMemberCopy), findsOneWidget);
      },
    );

    auditScreen(
      'Leave disabled, offline',
      build: screen(offline: true),
      arrange: (tester) async {
        await settleWith(tester, roster: [_member('u-me'), _coOwner]);
        await toLeaveRow(tester);
        expect(leaveTile(tester).enabled, isFalse);
        expect(inRow(_onlineOnlyCopy), findsOneWidget);
      },
    );

    auditScreen(
      'leave confirm',
      build: screen(),
      arrange: (tester) async {
        await settleWith(tester, roster: [_member('u-me'), _coOwner]);
        await openLeave(tester);
        expect(find.text('Leave Sunday Crew?'), findsOneWidget);
        expect(confirm().hitTestable(), findsOneWidget);
      },
    );

    // The leave never answers, so the row keeps spinning.
    auditScreen(
      'leaving',
      build: screen(),
      settle: false,
      arrange: (tester) async {
        when(() => remote.leave(any()))
            .thenAnswer((_) => Completer<HouseholdMember>().future);
        await settleWith(tester, roster: [_member('u-me'), _coOwner]);
        await confirmPending(tester);
        expect(inRow(_leavingCopy), findsOneWidget);
        expect(
          find.descendant(
            of: leaveRow(),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        expect(leaveRow().hitTestable(), findsOneWidget);
      },
    );

    auditScreen(
      'a refused leave',
      build: screen(),
      arrange: (tester) async {
        when(() => remote.leave(any())).thenThrow(
          const HouseholdMemberRefusedException('no', statusCode: 400),
        );
        await settleWith(tester, roster: [_owner, _coOwner]);
        await confirmLeave(tester);
        expect(failure(), findsOneWidget);
        expect(toneOf(tester), BgeBannerTone.warning);
        await tester.ensureVisible(failure());
        await tester.pumpAndSettle();
        expect(
          find
              .descendant(of: failure(), matching: find.text('Dismiss'))
              .hitTestable(),
          findsOneWidget,
        );
        expect(leaveRow().hitTestable(), findsOneWidget);
      },
    );
  });
}
