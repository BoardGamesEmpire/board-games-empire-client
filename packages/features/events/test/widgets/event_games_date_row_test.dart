import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/dates_scroller.dart';
import 'package:events/src/widgets/event_games_date_row.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';

const _longName =
    'The Saturday evening game night of the whole group, with supper and '
    'the long campaign';

/// The row of dates above the Games tab's sub-tabs (#1042).
void main() {
  final now = DateTime(2026, 11, 20, 12);
  late ValueNotifier<GamesDateView> selected;
  late List<GamesDateView> chosen;

  /// [count] dates, each named `Date n`, or [name] where it is given.
  List<EventOccurrence> dates(int count, {String? name}) => [
    for (var i = 1; i <= count; i++)
      confirmed(
        'o-$i',
        DateTime(2026, 11, 20 + i, 19),
        sortOrder: i,
      ).copyWith(label: name ?? 'Date $i'),
  ];

  setUp(() {
    selected = ValueNotifier(const EveryDateView());
    addTearDown(selected.dispose);
    chosen = [];
  });

  Widget app(
    List<EventOccurrence> list, {
    ThemeData? theme,
    TransitionBuilder? builder,
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    builder: builder,
    locale: const Locale('en', 'US'),
    localizationsDelegates: EventsLocalizations.localizationsDelegates,
    supportedLocales: EventsLocalizations.supportedLocales,
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: ValueListenableBuilder<GamesDateView>(
          valueListenable: selected,
          builder: (context, view, _) => EventGamesDateRow(
            dates: list,
            selected: view,
            onSelected: chosen.add,
            now: now,
          ),
        ),
      ),
    ),
  );

  Finder chip(String? id) => find.byKey(EventDetailScreen.dateChipKey(id));

  ScrollableState scroller(WidgetTester tester) =>
      tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(EventGamesDateRow),
          matching: find.byType(Scrollable),
        ),
      );

  /// The id of the chip holding focus, `all` for Every date.
  String? focusedChip(WidgetTester tester) {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus == null) return null;
    for (final id in <String?>[null, for (var i = 1; i <= 12; i++) 'o-$i']) {
      final found = find.descendant(
        of: chip(id),
        matching: find.byElementPredicate((e) => e == focus),
      );
      if (found.evaluate().isNotEmpty) return id ?? 'all';
    }
    return null;
  }

  testWidgets('Every date comes first, then each date in order', (
    tester,
  ) async {
    useViewSize(tester, const Size(800, 600));
    await tester.pumpWidget(app(dates(3)));

    final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
    expect(chips, hasLength(4));
    final lefts = [
      for (final id in <String?>[null, 'o-1', 'o-2', 'o-3'])
        tester.getTopLeft(chip(id)).dx,
    ];
    expect([...lefts]..sort(), lefts);
    expect(
      find.descendant(of: chip(null), matching: find.text('Every date')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chip('o-2'), matching: find.text('Date 2')),
      findsOneWidget,
    );
    expect(tester.widget<ChoiceChip>(chip(null)).selected, isTrue);
    expect(tester.widget<ChoiceChip>(chip('o-1')).selected, isFalse);
  });

  testWidgets('tapping a date chooses it', (tester) async {
    useViewSize(tester, const Size(800, 600));
    await tester.pumpWidget(app(dates(3)));

    await tester.tap(chip('o-2'));
    await tester.pump();
    await tester.tap(chip(null));
    await tester.pump();

    expect(chosen, [const OneDateView('o-2'), const EveryDateView()]);
  });

  testWidgets('the chosen chip comes into view on BgeMotion.enter', (
    tester,
  ) async {
    useViewSize(tester, const Size(400, 600));
    await tester.pumpWidget(app(dates(12)));
    final duration = BgeTokens.of(
      tester.element(find.byType(EventGamesDateRow)),
    ).motionShort;

    selected.value = const OneDateView('o-12');
    // The frame that builds the choice starts the scroll as it ends, and
    // the next is the scroll's first tick, with no time gone.
    await tester.pump();
    await tester.pump();
    await tester.pump(duration ~/ 2);
    final halfway = scroller(tester).position.pixels;
    await tester.pumpAndSettle();
    final landed = scroller(tester).position.pixels;

    expect(landed, greaterThan(0));
    expect(halfway / landed, closeTo(BgeMotion.enter.transform(0.5), 0.01));
  });

  testWidgets('the selected chip is scrolled into view', (tester) async {
    useViewSize(tester, const Size(400, 600));
    await tester.pumpWidget(app(dates(12)));
    expect(tester.getRect(chip('o-12')).right, greaterThan(400));

    selected.value = const OneDateView('o-12');
    await tester.pumpAndSettle();

    final rect = tester.getRect(chip('o-12'));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(400));
    expect(scroller(tester).position.pixels, greaterThan(0));

    selected.value = const EveryDateView();
    await tester.pumpAndSettle();
    expect(tester.getRect(chip(null)).left, greaterThanOrEqualTo(0));
  });

  testWidgets('arrow keys and Tab reach every chip', (tester) async {
    useViewSize(tester, const Size(400, 600));
    await tester.pumpWidget(app(dates(12)));

    // Tab visits each chip, scrolling it into view as it lands.
    final visited = <String?>{};
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final id = focusedChip(tester);
      if (id != null) {
        visited.add(id);
        final rect = tester.getRect(chip(id == 'all' ? null : id));
        expect(rect.left, greaterThanOrEqualTo(0), reason: id);
        expect(rect.right, lessThanOrEqualTo(400), reason: id);
      }
    }
    expect(visited, {'all', for (var i = 1; i <= 12; i++) 'o-$i'});
  });

  testWidgets('arrows move focus from chip to chip, stopping at the ends, '
      'with each on screen', (tester) async {
    useViewSize(tester, const Size(400, 600));
    await tester.pumpWidget(app(dates(12)));
    // Focus the first chip.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    if (focusedChip(tester) == null) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    expect(focusedChip(tester), 'all');

    void expectOnScreen(String reason) {
      final id = focusedChip(tester)!;
      final rect = tester.getRect(chip(id == 'all' ? null : id));
      expect(rect.left, greaterThanOrEqualTo(0), reason: reason);
      expect(rect.right, lessThanOrEqualTo(400), reason: reason);
    }

    // At the start, Left stays put.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(focusedChip(tester), 'all');

    for (var i = 1; i <= 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(focusedChip(tester), 'o-$i');
      expectOnScreen('right to o-$i');
    }
    // At the end, Right stays put.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focusedChip(tester), 'o-12');

    for (var i = 11; i >= 1; i--) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(focusedChip(tester), 'o-$i');
      expectOnScreen('left to o-$i');
    }
  });

  testWidgets('arrows swap in a right-to-left row', (tester) async {
    useViewSize(tester, const Size(400, 600));
    await tester.pumpWidget(
      app(
        dates(4),
        builder: (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    if (focusedChip(tester) == null) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    expect(focusedChip(tester), 'all');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(focusedChip(tester), 'o-1');
  });

  testWidgets('Alt+Left on a focused chip is left to the browser', (
    tester,
  ) async {
    useViewSize(tester, const Size(400, 600));
    await tester.pumpWidget(app(dates(4)));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focusedChip(tester), 'o-1');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final result = await simulateKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await simulateKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

    expect(result, isNotNull);
    expect(focusedChip(tester), 'o-1');
  });

  testWidgets('dates that come and go on a mounted row leave focus sensible', (
    tester,
  ) async {
    useViewSize(tester, const Size(400, 600));
    await tester.pumpWidget(app(dates(4)));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focusedChip(tester), 'o-2');

    // The focused chip's date removed.
    await tester.pumpWidget(
      app([
        for (final d in dates(4))
          if (d.id != 'o-2') d,
      ]),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(chip('o-2'), findsNothing);

    // A date added, then the keyboard still walks the chips.
    await tester.pumpWidget(app(dates(5)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(chip('o-5'), findsOneWidget);
    final visited = <String?>{};
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      visited.add(focusedChip(tester));
    }
    expect(visited, containsAll(['all', 'o-1', 'o-5']));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('with the scroller itself focused, the arrows still scroll', (
    tester,
  ) async {
    useViewSize(tester, const Size(400, 600));
    await tester.pumpWidget(app(dates(12)));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(focusedChip(tester), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(scroller(tester).position.pixels, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(scroller(tester).position.pixels, 0);
  });

  testWidgets('the focused scroller is ringed at the focus outline width', (
    tester,
  ) async {
    // A width the row could not have written in itself.
    final light = BgeTheme.light();
    final tokens = light.extension<BgeTokens>()!.copyWith(
      focusOutlineWidth: 3,
    );
    useViewSize(tester, const Size(400, 600));
    await tester.pumpWidget(
      app(
        dates(12),
        theme: light.copyWith(
          extensions: [
            for (final extension in light.extensions.values)
              if (extension is! BgeTokens) extension,
            tokens,
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Dates scroller');

    final ring = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(DatesScroller),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.position == DecorationPosition.foreground,
            ),
          )
          .first,
    );
    final border = (ring.decoration as BoxDecoration).border! as Border;
    expect(border.top.width, 3);
    expect(border.top.color, light.colorScheme.primary);
  });

  testWidgets('with animations disabled a chip chosen from the location lands '
      'in view in a single pump', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    useViewSize(tester, const Size(400, 600));
    await tester.pumpWidget(app(dates(12)));

    selected.value = const OneDateView('o-12');
    await tester.pump();
    final landed = scroller(tester).position.pixels;
    expect(landed, greaterThan(0));
    await tester.pump();
    expect(tester.getRect(chip('o-12')).right, lessThanOrEqualTo(400));
    expect(scroller(tester).position.pixels, landed);
  });

  for (final MapEntry(key: themeName, value: theme) in kAuditThemes.entries) {
    testWidgets('long date labels scale down at 320dp and 200% text with no '
        'overflow, $themeName', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(app(dates(3, name: _longName), theme: theme()));

      expect(tester.takeException(), isNull);
      for (final id in <String?>[null, 'o-1', 'o-2', 'o-3']) {
        final rect = tester.getRect(chip(id));
        expect(rect.width, lessThanOrEqualTo(320), reason: '$id');
        expect(rect.height, greaterThanOrEqualTo(kMinInteractiveDimension));
      }
      final label = find.descendant(
        of: chip('o-1'),
        matching: find.byType(RichText),
      );
      // Drawn smaller than it lays out, never larger.
      expect(
        tester.getRect(label).width,
        lessThan(tester.renderObject<RenderParagraph>(label).size.width),
      );
      expect(
        tester
            .widget<FittedBox>(
              find.descendant(
                of: chip('o-1'),
                matching: find.byType(FittedBox),
              ),
            )
            .fit,
        BoxFit.scaleDown,
      );
    });
  }

  testWidgets('a mouse can drag the row on desktop', (tester) async {
    useViewSize(tester, const Size(400, 800));
    await tester.pumpWidget(
      app(
        dates(12),
        theme: pointerPlatformTheme(),
        builder: underSelectionRegion,
      ),
    );
    expect(scroller(tester).position.pixels, 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(tester.getCenter(chip('o-1')));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await mouse.moveBy(const Offset(-30, 0));
      await tester.pump();
    }
    await mouse.up();
    await tester.pumpAndSettle();

    expect(scroller(tester).position.pixels, greaterThan(100));
    // The drag chose nothing.
    expect(chosen, isEmpty);
  });

  group('accessibility audit', () {
    auditScreen(
      'a row of dates, Every date chosen',
      build: (theme) => app(dates(4), theme: theme),
    );

    auditScreen(
      'a row of long dates, the last chosen',
      build: (theme) {
        selected.value = const OneDateView('o-3');
        return app(dates(3, name: _longName), theme: theme);
      },
    );

    testWidgets('the chips say which is selected, in a group named Dates', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      useViewSize(tester, const Size(800, 600));
      await tester.pumpWidget(app(dates(2)));

      expect(
        tester.getSemantics(chip(null)),
        isSemantics(label: 'Every date', isSelected: true, hasTapAction: true),
      );
      expect(
        tester.getSemantics(chip('o-1')),
        isSemantics(label: 'Date 1', isSelected: false, hasTapAction: true),
      );
      expect(find.bySemanticsLabel('Dates'), findsOneWidget);
      handle.dispose();
    });
  });
}
