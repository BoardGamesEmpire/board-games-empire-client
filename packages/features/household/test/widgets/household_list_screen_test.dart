import 'dart:async';

import 'package:flutter/material.dart';
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
}
