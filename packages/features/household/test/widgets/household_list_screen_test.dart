import 'dart:async';
import 'dart:math' as math;

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
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
const _couldNotSyncCopy = "Couldn't sync";
const _refreshFailedCopy =
    "This list may be out of date — we couldn't refresh it.";
const _errorCopy = "We couldn't open your households.";
const _retryCopy = 'Try again';
const _refreshingCopy = 'Refreshing\u2026';
const _refreshCopy = 'Refresh';

/// The four surfaces the list can show (#269), each of which can be
/// refreshed by hand (#314).
enum _Surface { loading, error, empty, rows }

/// Scrolls the list to its very end, checks the Create button leaves a 16dp
/// gap under [lastRow], then taps [lastRow] where the button would reach over
/// it (#467).
///
/// The tap lands on the middle of the horizontal stretch the row and the
/// button share, at the row's mid-height. Aimed at the row's own centre it
/// would miss the button at the phone-on-its-side and desktop windows, where
/// the row is wide and the button sits at its right end, and the case would
/// pass without the page reserving anything.
///
/// The tap alone does not pin the reserve either: it lands at the row's
/// mid-height, so any reserve over about 20dp passes it while the bottom of
/// the row is still under the button. The gap is what pins the amount.
Future<void> _tapLastRowUnderCreate(
  WidgetTester tester, {
  required Finder lastRow,
}) async {
  // The rows are built as they come into view, so the end is known only
  // once it is reached.
  final position = tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position;
  double? end;
  while (end != position.maxScrollExtent) {
    end = position.maxScrollExtent;
    position.jumpTo(end);
    await tester.pumpAndSettle();
  }

  final row = tester.getRect(lastRow);
  final create = tester.getRect(find.byKey(HouseholdListScreen.createFabKey));
  final left = math.max(row.left, create.left);
  final right = math.min(row.right, create.right);
  expect(
    left,
    lessThan(right),
    reason:
        'the row $row and the button $create share no width, so a tap '
        'could never reach the button and this case would pin nothing',
  );
  expect(
    create.top - row.bottom,
    greaterThanOrEqualTo(16),
    reason:
        'the button $create should sit at least 16dp clear of the last '
        'row $row once the list is scrolled to its end',
  );

  await tester.tapAt(Offset((left + right) / 2, row.center.dy));
  await tester.pumpAndSettle();
}

