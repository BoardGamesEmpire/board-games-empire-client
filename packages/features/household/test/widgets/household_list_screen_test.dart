import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

Household _household(
  String id, {
  String name = 'Game Night',
  bool isDirty = false,
  bool isLocalOnly = false,
}) => Household(
  id: id,
  name: name,
  isDirty: isDirty,
  isLocalOnly: isLocalOnly,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

const _emptyTitleCopy = 'No households yet';
const _notSyncedCopy = 'Not yet synced';
const _refreshFailedCopy =
    "This list may be out of date — we couldn't refresh it.";
const _errorCopy = "We couldn't open your households.";
const _retryCopy = 'Try again';
const _refreshingCopy = 'Refreshing\u2026';

/// Pins the #269 list screen against a mocked repository and a hand-driven
/// hydration stream — the four surfaces the decisions specify (loading,
/// empty, rows, error), the stale-rows banner, and the create affordance's
/// guard.
void main() {
  late _MockHouseholdRepository repository;
  late StreamController<List<Household>> households;
  late StreamController<HouseholdHydrationState> hydration;

  setUp(() {
    repository = _MockHouseholdRepository();
    households = StreamController<List<Household>>.broadcast();
    hydration = StreamController<HouseholdHydrationState>.broadcast();
    when(repository.watchHouseholds).thenAnswer((_) => households.stream);
  });

  tearDown(() {
    unawaited(households.close());
    unawaited(hydration.close());
  });

  Widget harness({
    void Function(BuildContext context)? onCreate,
    void Function(BuildContext context, String householdId)? onOpen,
    Future<void> Function()? onRetry,
    VoidCallback? onEnter,
    TextScaler textScaler = TextScaler.noScaling,
  }) => MaterialApp(
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: HouseholdListScreen(
      repository: repository,
      hydration: hydration.stream,
      onCreate: onCreate,
      onOpen: onOpen,
      onRetry: onRetry,
      onEnter: onEnter,
    ),
  );

  /// Renders into a phone-width window. `MediaQueryData.size` constrains
  /// nothing on its own, so the width a row has to fit into has to come
  /// from the view.
  void useNarrowWindow(WidgetTester tester, {double width = 320}) {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('while the cache is filling', () {
    testWidgets('shows a spinner rather than an empty state', (tester) async {
      await tester.pumpWidget(harness());
      hydration.add(HouseholdHydrationState.running);
      households.add(const []);
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.loadingKey), findsOneWidget);
      expect(find.text(_emptyTitleCopy), findsNothing);
    });

    testWidgets('shows rows the cache already has', (tester) async {
      // A returning user's cached rows are not hidden behind the refresh.
      await tester.pumpWidget(harness());
      hydration.add(HouseholdHydrationState.running);
      households.add([_household('h-1', name: 'Sunday Crew')]);
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.loadingKey), findsNothing);
      expect(find.text('Sunday Crew'), findsOneWidget);
    });
  });

  group('when there are no households', () {
    testWidgets('shows the empty state once the hydrate settles', (
      tester,
    ) async {
      await tester.pumpWidget(harness(onCreate: (_) {}));
      hydration.add(HouseholdHydrationState.refreshed);
      households.add(const []);
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.emptyKey), findsOneWidget);
      expect(find.text(_emptyTitleCopy), findsOneWidget);
    });

    testWidgets('offers create from the empty state itself', (tester) async {
      // The FAB alone is a weak call to action on a first-run screen, and
      // the empty state is where the user is looking.
      var created = 0;
      await tester.pumpWidget(harness(onCreate: (_) => created++));
      households.add(const []);
      await tester.pump();

      await tester.tap(find.byKey(HouseholdListScreen.emptyCreateKey));
      await tester.pump();

      expect(created, equals(1));
    });

    testWidgets('offers no create affordance when create is unavailable', (
      tester,
    ) async {
      // No household client on this container (#137): the create route
      // would dead-end, so neither the FAB nor the empty-state button is
      // offered.
      await tester.pumpWidget(harness());
      households.add(const []);
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.createFabKey), findsNothing);
      expect(find.byKey(HouseholdListScreen.emptyCreateKey), findsNothing);
      expect(find.byKey(HouseholdListScreen.emptyKey), findsOneWidget);
    });
  });

  group('with households', () {
    testWidgets('renders one row per household, in the order given', (
      tester,
    ) async {
      // The repository orders (#269 D3). A screen that re-sorted would be a
      // second, invisible ordering rule.
      await tester.pumpWidget(harness());
      households.add([
        _household('h-1', name: 'Alpha'),
        _household('h-2', name: 'zulu'),
      ]);
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.rowKey('h-1')), findsOneWidget);
      expect(find.byKey(HouseholdListScreen.rowKey('h-2')), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Alpha')).dy,
        lessThan(tester.getTopLeft(find.text('zulu')).dy),
      );
    });

    testWidgets('tells a screen reader how many rows there are', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      households.add([_household('h-1'), _household('h-2')]);
      await tester.pump();

      final scrollable = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      expect(scrollable.semanticChildCount, equals(2));
    });

    testWidgets('badges a household the server has never seen', (tester) async {
      await tester.pumpWidget(harness());
      households.add([
        _household('h-1', isLocalOnly: true, isDirty: true),
        _household('h-2'),
      ]);
      await tester.pump();

      expect(find.text(_notSyncedCopy), findsOneWidget);
    });

    testWidgets('badges a household with unsent local changes', (tester) async {
      await tester.pumpWidget(harness());
      households.add([_household('h-1', isDirty: true)]);
      await tester.pump();

      expect(find.text(_notSyncedCopy), findsOneWidget);
    });

    testWidgets('does not badge a synced household', (tester) async {
      await tester.pumpWidget(harness());
      households.add([_household('h-1')]);
      await tester.pump();

      expect(find.text(_notSyncedCopy), findsNothing);
    });

    testWidgets('states the badge in words, not colour alone', (tester) async {
      // The a11y requirement on the issue. The badge's meaning has to
      // survive a screen reader and a monochrome display.
      await tester.pumpWidget(harness());
      households.add([_household('h-1', isLocalOnly: true)]);
      await tester.pump();

      final semantics = tester.getSemantics(
        find.byKey(HouseholdListScreen.rowKey('h-1')),
      );
      expect(semantics.label, contains(_notSyncedCopy));
    });

    testWidgets('opens a household when its row is tapped', (tester) async {
      // #269 D5 kept rows inert because no detail route existed. #270
      // built it, so the row is a control.
      final opened = <String>[];
      await tester.pumpWidget(harness(onOpen: (_, id) => opened.add(id)));
      households.add([_household('h-1'), _household('h-2')]);
      await tester.pump();

      await tester.tap(find.byKey(HouseholdListScreen.rowKey('h-2')));
      await tester.pump();

      expect(opened, equals(['h-2']));
    });

    testWidgets('announces a navigating row as a button', (tester) async {
      await tester.pumpWidget(harness(onOpen: (_, _) {}));
      households.add([_household('h-1', name: 'Sunday Crew')]);
      await tester.pump();

      final semantics = tester.getSemantics(
        find.byKey(HouseholdListScreen.rowKey('h-1')),
      );
      expect(semantics, isSemantics(isButton: true));
      // Still one merged node, not a control plus loose fragments.
      expect(semantics.label, contains('Sunday Crew'));
    });

    testWidgets('keeps the badge inside the row control', (tester) async {
      // The badge was moved out of ListTile.trailing to survive text
      // scaling (#269); making the row tappable must not have pushed it
      // back out of the merged node.
      await tester.pumpWidget(harness(onOpen: (_, _) {}));
      households.add([_household('h-1', isLocalOnly: true)]);
      await tester.pump();

      final semantics = tester.getSemantics(
        find.byKey(HouseholdListScreen.rowKey('h-1')),
      );
      expect(semantics, isSemantics(isButton: true));
      expect(semantics.label, contains(_notSyncedCopy));
    });

    testWidgets('activates from the keyboard, not just a tap', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(harness(onOpen: (_, id) => opened.add(id)));
      households.add([_household('h-1')]);
      await tester.pump();

      final semantics = tester.getSemantics(
        find.byKey(HouseholdListScreen.rowKey('h-1')),
      );
      expect(semantics, isSemantics(hasTapAction: true));

      // The real keyboard path: focus the row, then press Enter.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(opened, equals(['h-1']));
    });

    testWidgets('stays inert content where no detail route is offered', (
      tester,
    ) async {
      // Not a leftover: a composition that cannot reach the detail screen
      // should not offer a tap that does nothing (#269 D5's judgement,
      // now a condition rather than an era).
      await tester.pumpWidget(harness());
      households.add([_household('h-1')]);
      await tester.pump();

      final semantics = tester.getSemantics(
        find.byKey(HouseholdListScreen.rowKey('h-1')),
      );
      expect(semantics, isSemantics(isButton: false, hasTapAction: false));
    });

    testWidgets('offers create from the floating action button', (
      tester,
    ) async {
      var created = 0;
      await tester.pumpWidget(harness(onCreate: (_) => created++));
      households.add([_household('h-1')]);
      await tester.pump();

      await tester.tap(find.byKey(HouseholdListScreen.createFabKey));
      await tester.pump();

      expect(created, equals(1));
    });
  });

  group('at the largest text scale the app honors', () {
    // BgeTextScale.maxScaleFactor — WCAG 1.4.4's 200%, which the shell
    // clamps to app-wide. A row that asserts at that scale is a row that
    // is unusable for exactly the users the badge is written for.
    for (final width in <double>[320, 360, 412]) {
      testWidgets('a badged row lays out on a ${width.toInt()}dp window', (
        tester,
      ) async {
        useNarrowWindow(tester, width: width);
        await tester.pumpWidget(
          harness(
            textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
          ),
        );
        households.add([
          _household(
            'h-1',
            name: 'The Sunday Board Game Club',
            isLocalOnly: true,
          ),
        ]);
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text(_notSyncedCopy), findsOneWidget);
      });
    }

    testWidgets('a badged row lays out at an intermediate scale too', (
      tester,
    ) async {
      // 200% is not the only breaking point — the trailing-slot assert
      // fires well below it on a narrow window.
      useNarrowWindow(tester, width: 360);
      await tester.pumpWidget(
        harness(textScaler: const TextScaler.linear(1.6)),
      );
      households.add([_household('h-1', isDirty: true)]);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('when the refresh failed', () {
    testWidgets('says so above the rows it is still showing', (tester) async {
      await tester.pumpWidget(harness());
      households.add([_household('h-1')]);
      hydration.add(HouseholdHydrationState.failed);
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(find.byKey(HouseholdListScreen.rowKey('h-1')), findsOneWidget);
    });

    testWidgets('clears when a re-hydrate refreshes the list, with nothing '
        'asked of the user (#302)', (tester) async {
      // The #302 re-run drives the same status holder the screen is
      // already watching (#270 D5), so the banner going away is the whole
      // of what the household feature had to do for that issue.
      await tester.pumpWidget(harness());
      households.add([_household('h-1')]);
      hydration.add(HouseholdHydrationState.failed);
      await tester.pump();
      expect(find.text(_refreshFailedCopy), findsOneWidget);

      hydration.add(HouseholdHydrationState.running);
      await tester.pump();
      hydration.add(HouseholdHydrationState.refreshed);
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsNothing);
      expect(find.byKey(HouseholdListScreen.rowKey('h-1')), findsOneWidget);
    });

    testWidgets('offers a retry where the composition can run one (#300 D5)', (
      tester,
    ) async {
      await tester.pumpWidget(harness(onRetry: () async {}));
      households.add([_household('h-1')]);
      hydration.add(HouseholdHydrationState.failed);
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.refreshRetryKey), findsOneWidget);
      expect(find.text(_retryCopy), findsOneWidget);
    });

    testWidgets('offers none where it cannot (#137)', (tester) async {
      // A container with no household client has no drain to re-run, and a
      // button that does nothing is worse than no button (#269 D5's
      // reasoning, applied to this control).
      await tester.pumpWidget(harness());
      households.add([_household('h-1')]);
      hydration.add(HouseholdHydrationState.failed);
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(find.byKey(HouseholdListScreen.refreshRetryKey), findsNothing);
    });

    testWidgets('pressing it runs a pass and says so (#300 D6)', (
      tester,
    ) async {
      final pass = Completer<void>();
      var calls = 0;

      await tester.pumpWidget(
        harness(
          onRetry: () {
            calls++;
            return pass.future;
          },
        ),
      );
      households.add([_household('h-1')]);
      hydration.add(HouseholdHydrationState.failed);
      await tester.pump();

      await tester.tap(find.byKey(HouseholdListScreen.refreshRetryKey));
      await tester.pump();
      hydration.add(HouseholdHydrationState.running);
      await tester.pump();

      expect(calls, 1);
      // Two of them: the banner's message, and the disabled button's own
      // label — it keeps a name rather than becoming a bare spinner
      // (`BgeSubmitButton`'s contract, #163).
      expect(find.text(_refreshingCopy), findsNWidgets(2));
      expect(find.text(_refreshFailedCopy), findsNothing);
      // The rows it is refreshing stay put underneath.
      expect(find.byKey(HouseholdListScreen.rowKey('h-1')), findsOneWidget);

      pass.complete();
      hydration.add(HouseholdHydrationState.refreshed);
      await tester.pump();
      await tester.pump();

      expect(find.text(_refreshingCopy), findsNothing);
      expect(find.text(_refreshFailedCopy), findsNothing);
    });

    testWidgets('a pass nobody asked for is not announced (#300 D6)', (
      tester,
    ) async {
      // #302's triggers re-hydrate on a connectivity edge and on app
      // resume. The banner clearing is all the user should see of that;
      // narrating it would put a message on screen for work they did not
      // ask for.
      await tester.pumpWidget(harness(onRetry: () async {}));
      households.add([_household('h-1')]);
      hydration.add(HouseholdHydrationState.failed);
      await tester.pump();

      hydration.add(HouseholdHydrationState.running);
      await tester.pump();

      expect(find.text(_refreshingCopy), findsNothing);
      expect(find.text(_refreshFailedCopy), findsNothing);
    });

    testWidgets('retrying an empty list shows the spinner, not a banner over '
        '"no households yet"', (tester) async {
      final pass = Completer<void>();
      await tester.pumpWidget(harness(onRetry: () => pass.future));
      households.add(const []);
      hydration.add(HouseholdHydrationState.failed);
      await tester.pump();
      expect(find.byKey(HouseholdListScreen.emptyKey), findsOneWidget);

      await tester.tap(find.byKey(HouseholdListScreen.refreshRetryKey));
      await tester.pump();
      hydration.add(HouseholdHydrationState.running);
      await tester.pump();

      // #269 D1: an empty cache being refilled is unknown, not empty. The
      // whole surface becomes the spinner rather than an empty state
      // wearing a "refreshing" banner.
      expect(find.byKey(HouseholdListScreen.loadingKey), findsOneWidget);
      expect(find.byKey(HouseholdListScreen.emptyKey), findsNothing);
      expect(find.text(_refreshingCopy), findsNothing);

      pass.complete();
      hydration.add(HouseholdHydrationState.failed);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.emptyKey), findsOneWidget);
      expect(find.text(_refreshFailedCopy), findsOneWidget);
    });

    testWidgets('the retry keeps an accessible name while it is disabled', (
      tester,
    ) async {
      // `BgeSubmitButton`'s contract, applied to this button: a control
      // that keeps its place must also keep saying what it is doing, or a
      // screen reader announces "Try again, disabled" with no reason.
      final pass = Completer<void>();
      await tester.pumpWidget(harness(onRetry: () => pass.future));
      households.add([_household('h-1')]);
      hydration.add(HouseholdHydrationState.failed);
      await tester.pump();

      await tester.tap(find.byKey(HouseholdListScreen.refreshRetryKey));
      await tester.pump();
      hydration.add(HouseholdHydrationState.running);
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(HouseholdListScreen.refreshRetryKey),
          matching: find.text(_refreshingCopy),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(HouseholdListScreen.refreshRetryKey))
            .onPressed,
        isNull,
      );

      pass.complete();
    });

    testWidgets('a retry that fails again puts the banner back', (
      tester,
    ) async {
      final pass = Completer<void>();
      await tester.pumpWidget(harness(onRetry: () => pass.future));
      households.add([_household('h-1')]);
      hydration.add(HouseholdHydrationState.failed);
      await tester.pump();

      await tester.tap(find.byKey(HouseholdListScreen.refreshRetryKey));
      await tester.pump();
      hydration.add(HouseholdHydrationState.running);
      await tester.pump();
      // Two of them: the banner's message, and the disabled button's own
      // label — it keeps a name rather than becoming a bare spinner
      // (`BgeSubmitButton`'s contract, #163).
      expect(find.text(_refreshingCopy), findsNWidgets(2));

      hydration.add(HouseholdHydrationState.failed);
      pass.complete();
      await tester.pump();
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(find.byKey(HouseholdListScreen.refreshRetryKey), findsOneWidget);
      expect(find.text(_refreshingCopy), findsNothing);
    });

    testWidgets('qualifies an empty list rather than replacing it', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      households.add(const []);
      hydration.add(HouseholdHydrationState.failed);
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(find.byKey(HouseholdListScreen.emptyKey), findsOneWidget);
    });
  });

  testWidgets('surfaces a failed cache read as an error', (tester) async {
    await tester.pumpWidget(harness());
    households.addError(StateError('no authenticated user'));
    await tester.pump();

    expect(find.byKey(HouseholdListScreen.errorKey), findsOneWidget);
    expect(find.text(_errorCopy), findsOneWidget);
  });

  group('the entry trigger (#300 D1, D13, D14)', () {
    testWidgets('asks for a pass once, on entry', (tester) async {
      var entries = 0;
      await tester.pumpWidget(harness(onEnter: () => entries++));
      await tester.pump();

      expect(entries, 1);
    });

    testWidgets('a rebuild does not ask for a second pass', (tester) async {
      // The reason this lives here rather than in the route builder (#300
      // D14). go_router re-runs a route's builder whenever the router
      // rebuilds, and builds every page in the match stack — so a side
      // effect there fires on rebuilds and on pushing a child route, which
      // is a poll rather than an entry. `BlocProvider.create` runs once per
      // provider insertion, which is what "on entry" actually means.
      var entries = 0;
      await tester.pumpWidget(harness(onEnter: () => entries++));
      await tester.pump();

      households.add([_household('h-1')]);
      await tester.pump();
      hydration.add(HouseholdHydrationState.refreshed);
      await tester.pump();
      await tester.pumpWidget(harness(onEnter: () => entries++));
      await tester.pump();

      expect(entries, 1);
    });

    testWidgets('a composition with no pass to run still renders', (
      tester,
    ) async {
      // The #137 path: absent, like `onRetry`, rather than a callback that
      // does nothing.
      await tester.pumpWidget(harness());
      households.add(const []);
      hydration.add(HouseholdHydrationState.refreshed);
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.emptyKey), findsOneWidget);
    });

    testWidgets('the pass it starts is not narrated', (tester) async {
      // #300 D6: only a press narrates. An entry is not a press, so the
      // screen says nothing while the pass it started runs.
      await tester.pumpWidget(harness(onEnter: () {}));
      households.add([_household('h-1')]);
      hydration.add(HouseholdHydrationState.failed);
      await tester.pump();

      hydration.add(HouseholdHydrationState.running);
      await tester.pump();

      expect(find.text(_refreshingCopy), findsNothing);
      expect(find.text(_refreshFailedCopy), findsNothing);
    });
  });
}