/// Pins the #269 list screen against a mocked repository and a hand-driven
/// hydration status — the four surfaces the decisions specify (loading,
/// empty, rows, error), the stale-rows banner, and the create affordance's
/// guard.
void main() {
  late _MockHouseholdRepository repository;
  late StreamController<List<Household>> households;
  late HouseholdHydrationStatus status;

  setUp(() {
    repository = _MockHouseholdRepository();
    households = StreamController<List<Household>>.broadcast();
    status = HouseholdHydrationStatus();
    when(repository.watchHouseholds).thenAnswer((_) => households.stream);
  });

  tearDown(() {
    unawaited(households.close());
    unawaited(status.close());
  });

  /// A status call the screen must hear before the cache's first answer
  /// goes before this is pumped, so the reading is replayed on subscribe
  /// rather than landing a turn after the cache event beside it.
  Widget harness({
    void Function(BuildContext context)? onCreate,
    void Function(BuildContext context, String householdId)? onOpen,
    Future<void> Function()? onRetry,
    VoidCallback? onEnter,
    TextScaler? textScaler,
    ThemeData? theme,
    TransitionBuilder? builder,
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    // A caller's region goes innermost and the text scaler wraps it, the
    // order `BgeApp` builds: its clamped text scaling is outermost, with the
    // region inside.
    builder: textScaler == null && builder == null
        ? null
        : (context, child) {
            final region = builder == null ? child! : builder(context, child);
            return textScaler == null
                ? region
                : MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: textScaler),
                    child: region,
                  );
          },
    home: HouseholdListScreen(
      repository: repository,
      hydration: status.watch(),
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
    useViewSize(tester, Size(width, 800));
  }

  group('under the selection region (#338)', () {
    Future<void> pumpUnderRegion(
      WidgetTester tester, {
      void Function(BuildContext context, String householdId)? onOpen,
      Future<void> Function()? onRetry,
    }) async {
      useViewSize(tester, const Size(1280, 800));
      status.finished(HydrateOutcome.complete);
      await tester.pumpWidget(
        harness(
          theme: pointerPlatformTheme(),
          builder: underSelectionRegion,
          onOpen: onOpen,
          onRetry: onRetry,
        ),
      );
      households.add([
        for (var i = 1; i <= 30; i++) _household('h-$i', name: 'Crew $i'),
      ]);
      await tester.pumpAndSettle();
    }

    testWidgets('the region is installed', (tester) async {
      await pumpUnderRegion(tester);

      expect(find.byType(SelectableRegion), findsOneWidget);
    });

    testWidgets(
      'a vertical touch drag scrolls the list rather than selecting',
      (
        tester,
      ) async {
        final copies = captureClipboardCopies();
        await pumpUnderRegion(tester);

        final list = tester.state<ScrollableState>(
          find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        );
        expect(list.position.maxScrollExtent, greaterThan(0));
        expect(list.position.pixels, 0);

        await tester.drag(
          find.byKey(HouseholdListScreen.rowKey('h-1')),
          const Offset(0, -400),
        );
        await tester.pumpAndSettle();

        expect(list.position.pixels, greaterThan(0));

        await sendCopyShortcut(tester);
        expect(copies, isEmpty);
      },
    );

    testWidgets('a pull under the selection region refreshes', (
      tester,
    ) async {
      // A touch pull, on the desktop platform the region is installed on:
      // it has to reach the list as a scroll, not start a selection (#314).
      final copies = captureClipboardCopies();
      var calls = 0;
      await pumpUnderRegion(tester, onRetry: () async => calls++);

      // Further than the other groups pull. macOS scrolls with the desktop
      // bouncing physics, whose fast deceleration rate gives an overscroll
      // about a quarter of the finger's travel (friction about 0.26), so
      // arming the indicator takes roughly 0.77 of the viewport plus the
      // touch slop. iOS, at the normal rate, takes about 0.385 of it. 300dp
      // in this 800dp window falls short; measured, 600dp arms it, with the
      // region or without it.
      await tester.fling(
        find.byKey(HouseholdListScreen.rowKey('h-1')),
        const Offset(0, 600),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(calls, 1);
      await tester.pumpAndSettle();
      await sendCopyShortcut(tester);
      expect(copies, isEmpty);
    });

    for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
      testWidgets('a ${kind.name} tap on a row still opens it', (tester) async {
        final opened = <String>[];
        await pumpUnderRegion(tester, onOpen: (_, id) => opened.add(id));

        await tester.tap(
          find.byKey(HouseholdListScreen.rowKey('h-2')),
          kind: kind,
        );
        await tester.pump();

        expect(opened, equals(['h-2']));
      });
    }
  });

  group('while the cache is filling', () {
    testWidgets('shows a spinner rather than an empty state', (tester) async {
      status.started();
      await tester.pumpWidget(harness());
      households.add(const []);
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.loadingKey), findsOneWidget);
      expect(find.text(_emptyTitleCopy), findsNothing);
    });

    testWidgets('shows rows the cache already has', (tester) async {
      // A returning user's cached rows are not hidden behind the refresh.
      status.started();
      await tester.pumpWidget(harness());
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
      status.finished(HydrateOutcome.complete);
      await tester.pumpWidget(harness(onCreate: (_) {}));
      households.add(const []);
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.emptyKey), findsOneWidget);
      expect(find.text(_emptyTitleCopy), findsOneWidget);
    });

    testWidgets('the empty state is announced', (tester) async {
      final handle = tester.ensureSemantics();
      status.finished(HydrateOutcome.complete);
      await tester.pumpWidget(harness(onCreate: (_) {}));
      households.add(const []);
      await tester.pump();

      final title = tester.getSemantics(find.text(_emptyTitleCopy));
      expect(title, isSemantics(isLiveRegion: true));
      expect(title.label, contains(_emptyTitleCopy));
      expect(title.label, contains('A household is the group you share'));
      handle.dispose();
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
      // The repository orders (#269). A screen that re-sorted would be a
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

    testWidgets('every row is outlined (#647)', (tester) async {
      await tester.pumpWidget(harness());
      households.add([_household('h-1'), _household('h-2')]);
      await tester.pump();

      expect(find.byType(BgeOutlinedRow), findsNWidgets(2));
    });

    testWidgets('a focused row is ringed (#758)', (tester) async {
      await tester.pumpWidget(harness(onOpen: (_, _) {}));
      households.add([_household('h-1', name: 'Alpha')]);
      await tester.pump();

      expect(
        await keyboardFocusShowsRing(tester, find.text('Alpha')),
        isTrue,
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

    testWidgets("a stuck household create says Couldn't sync", (tester) async {
      // A stuck op never sends on its own, so "not yet synced" would
      // promise what will not happen (#47).
      await tester.pumpWidget(
        harness(
          onOpen: (_, _) {},
          builder: (context, child) => BgeSyncStatusScope(
            stuck: 1,
            stuckRecordIds: const {'h-1'},
            child: child!,
          ),
        ),
      );
      households.add([
        _household('h-1', isLocalOnly: true, isDirty: true),
        _household('h-2', isLocalOnly: true, isDirty: true),
      ]);
      await tester.pump();

      expect(find.text(_couldNotSyncCopy), findsOneWidget);
      expect(find.text(_notSyncedCopy), findsOneWidget);
      final stuck = find.descendant(
        of: find.byKey(HouseholdListScreen.rowKey('h-1')),
        matching: find.text(_couldNotSyncCopy),
      );
      expect(stuck, findsOneWidget);
      // Read inside the row control's one merged node, as the waiting
      // badge is, and in place of it.
      final semantics = tester.getSemantics(
        find.descendant(
          of: find.byKey(HouseholdListScreen.rowKey('h-1')),
          matching: find.byType(MergeSemantics),
        ),
      );
      expect(semantics, isSemantics(isButton: true));
      expect(semantics.label, contains(_couldNotSyncCopy));
      expect(semantics.label, isNot(contains(_notSyncedCopy)));
    });

    testWidgets('the badge is BgeSyncBadge', (tester) async {
      await tester.pumpWidget(harness());
      households.add([_household('h-1', isLocalOnly: true)]);
      await tester.pump();

      expect(find.byType(BgeSyncBadge), findsOneWidget);
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
        find.descendant(
          of: find.byKey(HouseholdListScreen.rowKey('h-1')),
          matching: find.byType(MergeSemantics),
        ),
      );
      expect(semantics.label, contains(_notSyncedCopy));
    });

    testWidgets('opens a household when its row is tapped', (tester) async {
      // #269 kept rows inert because no detail route existed. #270 built it, so
      // the row is a control.
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
        find.descendant(
          of: find.byKey(HouseholdListScreen.rowKey('h-1')),
          matching: find.byType(MergeSemantics),
        ),
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
        find.descendant(
          of: find.byKey(HouseholdListScreen.rowKey('h-1')),
          matching: find.byType(MergeSemantics),
        ),
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
        find.descendant(
          of: find.byKey(HouseholdListScreen.rowKey('h-1')),
          matching: find.byType(MergeSemantics),
        ),
      );
      expect(semantics, isSemantics(hasTapAction: true));

      // The real keyboard path: focus the row, then press Enter.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(opened, equals(['h-1']));
    });

    testWidgets('a row keeps its focus when a row above it leaves', (
      tester,
    ) async {
      // A purge removes a household the server no longer lists, or a discard
      // deletes a local-only one (#549). Only a row that opens somewhere is
      // a focus stop, so this one is given somewhere to go.
      status.finished(HydrateOutcome.complete);
      await tester.pumpWidget(harness(onOpen: (_, _) {}));
      households.add([
        _household('h-1', name: 'Alpha'),
        _household('h-2', name: 'Bravo'),
      ]);
      await tester.pump();
      FocusNode focusOf(String id, String name) => Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(HouseholdListScreen.rowKey(id)),
            matching: find.text(name),
          ),
        ),
      );
      focusOf('h-2', 'Bravo').requestFocus();
      await tester.pump();
      expect(focusOf('h-2', 'Bravo').hasPrimaryFocus, isTrue);

      // A pass that ends early after purging a household: the row above
      // leaves and the refresh banner appears above the list, in the same
      // frame. The banner is the one thing the status changes on a list that
      // has rows, and it pushes the list one place down its parent, so this
      // is the rebuild the focus has to survive. The first pump delivers the
      // two streams' events, since no frame is scheduled yet to build them
      // in, and the second builds the frame.
      households.add([_household('h-2', name: 'Bravo')]);
      status.finished(HydrateOutcome.failed);
      await tester.pump();
      await tester.pump();

      expect(find.text('Alpha'), findsNothing);
      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(focusOf('h-2', 'Bravo').hasPrimaryFocus, isTrue);
    });

    testWidgets('stays inert content where no detail route is offered', (
      tester,
    ) async {
      // Not a leftover: a composition that cannot reach the detail screen
      // should not offer a tap that does nothing (#269's judgement, now a
      // condition rather than an era).
      await tester.pumpWidget(harness());
      households.add([_household('h-1')]);
      await tester.pump();

      final semantics = tester.getSemantics(
        find.descendant(
          of: find.byKey(HouseholdListScreen.rowKey('h-1')),
          matching: find.byType(MergeSemantics),
        ),
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

  group('focus after the household a row opened is gone (#479)', () {
    // Leaving a household pops its detail screen back to this list, which no
    // longer has the row the user came from. #477's Delete will do the same.

    /// Pushes a page over the list, as the app's route to the detail screen
    /// does.
    void openDetail(BuildContext context, String householdId) =>
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(body: Text('Detail $householdId')),
          ),
        );

    Finder detail() => find.textContaining('Detail ', skipOffstage: false);

    void popDetail(WidgetTester tester) =>
        Navigator.of(tester.element(detail())).pop();

    FocusNode heading(WidgetTester tester) => tester
        .widget<Focus>(find.byKey(HouseholdListScreen.headingKey))
        .focusNode!;

    FocusNode row(WidgetTester tester, String name) =>
        Focus.of(tester.element(find.text(name)), createDependency: false);

    /// Tabs [stops] times from the top of the page, then presses Enter.
    Future<void> openWithKeyboard(WidgetTester tester, {int stops = 1}) async {
      for (var i = 0; i < stops; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(detail(), findsOneWidget);
    }

    /// Hands the list [listed] while the detail covers it, and lets the
    /// covered list rebuild without the rest.
    ///
    /// Two frames: the first delivers the cache's answer and the second
    /// builds it.
    Future<void> dropWhileCovered(
      WidgetTester tester,
      List<Household> listed,
    ) async {
      households.add(listed);
      await tester.pumpAndSettle();
      for (final name in ['Alpha', 'Bravo']) {
        final kept = listed.any((household) => household.name == name);
        expect(
          find.text(name, skipOffstage: false),
          kept ? findsOneWidget : findsNothing,
        );
      }
    }

    final alpha = _household('h-1', name: 'Alpha');
    final bravo = _household('h-2', name: 'Bravo');

    setUp(() => status.finished(HydrateOutcome.complete));

    testWidgets('when the household it opened is gone, focus lands on the '
        'heading', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      await openWithKeyboard(tester);

      await dropWhileCovered(tester, [bravo]);
      popDetail(tester);
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus, same(heading(tester)));
      final node = tester.getSemantics(
        find.byKey(HouseholdListScreen.headingKey),
      );
      expect(node.label, 'Households');
      expect(node, isSemantics(isHeader: true, isFocused: true));
      handle.dispose();
    });

    testWidgets('when the household goes only once the detail has started to '
        'pop, focus still lands on the heading', (tester) async {
      // The app's order: the detail pops as soon as its cache write
      // resolves, and the list's read of the cache answers after that.
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      await openWithKeyboard(tester);

      popDetail(tester);
      await tester.pump();
      households.add([bravo]);
      await tester.pumpAndSettle();

      expect(find.text('Alpha'), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(heading(tester)));
    });

    testWidgets('after a screen reader opened it, focus lands on the heading', (
      tester,
    ) async {
      // A screen reader's tap gives the row no keyboard focus, so focus comes
      // back to the page itself.
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      tester.semantics.tap(find.semantics.byLabel('Alpha'));
      await tester.pumpAndSettle();
      expect(detail(), findsOneWidget);

      await dropWhileCovered(tester, [bravo]);
      popDetail(tester);
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus, same(heading(tester)));
      expect(
        tester.getSemantics(find.byKey(HouseholdListScreen.headingKey)),
        isSemantics(isFocused: true),
      );
      handle.dispose();
    });

    testWidgets('when the household it opened is still listed, focus is left '
        'to the framework', (tester) async {
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      await openWithKeyboard(tester);

      popDetail(tester);
      await tester.pumpAndSettle();

      expect(heading(tester).hasFocus, isFalse);
      expect(row(tester, 'Alpha').hasPrimaryFocus, isTrue);
    });

    testWidgets('after a screen reader opened it, and it is still listed, '
        'focus is left to the framework', (tester) async {
      // Focus comes back to the page itself, as it does when the household
      // is gone. Only a row that went is a reason to move it.
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      tester.semantics.tap(find.semantics.byLabel('Alpha'));
      await tester.pumpAndSettle();
      expect(detail(), findsOneWidget);

      popDetail(tester);
      await tester.pumpAndSettle();

      expect(heading(tester).hasFocus, isFalse);
      expect(FocusManager.instance.primaryFocus, isA<FocusScopeNode>());
      handle.dispose();
    });

    testWidgets('focus the user moved is left alone', (tester) async {
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      await openWithKeyboard(tester);

      await dropWhileCovered(tester, [bravo]);
      popDetail(tester);
      // The user moves on while the detail is still on its way out.
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(heading(tester).hasFocus, isFalse);
      expect(row(tester, 'Bravo').hasPrimaryFocus, isTrue);
    });

    testWidgets('focus the user moves after the row has gone, while the '
        'detail is still leaving, is left alone', (tester) async {
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      await openWithKeyboard(tester);

      popDetail(tester);
      await tester.pump();
      expect(row(tester, 'Alpha').hasPrimaryFocus, isTrue);
      households.add([bravo]);
      await tester.pump();
      expect(find.text('Alpha'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(heading(tester).hasFocus, isFalse);
      expect(row(tester, 'Bravo').hasPrimaryFocus, isTrue);
    });

    testWidgets('focus the user moves before the row goes, and again after, is '
        'left alone', (tester) async {
      // The row isn't focused when it goes, so the framework hands nothing on
      // and the second move is the user's too.
      final charlie = _household('h-3', name: 'Charlie');
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo, charlie]);
      await tester.pump();
      await openWithKeyboard(tester);

      popDetail(tester);
      await tester.pump();
      expect(row(tester, 'Alpha').hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(row(tester, 'Bravo').hasPrimaryFocus, isTrue);
      households.add([bravo, charlie]);
      await tester.pump();
      expect(find.text('Alpha'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(row(tester, 'Charlie').hasPrimaryFocus, isTrue);
      await tester.pumpAndSettle();

      expect(heading(tester).hasFocus, isFalse);
      expect(row(tester, 'Charlie').hasPrimaryFocus, isTrue);
    });

    testWidgets('focus the user moves back onto the row the framework handed '
        'it to is left alone', (tester) async {
      final charlie = _household('h-3', name: 'Charlie');
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo, charlie]);
      await tester.pump();
      await openWithKeyboard(tester, stops: 2);

      await dropWhileCovered(tester, [alpha, charlie]);
      popDetail(tester);
      await tester.pump();
      expect(row(tester, 'Alpha').hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(row(tester, 'Charlie').hasPrimaryFocus, isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(row(tester, 'Alpha').hasPrimaryFocus, isTrue);
      await tester.pumpAndSettle();

      expect(heading(tester).hasFocus, isFalse);
      expect(row(tester, 'Alpha').hasPrimaryFocus, isTrue);
    });

    testWidgets('when the framework hands focus back to a row focused before, '
        'the heading takes it', (tester) async {
      // The page's scope remembers the nodes it has focused, so with the
      // opened row gone the framework goes back to the one before it: here
      // the row above, which the user passed on the way. Which one that is
      // depends on how they got there, and the heading doesn't.
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      await openWithKeyboard(tester, stops: 2);

      await dropWhileCovered(tester, [alpha]);
      popDetail(tester);
      await tester.pump();
      expect(row(tester, 'Alpha').hasPrimaryFocus, isTrue);
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus, same(heading(tester)));
    });

    testWidgets('when the row goes once the detail has started to pop, and the '
        'framework hands focus on to a row focused before, the heading takes '
        'it', (tester) async {
      // Focus comes back to the opened row, which is still listed, and the
      // framework hands it on to the row above when the row goes.
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      await openWithKeyboard(tester, stops: 2);

      popDetail(tester);
      await tester.pump();
      expect(row(tester, 'Bravo').hasPrimaryFocus, isTrue);
      households.add([alpha]);
      await tester.pump();
      expect(find.text('Bravo'), findsNothing);
      expect(row(tester, 'Alpha').hasPrimaryFocus, isTrue);
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus, same(heading(tester)));
    });

    testWidgets('when the row goes in the frame the detail finishes leaving, '
        'the heading takes focus', (tester) async {
      // The row's own node goes at the end of that frame, and focus is on
      // nothing until the framework hands it back after the frame.
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      await openWithKeyboard(tester, stops: 2);
      final leaving = ModalRoute.of(tester.element(detail()))!;
      final exit = leaving.reverseTransitionDuration;
      final above = ModalRoute.of(
        tester.element(find.text('Households', skipOffstage: false)),
      )!.secondaryAnimation!;

      popDetail(tester);
      await tester.pump();
      // The exit's value reaches nothing here, and it ends on the next frame.
      await tester.pump(exit);
      expect(above.status, AnimationStatus.reverse);
      expect(find.text('Bravo'), findsOneWidget);

      households.add([alpha]);
      await tester.pump(const Duration(milliseconds: 1));
      expect(above.status, AnimationStatus.dismissed);
      expect(find.text('Bravo'), findsNothing);
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus, same(heading(tester)));
    });

    testWidgets('when the household goes only after the detail has gone, '
        'focus still lands on the heading', (tester) async {
      // The leave's answer can land after the detail has gone, as when the
      // user pressed Back while it was on its way.
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      await openWithKeyboard(tester);

      popDetail(tester);
      await tester.pumpAndSettle();
      expect(detail(), findsNothing);
      expect(row(tester, 'Alpha').hasPrimaryFocus, isTrue);

      households.add([bravo]);
      await tester.pumpAndSettle();

      expect(find.text('Alpha'), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(heading(tester)));
    });

    testWidgets('when the household goes only after the detail has gone, '
        'focus does not fall back to a row focused before', (tester) async {
      // Left to the framework, focus would go back to the row above, which
      // the user passed on the way.
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      await openWithKeyboard(tester, stops: 2);

      popDetail(tester);
      await tester.pumpAndSettle();
      expect(row(tester, 'Bravo').hasPrimaryFocus, isTrue);

      households.add([alpha]);
      await tester.pumpAndSettle();

      expect(find.text('Bravo'), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(heading(tester)));
    });

    testWidgets('focus the user moves after the detail has gone, before the '
        'household goes, is left alone', (tester) async {
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      await openWithKeyboard(tester);

      popDetail(tester);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(row(tester, 'Bravo').hasPrimaryFocus, isTrue);

      households.add([bravo]);
      await tester.pumpAndSettle();

      expect(heading(tester).hasFocus, isFalse);
      expect(row(tester, 'Bravo').hasPrimaryFocus, isTrue);
    });

    testWidgets('a route opened after the detail has gone, before the '
        'household goes, leaves focus to the framework', (tester) async {
      await tester.pumpWidget(harness(onOpen: openDetail));
      households.add([alpha, bravo]);
      await tester.pump();
      await openWithKeyboard(tester);

      popDetail(tester);
      await tester.pumpAndSettle();
      const other = 'Other page';
      Navigator.of(tester.element(find.text('Alpha'))).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text(other)),
        ),
      );
      await tester.pumpAndSettle();

      await dropWhileCovered(tester, [bravo]);
      Navigator.of(tester.element(find.text(other))).pop();
      await tester.pumpAndSettle();

      expect(find.text(other), findsNothing);
      expect(heading(tester).hasFocus, isFalse);
    });

    testWidgets('a route no row opened, such as Create, leaves focus to the '
        'framework, even with a household gone meanwhile', (tester) async {
      const form = 'Create form';
      await tester.pumpWidget(
        harness(
          onCreate: (context) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text(form)),
            ),
          ),
          onOpen: openDetail,
        ),
      );
      households.add([alpha, bravo]);
      await tester.pump();

      final fab = find.byKey(HouseholdListScreen.createFabKey);

      /// Whether the primary focus is the Create button's own.
      bool fabFocused() {
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused == null) return false;
        return find
            .descendant(
              of: fab,
              matching: find.byElementPredicate((e) => identical(e, focused)),
            )
            .evaluate()
            .isNotEmpty;
      }

      for (var i = 0; i < 6 && !fabFocused(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      expect(fabFocused(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text(form), findsOneWidget);

      await dropWhileCovered(tester, [bravo]);
      Navigator.of(tester.element(find.text(form))).pop();
      await tester.pumpAndSettle();

      expect(find.text(form), findsNothing);
      expect(heading(tester).hasFocus, isFalse);
      expect(fabFocused(), isTrue);
    });
  });

  // The Create button floats over the end of the list (#467). BgePage owns
  // the room that lets the last row scroll clear of it, and this is the
  // screen the bug was found on.
  for (final (label, window) in [
    ('a phone', const Size(360, 640)),
    ('a phone on its side', const Size(640, 360)),
    ('a desktop window', const Size(1024, 768)),
  ]) {
    testWidgets('on $label, the last household opens rather than Create', (
      tester,
    ) async {
      useViewSize(tester, window);
      final opened = <String>[];
      var created = 0;
      await tester.pumpWidget(
        harness(onOpen: (_, id) => opened.add(id), onCreate: (_) => created++),
      );
      households.add([
        for (var i = 1; i <= 20; i++) _household('h-$i', name: 'Home $i'),
      ]);
      await tester.pump();

      await _tapLastRowUnderCreate(
        tester,
        lastRow: find.byKey(HouseholdListScreen.rowKey('h-20')),
      );

      expect(created, 0, reason: 'Create took the tap');
      expect(opened, ['h-20']);
    });
  }

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
      status.finished(HydrateOutcome.failed);
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(find.byKey(HouseholdListScreen.rowKey('h-1')), findsOneWidget);
    });

    testWidgets('clears when a re-hydrate refreshes the list, with nothing '
        'asked of the user (#302)', (tester) async {
      // The #302 re-run drives the same status holder the screen is
      // already watching (#270), so the banner going away is the whole of what
      // the household feature had to do for that issue.
      await tester.pumpWidget(harness());
      households.add([_household('h-1')]);
      status.finished(HydrateOutcome.failed);
      await tester.pump();
      expect(find.text(_refreshFailedCopy), findsOneWidget);

      status.started();
      await tester.pump();
      await tester.pump();
      // The rows are no fresher while it runs, so the warning stays until
      // the pass lands (#453).
      expect(find.text(_refreshFailedCopy), findsOneWidget);

      // Two pumps: this reading is the first change since the pass started,
      // so no frame is scheduled to build it in. The first pump delivers it
      // and the second builds the frame.
      status.finished(HydrateOutcome.complete);
      await tester.pump();
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsNothing);
      expect(find.byKey(HouseholdListScreen.rowKey('h-1')), findsOneWidget);
    });

    testWidgets('offers a retry where the composition can run one (#300)', (
      tester,
    ) async {
      await tester.pumpWidget(harness(onRetry: () async {}));
      households.add([_household('h-1')]);
      status.finished(HydrateOutcome.failed);
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.refreshRetryKey), findsOneWidget);
      expect(find.text(_retryCopy), findsOneWidget);
    });

    testWidgets('offers none where it cannot (#137)', (tester) async {
      // A container with no household client has no drain to re-run, and a
      // button that does nothing is worse than no button (#269's reasoning,
      // applied to this control).
      await tester.pumpWidget(harness());
      households.add([_household('h-1')]);
      status.finished(HydrateOutcome.failed);
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(find.byKey(HouseholdListScreen.refreshRetryKey), findsNothing);
    });

    testWidgets('pressing it runs a pass and says so (#300)', (
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
      status.finished(HydrateOutcome.failed);
      await tester.pump();

      await tester.tap(find.byKey(HouseholdListScreen.refreshRetryKey));
      await tester.pump();
      status.started();
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
      status.finished(HydrateOutcome.complete);
      await tester.pump();
      await tester.pump();

      expect(find.text(_refreshingCopy), findsNothing);
      expect(find.text(_refreshFailedCopy), findsNothing);
    });

    testWidgets('a pass nobody asked for is not announced (#300)', (
      tester,
    ) async {
      // #302's triggers re-hydrate on a connectivity edge and on app
      // resume. The banner keeps its failed copy until the pass lands, and
      // clearing then is all the user should see of it (#453); narrating
      // it would put a message on screen for work they did not ask for.
      await tester.pumpWidget(harness(onRetry: () async {}));
      households.add([_household('h-1')]);
      status.finished(HydrateOutcome.failed);
      await tester.pump();

      status.started();
      await tester.pump();
      await tester.pump();

      expect(find.text(_refreshingCopy), findsNothing);
      expect(find.text(_refreshFailedCopy), findsOneWidget);
    });

    testWidgets('a pass nobody asked for does not take focus off the retry', (
      tester,
    ) async {
      // A banner that dropped when any pass started took its retry, and a
      // keyboard user's place, with it (#453).
      FocusNode retryFocus() => Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(HouseholdListScreen.refreshRetryKey),
            matching: find.text(_retryCopy),
          ),
        ),
      );

      status.finished(HydrateOutcome.failed);
      await tester.pumpWidget(harness(onRetry: () async {}));
      households.add([_household('h-1')]);
      await tester.pump();
      retryFocus().requestFocus();
      await tester.pump();
      expect(retryFocus().hasPrimaryFocus, isTrue);

      status.started();
      await tester.pump();
      await tester.pump();

      expect(retryFocus().hasPrimaryFocus, isTrue);
    });

    testWidgets('retrying an empty list shows the spinner, not a banner over '
        '"no households yet"', (tester) async {
      final pass = Completer<void>();
      await tester.pumpWidget(harness(onRetry: () => pass.future));
      households.add(const []);
      status.finished(HydrateOutcome.failed);
      await tester.pump();
      expect(find.byKey(HouseholdListScreen.emptyKey), findsOneWidget);

      await tester.tap(find.byKey(HouseholdListScreen.refreshRetryKey));
      await tester.pump();
      status.started();
      await tester.pump();

      // #269: an empty cache being refilled is unknown, not empty. The whole
      // surface becomes the spinner rather than an empty state wearing a
      // "refreshing" banner.
      expect(find.byKey(HouseholdListScreen.loadingKey), findsOneWidget);
      expect(find.byKey(HouseholdListScreen.emptyKey), findsNothing);
      expect(find.text(_refreshingCopy), findsNothing);

      pass.complete();
      status.finished(HydrateOutcome.failed);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.emptyKey), findsOneWidget);
      expect(find.text(_refreshFailedCopy), findsOneWidget);
    });

    testWidgets('the retry keeps an accessible name while it is busy', (
      tester,
    ) async {
      // `BgeSubmitButton`'s contract, applied to this button: a control
      // that keeps its place must also keep saying what it is doing, or a
      // screen reader announces a bare "Try again" with no sign it is busy.
      final pass = Completer<void>();
      await tester.pumpWidget(harness(onRetry: () => pass.future));
      households.add([_household('h-1')]);
      status.finished(HydrateOutcome.failed);
      await tester.pump();

      await tester.tap(find.byKey(HouseholdListScreen.refreshRetryKey));
      await tester.pump();
      status.started();
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
        // Enabled and inert, so it keeps focus (#607).
        isNotNull,
      );

      pass.complete();
    });

    testWidgets('a retry that fails again puts the banner back', (
      tester,
    ) async {
      final pass = Completer<void>();
      await tester.pumpWidget(harness(onRetry: () => pass.future));
      households.add([_household('h-1')]);
      status.finished(HydrateOutcome.failed);
      await tester.pump();

      await tester.tap(find.byKey(HouseholdListScreen.refreshRetryKey));
      await tester.pump();
      status.started();
      await tester.pump();
      // Two of them: the banner's message, and the disabled button's own
      // label — it keeps a name rather than becoming a bare spinner
      // (`BgeSubmitButton`'s contract, #163).
      expect(find.text(_refreshingCopy), findsNWidgets(2));

      status.finished(HydrateOutcome.failed);
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
      status.finished(HydrateOutcome.failed);
      await tester.pump();

      expect(find.text(_refreshFailedCopy), findsOneWidget);
      expect(find.byKey(HouseholdListScreen.emptyKey), findsOneWidget);
    });
  });

  group('refreshing by hand (#314)', () {
    /// Pumps the screen on [surface], reached the way the groups above reach
    /// it, and checks it is the one showing.
    Future<void> pumpOn(
      WidgetTester tester,
      _Surface surface, {
      Future<void> Function()? onRetry,
      void Function(BuildContext context, String householdId)? onOpen,
    }) async {
      switch (surface) {
        case _Surface.loading:
          status.started();
        case _Surface.error:
          break;
        case _Surface.empty || _Surface.rows:
          status.finished(HydrateOutcome.complete);
      }
      await tester.pumpWidget(harness(onRetry: onRetry, onOpen: onOpen));
      switch (surface) {
        case _Surface.loading || _Surface.empty:
          households.add(const []);
        case _Surface.error:
          households.addError(StateError('no authenticated user'));
        case _Surface.rows:
          households.add([
            _household('h-1', name: 'Alpha'),
            _household('h-2', name: 'Bravo'),
          ]);
      }
      await tester.pump();
      expect(
        find.byKey(switch (surface) {
          _Surface.loading => HouseholdListScreen.loadingKey,
          _Surface.error => HouseholdListScreen.errorKey,
          _Surface.empty => HouseholdListScreen.emptyKey,
          _Surface.rows => HouseholdListScreen.rowKey('h-1'),
        }),
        findsOneWidget,
      );
    }

    /// A touch pull down from the top of the list, held for the indicator to
    /// snap into place and call for the refresh.
    Future<void> pull(WidgetTester tester) async {
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 300),
        1000,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    Finder button() => find.byKey(HouseholdListScreen.refreshButtonKey);

    FocusNode buttonFocus(WidgetTester tester) =>
        tester.widget<IconButton>(button()).focusNode!;

    for (final surface in _Surface.values) {
      testWidgets('the app bar has a refresh button: ${surface.name}', (
        tester,
      ) async {
        await pumpOn(tester, surface, onRetry: () async {});

        expect(
          find.descendant(of: find.byType(AppBar), matching: button()),
          findsOneWidget,
        );
      });

      testWidgets('the button sends the retry: ${surface.name}', (
        tester,
      ) async {
        var calls = 0;
        await pumpOn(tester, surface, onRetry: () async => calls++);

        await tester.tap(button());
        await tester.pump();

        expect(calls, 1);
      });

      testWidgets('no seam, no gesture and no button: ${surface.name}', (
        tester,
      ) async {
        await pumpOn(tester, surface);

        expect(button(), findsNothing);
        expect(find.byType(RefreshIndicator), findsNothing);
      });
    }

    testWidgets('a pull sends the retry and the spinner holds until the pass '
        'ends', (tester) async {
      final pass = Completer<void>();
      var calls = 0;
      await pumpOn(
        tester,
        _Surface.rows,
        onRetry: () {
          calls++;
          return pass.future;
        },
      );

      await pull(tester);

      expect(calls, 1);
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      // The banner narrates the same pass.
      expect(find.byKey(HouseholdListScreen.refreshBannerKey), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);

      pass.complete();
      await tester.pumpAndSettle();

      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(find.byKey(HouseholdListScreen.refreshBannerKey), findsNothing);
    });

    testWidgets('a pull from the loading state refreshes', (tester) async {
      var calls = 0;
      await pumpOn(tester, _Surface.loading, onRetry: () async => calls++);

      await pull(tester);

      expect(calls, 1);
    });

    testWidgets('a pull from the empty state refreshes', (tester) async {
      var calls = 0;
      await pumpOn(tester, _Surface.empty, onRetry: () async => calls++);

      await pull(tester);

      expect(calls, 1);
      await tester.pumpAndSettle();
    });

    testWidgets('a pull from the error state refreshes', (tester) async {
      var calls = 0;
      await pumpOn(tester, _Surface.error, onRetry: () async => calls++);

      await pull(tester);

      expect(calls, 1);
      await tester.pumpAndSettle();
    });

    testWidgets('the button keeps focus through its own pass', (tester) async {
      final handle = tester.ensureSemantics();
      final pass = Completer<void>();
      var calls = 0;
      await pumpOn(
        tester,
        _Surface.rows,
        onRetry: () {
          calls++;
          return pass.future;
        },
      );
      buttonFocus(tester).requestFocus();
      await tester.pump();
      final node = FocusManager.instance.primaryFocus;
      expect(node, same(buttonFocus(tester)));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(calls, 1);
      expect(
        tester.getSemantics(find.byType(BgeRefreshButton)).label,
        _refreshingCopy,
      );
      expect(FocusManager.instance.primaryFocus, same(node));
      expect(buttonFocus(tester), same(node));

      pass.complete();
      await tester.pump();
      await tester.pump();

      expect(
        tester.getSemantics(find.byType(BgeRefreshButton)).label,
        _refreshCopy,
      );
      expect(FocusManager.instance.primaryFocus, same(node));
      // In the body: the framework checks for a live handle before
      // teardowns run, so `addTearDown(handle.dispose)` fails the test.
      handle.dispose();
    });

    // The error surface has no banner and the loading one only a spinner, so
    // the button's label is what says the press was taken (#314).
    for (final surface in [_Surface.error, _Surface.loading]) {
      testWidgets('on the ${surface.name} surface, the button says a pass is '
          'running until it ends', (tester) async {
        final handle = tester.ensureSemantics();
        final pass = Completer<void>();
        await pumpOn(tester, surface, onRetry: () => pass.future);
        expect(
          tester.getSemantics(find.byType(BgeRefreshButton)).label,
          _refreshCopy,
        );

        await tester.tap(button());
        await tester.pump();
        await tester.pump();

        expect(
          tester.getSemantics(find.byType(BgeRefreshButton)).label,
          _refreshingCopy,
        );
        expect(find.byTooltip(_refreshingCopy), findsOneWidget);

        pass.complete();
        await tester.pump();
        await tester.pump();

        expect(
          tester.getSemantics(find.byType(BgeRefreshButton)).label,
          _refreshCopy,
        );
        expect(find.byTooltip(_refreshCopy), findsOneWidget);
        handle.dispose();
      });
    }

    testWidgets('a pull during a pass the button started joins it', (
      tester,
    ) async {
      final pass = Completer<void>();
      var calls = 0;
      await pumpOn(
        tester,
        _Surface.rows,
        onRetry: () {
          calls++;
          return pass.future;
        },
      );
      await tester.tap(button());
      await tester.pump();
      await tester.pump();
      expect(calls, 1);

      await pull(tester);

      // No second pass, and the pull's spinner waits on the first.
      expect(calls, 1);
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);

      pass.complete();
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.byType(RefreshProgressIndicator), findsNothing);
    });

    testWidgets('a row keeps focus while the banner comes and goes', (
      tester,
    ) async {
      final pass = Completer<void>();
      await pumpOn(
        tester,
        _Surface.rows,
        onRetry: () => pass.future,
        onOpen: (_, _) {},
      );
      FocusNode rowFocus() => Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(HouseholdListScreen.rowKey('h-1')),
            matching: find.text('Alpha'),
          ),
        ),
      );
      rowFocus().requestFocus();
      await tester.pump();
      final row = rowFocus();
      expect(row.hasPrimaryFocus, isTrue);

      await tester.tap(button());
      await tester.pump();
      await tester.pump();

      // The banner arrives above the rows, moving them one place down.
      expect(find.byKey(HouseholdListScreen.refreshBannerKey), findsOneWidget);
      expect(rowFocus(), same(row));
      expect(row.hasPrimaryFocus, isTrue);

      pass.complete();
      await tester.pump();
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.refreshBannerKey), findsNothing);
      expect(rowFocus(), same(row));
      expect(row.hasPrimaryFocus, isTrue);
    });
  });

  testWidgets('surfaces a failed cache read as an error', (tester) async {
    await tester.pumpWidget(harness());
    households.addError(StateError('no authenticated user'));
    await tester.pump();

    expect(find.byKey(HouseholdListScreen.errorKey), findsOneWidget);
    expect(find.text(_errorCopy), findsOneWidget);
  });

  group('accessibility audit', () {
    /// Rows enough to run below the fold at 320dp × 2.0.
    List<Household> manyRows() => [
      _household('h-1', name: 'Sunday Crew', isDirty: true),
      for (var i = 2; i <= 10; i++) _household('h-$i', name: 'Group $i'),
    ];

    /// The screen as the shell composes it: with `onOpen`, so each row is
    /// the button the app draws, held to the tap-target and label checks. An
    /// inert row is what a composition with no detail route gets, and the
    /// shell always has one. With a retry too, so the app bar's refresh
    /// button is held to the same checks in every state (#314); the shell
    /// passes one wherever it has a household client.
    Widget Function(ThemeData) screen({
      bool started = false,
      HydrateOutcome? finished,
      Future<void> Function()? onRetry,
      bool seam = true,
    }) => (theme) {
      if (started) status.started();
      if (finished != null) status.finished(finished);
      return harness(
        theme: theme,
        onCreate: (_) {},
        onOpen: (_, _) {},
        onRetry: seam ? onRetry ?? () async {} : null,
      );
    };

    /// The app bar's refresh button, at rest or busy.
    void expectRefreshButton({bool refreshing = false}) {
      expect(find.byKey(HouseholdListScreen.refreshButtonKey), findsOneWidget);
      expect(
        find.byTooltip(refreshing ? _refreshingCopy : _refreshCopy),
        findsOneWidget,
      );
    }

    auditScreen(
      'loading',
      build: screen(started: true),
      settle: false,
      arrange: (tester) async {
        households.add(const []);
        await tester.pump();
        expect(find.byKey(HouseholdListScreen.loadingKey), findsOneWidget);
        expectRefreshButton();
      },
    );

    auditScreen(
      'empty, with Create',
      build: screen(finished: HydrateOutcome.complete),
      arrange: (tester) async {
        households.add(const []);
        await tester.pumpAndSettle();
        expect(find.byKey(HouseholdListScreen.emptyCreateKey), findsOneWidget);
        expectRefreshButton();
      },
    );

    auditScreen(
      'ready, with a row not yet synced',
      build: screen(finished: HydrateOutcome.complete),
      arrange: (tester) async {
        households.add(manyRows());
        await tester.pumpAndSettle();
        expect(find.text('Sunday Crew'), findsOneWidget);
        expect(find.text(_notSyncedCopy), findsOneWidget);
        expect(find.byKey(HouseholdListScreen.createFabKey), findsOneWidget);
        expectRefreshButton();
      },
    );

    auditScreen(
      'ready, scrolled to the end',
      build: screen(finished: HydrateOutcome.complete),
      arrange: (tester) async {
        households.add(manyRows());
        await tester.pumpAndSettle();
        await scrollListToEnd(
          tester,
          find.byKey(HouseholdListScreen.rowKey('h-10')),
          // The wider, taller view holds all ten rows; only the narrow one
          // has anything below the fold.
          mustScroll:
              tester.view.physicalSize.width / tester.view.devicePixelRatio <=
              320,
        );
        expect(find.byKey(HouseholdListScreen.createFabKey), findsOneWidget);
        expectRefreshButton();
      },
    );

    auditScreen(
      'ready, with no refresh seam',
      build: screen(finished: HydrateOutcome.complete, seam: false),
      arrange: (tester) async {
        households.add(manyRows());
        await tester.pumpAndSettle();
        expect(find.text('Sunday Crew'), findsOneWidget);
        expect(
          find.byKey(HouseholdListScreen.refreshButtonKey),
          findsNothing,
        );
      },
    );

    auditScreen(
      'stream error',
      build: screen(finished: HydrateOutcome.complete),
      arrange: (tester) async {
        households.addError(StateError('no authenticated user'));
        await tester.pumpAndSettle();
        expect(find.byKey(HouseholdListScreen.errorKey), findsOneWidget);
        expectRefreshButton();
      },
    );

    auditScreen(
      'refresh failed, with retry',
      build: screen(finished: HydrateOutcome.failed, onRetry: () async {}),
      arrange: (tester) async {
        households.add(manyRows());
        await tester.pumpAndSettle();
        expect(find.text(_refreshFailedCopy), findsOneWidget);
        expect(find.byKey(HouseholdListScreen.refreshRetryKey), findsOneWidget);
        expectRefreshButton();
      },
    );

    auditScreen(
      'refreshing',
      build: screen(
        finished: HydrateOutcome.failed,
        onRetry: () => Completer<void>().future,
      ),
      settle: false,
      arrange: (tester) async {
        // Six rows, not ten: with the 8dp each row now leaves beneath it
        // (#647), the last two sit under the Create button in the tall view
        // and the audit reads their words against its colour.
        households.add(manyRows().take(6).toList());
        await tester.pump();
        await tester.tap(find.byKey(HouseholdListScreen.refreshRetryKey));
        await tester.pump();
        status.started();
        await tester.pump();
        expect(find.text(_refreshingCopy), findsNWidgets(2));
        expectRefreshButton(refreshing: true);
      },
    );
  });

  group('the entry trigger (#300)', () {
    testWidgets('asks for a pass once, on entry', (tester) async {
      var entries = 0;
      await tester.pumpWidget(harness(onEnter: () => entries++));
      await tester.pump();

      expect(entries, 1);
    });

    testWidgets('a rebuild does not ask for a second pass', (tester) async {
      // The reason this lives here rather than in the route builder (#300).
      // go_router re-runs a route's builder whenever the router rebuilds, and
      // builds every page in the match stack — so a side effect there fires on
      // rebuilds and on pushing a child route, which is a poll rather than an
      // entry. `BlocProvider.create` runs once per provider insertion, which is
      // what "on entry" actually means.
      var entries = 0;
      await tester.pumpWidget(harness(onEnter: () => entries++));
      await tester.pump();

      households.add([_household('h-1')]);
      await tester.pump();
      status.finished(HydrateOutcome.complete);
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
      status.finished(HydrateOutcome.complete);
      await tester.pump();

      expect(find.byKey(HouseholdListScreen.emptyKey), findsOneWidget);
    });

    testWidgets('the pass it starts is not narrated', (tester) async {
      // #300: only a press narrates. An entry is not a press, so the screen
      // says nothing while the pass it started runs. The failure it may be
      // about to clear stays up until it does (#453).
      await tester.pumpWidget(harness(onEnter: () {}));
      households.add([_household('h-1')]);
      status.finished(HydrateOutcome.failed);
      await tester.pump();

      status.started();
      await tester.pump();
      await tester.pump();

      expect(find.text(_refreshingCopy), findsNothing);
      expect(find.text(_refreshFailedCopy), findsOneWidget);
    });
  });
}
