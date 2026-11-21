import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/l10n/events_localizations_en.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:flutter/foundation.dart'
    show SynchronousFuture, ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_filters/game_filters.dart' show GameFiltersLocalizations;
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';
import '../support/fake_event_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

/// The app's English, with a Details tab label too long for its half of the
/// bar at 320dp and 200% text, as another language's could be.
class _LongDetailsLabel extends EventsLocalizationsEn {
  @override
  String get eventsDetailTabDetails => 'Everything about this event';
}

class _LongDetailsLabelDelegate
    extends LocalizationsDelegate<EventsLocalizations> {
  const _LongDetailsLabelDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'en';

  @override
  Future<EventsLocalizations> load(Locale locale) =>
      SynchronousFuture(_LongDetailsLabel());

  @override
  bool shouldReload(_LongDetailsLabelDelegate old) => false;
}

/// The tab bar on `EventDetailScreen` (#516), where it is narrowest and its
/// labels are largest: at 320dp and 200% text; and the tab the screen's
/// location names, and the changes it reports (#856).
void main() {
  // Local, as the device's clock reads it.
  final now = DateTime(2026, 10, 23, 18);

  late _MockEventRepository repository;
  late StreamController<EventDetail?> cache;

  /// Event `e-1`, hosted by the viewer, with a date ahead and someone else
  /// on the roster.
  final viewer = attendance(
    EventParticipationStatus.attending,
  ).copyWith(eventId: 'e-1', displayName: 'Me', role: EventRole.host);
  final hosted = EventDetail(
    snapshot: EventSnapshot(
      event: item('e-1', title: 'Catan night').event,
      occurrences: [
        confirmed('o-1', DateTime(2026, 11, 6, 19)).copyWith(eventId: 'e-1'),
      ],
      attendees: [
        viewer,
        EventAttendee(
          id: 'att-2',
          eventId: 'e-1',
          userId: 'user-att-2',
          displayName: 'Ada',
          role: EventRole.participant,
          status: EventParticipationStatus.attending,
          createdAt: kItemInstant,
          updatedAt: kItemInstant,
        ),
      ],
    ),
    attendance: viewer,
  );

  /// [hosted] with a second date, a week after its first: an event with a
  /// row of dates (#1042), which opens on its first.
  final twoDated = hosted.copyWith(
    snapshot: hosted.snapshot.copyWith(
      occurrences: [
        ...hosted.snapshot.occurrences,
        confirmed(
          'o-2',
          DateTime(2026, 11, 13, 19),
          sortOrder: 1,
        ).copyWith(eventId: 'e-1'),
      ],
    ),
  );

  /// [twoDated] with a third date, a week after its second, which the
  /// cache can lack while the server has it (#1042).
  final threeDated = twoDated.copyWith(
    snapshot: twoDated.snapshot.copyWith(
      occurrences: [
        ...twoDated.snapshot.occurrences,
        confirmed(
          'o-3',
          DateTime(2026, 11, 20, 19),
          sortOrder: 2,
        ).copyWith(eventId: 'e-1'),
      ],
    ),
  );

  setUpAll(() {
    registerFallbackValue(hosted.snapshot);
    registerFallbackValue(EventAccessSource.read);
  });

  setUp(() {
    repository = _MockEventRepository();
    cache = StreamController<EventDetail?>.broadcast();
    when(() => repository.watchEvent(any())).thenAnswer((_) => cache.stream);
    when(
      () => repository.cacheEvent(any(), source: any(named: 'source')),
    ).thenAnswer((_) async {});
    when(() => repository.lastWrite(any())).thenAnswer((_) async => 7);
  });

  tearDown(() {
    unawaited(cache.close());
  });

  /// Ada's Azul, offered to the pool, where a test serves a pool.
  const azul = OfferedGame(
    id: 'o-1',
    attendeeId: 'att-2',
    collectionId: 'col-1',
    platformGameId: 'pg-1',
    gameId: 'g-1',
    title: 'Azul',
    platformName: 'Tabletop',
    medium: GameMedium.physical,
  );

  /// The screen with a server and a way back, as the app opens it, so it
  /// shows the tabs; with [longLabel], a Details label too long for its tab.
  /// The pool is [pool], none unless a test says otherwise, served by
  /// [remote] where a test holds one.
  ///
  /// The screen's `tab` is [location]'s value, and its `date` is [date]'s,
  /// and the screen is built again with each new one, as the router builds it
  /// for a new location (#856, #1042). Each change the screen reports goes to
  /// [onLocationChanged].
  Widget app({
    ThemeData? theme,
    bool longLabel = false,
    List<OfferedGame> pool = const [],
    FakeEventRemote? remote,
    ValueListenable<String?>? location,
    ValueListenable<String?>? date,
    EventLocationChanged? onLocationChanged,
  }) {
    // Nobody has offered a game, unless a test says otherwise: the pool is
    // the empty state, under its header. Its rows are audited with the tab's
    // own suite.
    final server =
        remote ??
        FakeEventRemote.detail((_) => hosted.snapshot, pool: (_) => pool);
    final lease = FakeSessionLease();
    Widget screen(String? tab, String? date) => EventDetailScreen(
      eventId: 'e-1',
      repository: repository,
      session: lease,
      remote: server,
      onBack: (_) {},
      now: () => now,
      tab: tab,
      date: date,
      onLocationChanged: onLocationChanged,
    );

    return MaterialApp(
      theme: theme ?? BgeTheme.light(),
      locale: const Locale('en', 'US'),
      // The first delegate for a type wins.
      localizationsDelegates: [
        if (longLabel) const _LongDetailsLabelDelegate(),
        ...EventsLocalizations.localizationsDelegates,
        // The Games tab's Filters, its sheet and its chips (#851).
        GameFiltersLocalizations.delegate,
      ],
      supportedLocales: EventsLocalizations.supportedLocales,
      home: location == null
          ? screen(null, date?.value)
          : ListenableBuilder(
              listenable: Listenable.merge([location, date]),
              builder: (_, _) => screen(location.value, date?.value),
            ),
    );
  }

  /// [app] as it opens, in [theme].
  Widget harness([ThemeData? theme]) => app(theme: theme);

  /// Shows the hosted event, and lets the read it starts end.
  Future<void> showing(WidgetTester tester) async {
    cache.add(hosted);
    await tester.pumpAndSettle();
    expect(find.text('Catan night'), findsOneWidget);
  }

  Finder tab(EventDetailTab which) =>
      find.byKey(EventDetailScreen.tabKey(which));

  /// One of the Games tab's sub-tabs (#945).
  Finder section(EventGamesSection which) =>
      find.byKey(EventDetailScreen.sectionTabKey(which));

  /// Each sub-tab's label.
  const sectionLabels = {
    EventGamesSection.lineup: 'Lineup',
    EventGamesSection.nominations: 'Nominations',
    EventGamesSection.pool: 'Pool',
  };

  /// The Games tab's body (#516). A sliver group, which a finder that skips
  /// what isn't on screen would pass over.
  Finder gamesBody() =>
      find.byKey(EventDetailScreen.gamesBodyKey, skipOffstage: false);

  group('accessibility audit', () {
    /// The screen at 320×640 and 200% text, the narrowest window at the
    /// largest text, as a device's setting applies it.
    Future<void> showNarrow(
      WidgetTester tester, {
      bool longLabel = false,
      ThemeData? theme,
    }) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(app(longLabel: longLabel, theme: theme));
      await showing(tester);
    }

    /// [label] in the tab [control], a top tab or a sub-tab, is whole: on
    /// one line, not cut short, and drawn inside its tab, scaled down to fit
    /// rather than clipped.
    void expectWholeLabel(WidgetTester tester, Finder control, String label) {
      final text = find.descendant(of: control, matching: find.text(label));
      expect(text, findsOneWidget, reason: label);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)),
      );
      expect(paragraph.didExceedMaxLines, isFalse, reason: label);
      final tabRect = tester.getRect(control);
      final textRect = tester.getRect(text);
      expect(textRect.left, greaterThanOrEqualTo(tabRect.left), reason: label);
      expect(textRect.right, lessThanOrEqualTo(tabRect.right), reason: label);
      expect(textRect.top, greaterThanOrEqualTo(tabRect.top), reason: label);
      expect(
        textRect.bottom,
        lessThanOrEqualTo(tabRect.bottom),
        reason: label,
      );
    }

    testWidgets('the bar lays out with no overflow at 320dp and 200% text', (
      tester,
    ) async {
      await showNarrow(tester);

      expect(tester.takeException(), isNull);
      final bar = tester.getRect(find.byKey(EventDetailScreen.tabBarKey));
      expect(bar.right, lessThanOrEqualTo(320));
      for (final which in EventDetailTab.values) {
        final rect = tester.getRect(tab(which));
        expect(rect.left, greaterThanOrEqualTo(bar.left), reason: '$which');
        expect(rect.right, lessThanOrEqualTo(bar.right), reason: '$which');
      }
    });

    testWidgets('both labels are whole at 320dp and 200% text', (
      tester,
    ) async {
      await showNarrow(tester);

      for (final (which, label) in [
        (EventDetailTab.details, 'Details'),
        (EventDetailTab.games, 'Games'),
      ]) {
        expectWholeLabel(tester, tab(which), label);
      }
    });

    for (final MapEntry(key: themeName, value: theme) in kAuditThemes.entries) {
      testWidgets('every sub-tab label is whole, and each tab says where it '
          'stands, at 320dp and 200% text, $themeName', (tester) async {
        final handle = tester.ensureSemantics();
        try {
          await showNarrow(tester, theme: theme());
          await tester.tap(tab(EventDetailTab.games));
          await tester.pumpAndSettle();

          for (final which in EventGamesSection.values) {
            final label = sectionLabels[which]!;
            expectWholeLabel(tester, section(which), label);
            expect(
              tester.getSemantics(section(which)),
              isSemantics(isSelected: which == EventGamesSection.lineup),
              reason: label,
            );
            expect(
              tester.getSemantics(section(which)).label,
              contains('${which.index + 1} of 3'),
              reason: label,
            );
            expect(
              tester.getSemantics(section(which)).rect.shortestSide,
              greaterThanOrEqualTo(kMinInteractiveDimension),
              reason: label,
            );
          }
        } finally {
          handle.dispose();
        }
      });
    }

    for (final MapEntry(key: themeName, value: theme) in kAuditThemes.entries) {
      testWidgets('the bar lays out three sub-tabs with no overflow and whole '
          'labels at 320dp and 200% text, $themeName', (tester) async {
        await showNarrow(tester, theme: theme());
        await tester.tap(tab(EventDetailTab.games));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(EventGamesSection.values, hasLength(3));
        final bar = tester.getRect(find.byKey(EventDetailScreen.sectionBarKey));
        expect(bar.left, greaterThanOrEqualTo(0));
        expect(bar.right, lessThanOrEqualTo(320));
        var previousRight = bar.left;
        for (final which in EventGamesSection.values) {
          final label = sectionLabels[which]!;
          final tabRect = tester.getRect(section(which));
          expect(tabRect.left, greaterThanOrEqualTo(bar.left), reason: label);
          expect(tabRect.right, lessThanOrEqualTo(bar.right), reason: label);
          // In order, without overlap: Lineup first.
          expect(
            tabRect.left,
            greaterThanOrEqualTo(previousRight - 0.5),
            reason: label,
          );
          previousRight = tabRect.right;
          expectWholeLabel(tester, section(which), label);
        }
      });
    }

    // At 320dp and 200% "Details" fits its half of the bar, so the case
    // above would pass with a bare Text. A longer label must shrink.
    testWidgets('a label too long for its tab scales down: whole, on one '
        'line, inside its tab', (tester) async {
      await showNarrow(tester, longLabel: true);

      expect(tester.takeException(), isNull);
      const label = 'Everything about this event';
      final text = find.descendant(
        of: tab(EventDetailTab.details),
        matching: find.text(label),
      );
      expect(text, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)),
      );
      // Laid out whole, on one line: as wide as the whole label unwrapped.
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(
        paragraph.size.width,
        closeTo(paragraph.getMaxIntrinsicWidth(double.infinity), 0.5),
      );
      // Drawn smaller than that, inside its tab.
      final tabRect = tester.getRect(tab(EventDetailTab.details));
      final drawn = tester.getRect(text);
      expect(drawn.width, lessThan(tester.getSize(text).width));
      expect(drawn.left, greaterThanOrEqualTo(tabRect.left));
      expect(drawn.right, lessThanOrEqualTo(tabRect.right));
      expect(drawn.top, greaterThanOrEqualTo(tabRect.top));
      expect(drawn.bottom, lessThanOrEqualTo(tabRect.bottom));
    });

    testWidgets('each tab meets the tap-target guideline at 320dp and 200% '
        'text', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await showNarrow(tester);
        for (final which in EventDetailTab.values) {
          final rect = tester.getSemantics(tab(which)).rect;
          expect(
            rect.shortestSide,
            greaterThanOrEqualTo(kMinInteractiveDimension),
            reason: '$which',
          );
        }

        // On Games, with the tab's header and its empty state under the
        // bar.
        await tester.tap(tab(EventDetailTab.games));
        await tester.pumpAndSettle();
        expect(gamesBody(), findsOneWidget);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      } finally {
        handle.dispose();
      }
    });

    testWidgets('focus stays on Games after it is activated with the '
        'keyboard', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await showNarrow(tester);
        final games = Focus.of(tester.element(tab(EventDetailTab.games)));

        await activateByKeyboard(tester, tab(EventDetailTab.games));

        expect(gamesBody(), findsOneWidget);
        expect(find.byKey(EventDetailScreen.datesKey), findsNothing);
        expect(FocusManager.instance.primaryFocus, same(games));
        expect(
          tester.getSemantics(tab(EventDetailTab.games)),
          isSemantics(isSelected: true, isFocused: true),
        );
      } finally {
        handle.dispose();
      }
    });

    testWidgets('Games opens on Lineup', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(app(pool: const [azul]));
        await showing(tester);

        await tester.tap(tab(EventDetailTab.games));
        await tester.pumpAndSettle();

        expect(
          tester.getSemantics(section(EventGamesSection.lineup)),
          isSemantics(isSelected: true),
        );
        for (final other in [
          EventGamesSection.nominations,
          EventGamesSection.pool,
        ]) {
          expect(
            tester.getSemantics(section(other)),
            isSemantics(isSelected: false),
          );
        }
        // The pool's rows are the Pool sub-tab's alone.
        Finder azulRow() => find.byKey(
          EventDetailScreen.poolRowKey(azul.id),
          skipOffstage: false,
        );
        expect(azulRow(), findsNothing);

        await tester.tap(section(EventGamesSection.pool));
        await tester.pumpAndSettle();
        expect(azulRow(), findsOneWidget);
      } finally {
        handle.dispose();
      }
    });

    testWidgets('focus stays on Pool after it is activated with the '
        'keyboard', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await showNarrow(tester);
        await activateByKeyboard(tester, tab(EventDetailTab.games));
        final pool = Focus.of(
          tester.element(section(EventGamesSection.pool)),
        );
        await activateByKeyboard(
          tester,
          section(EventGamesSection.nominations),
        );
        expect(
          find.text("Couldn't load nominations", skipOffstage: false),
          findsOneWidget,
        );

        await activateByKeyboard(tester, section(EventGamesSection.pool));

        // The pool under the bar, its header over its empty state, and the
        // nominations gone from it.
        expect(
          find.byKey(EventDetailScreen.poolSearchKey, skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text("Couldn't load nominations", skipOffstage: false),
          findsNothing,
        );
        expect(FocusManager.instance.primaryFocus, same(pool));
        expect(
          tester.getSemantics(section(EventGamesSection.pool)),
          isSemantics(isSelected: true, isFocused: true),
        );
      } finally {
        handle.dispose();
      }
    });

    // Details with the bar is audited with the rest of the event, in the
    // screen's own suite. This is each of the Games tab's sub-tabs (#945)
    // with nobody's games on it (#516); with a pool it is audited in the
    // tab's own suite.
    for (final which in EventGamesSection.values) {
      auditScreen(
        'ready, on the Games tab, ${which.name}',
        build: harness,
        arrange: (tester) async {
          await showing(tester);
          await tester.tap(tab(EventDetailTab.games));
          await tester.pumpAndSettle();
          await tester.tap(section(which));
          await tester.pumpAndSettle();
          expect(gamesBody(), findsOneWidget);
          expect(
            tester.getSemantics(section(which)),
            isSemantics(isSelected: true),
          );
        },
      );
    }
  });

  group('EventScreenTab (#856)', () {
    // Each value the location can carry, the tab it opens and the value a
    // report of that tab puts back.
    for (final (value, opens, query) in [
      (null, EventScreenTab.details, null),
      ('details', EventScreenTab.details, null),
      ('games', EventScreenTab.lineup, 'lineup'),
      ('lineup', EventScreenTab.lineup, 'lineup'),
      ('nominations', EventScreenTab.nominations, 'nominations'),
      ('pool', EventScreenTab.pool, 'pool'),
      ('nonsense', EventScreenTab.details, null),
      // Case matters.
      ('POOL', EventScreenTab.details, null),
    ]) {
      test('$value opens ${opens.name}, whose query is $query', () {
        final tab = EventScreenTab.parse(value);

        expect(tab, opens);
        expect(tab.query, query);
        expect(EventScreenTab.parse(tab.query), tab);
      });
    }

    // Each tab's place in the screen's bar and the Games tab's, and back.
    for (final (screenTab, tab, section)
        in <
          (
            EventScreenTab,
            EventDetailTab,
            EventGamesSection?,
          )
        >[
          (EventScreenTab.details, EventDetailTab.details, null),
          (
            EventScreenTab.lineup,
            EventDetailTab.games,
            EventGamesSection.lineup,
          ),
          (
            EventScreenTab.nominations,
            EventDetailTab.games,
            EventGamesSection.nominations,
          ),
          (EventScreenTab.pool, EventDetailTab.games, EventGamesSection.pool),
        ]) {
      test('${screenTab.name} is ${tab.name}, on ${section?.name}', () {
        expect(screenTab.tab, tab);
        expect(screenTab.section, section);
        if (section != null) {
          expect(EventScreenTab.of(tab, section), screenTab);
        }
      });
    }

    test('the bar on Details is Details, whatever the sub-tabs stand on', () {
      for (final section in EventGamesSection.values) {
        expect(
          EventScreenTab.of(EventDetailTab.details, section),
          EventScreenTab.details,
          reason: section.name,
        );
      }
    });
  });

  group('the location (#856)', () {
    late ValueNotifier<String?> location;
    late ValueNotifier<String?> dateLocation;
    late List<EventScreenTab> reports;

    /// The date told beside each of [reports], in the same order (#1042).
    late List<String?> reportedDates;

    /// Opens the screen on the location's [tab] and [date], and keeps each
    /// tab change it reports in [reports], with the date told beside it in
    /// [reportedDates].
    Future<void> open(
      WidgetTester tester,
      String? tab, {
      String? date,
      FakeEventRemote? remote,
      List<OfferedGame> pool = const [],
    }) async {
      location = ValueNotifier(tab);
      addTearDown(location.dispose);
      dateLocation = ValueNotifier(date);
      addTearDown(dateLocation.dispose);
      reports = [];
      reportedDates = [];
      await tester.pumpWidget(
        app(
          location: location,
          date: dateLocation,
          remote: remote,
          pool: pool,
          onLocationChanged: (_, tab, date) {
            reports.add(tab);
            reportedDates.add(date);
          },
        ),
      );
    }

    /// The screen's own tab bar's controller, and the Games tab's sub-tabs'.
    TabController tabs(WidgetTester tester) => tester
        .widget<TabBar>(
          find.descendant(
            of: find.byKey(EventDetailScreen.tabBarKey),
            matching: find.byType(TabBar),
          ),
        )
        .controller!;
    TabController sections(WidgetTester tester) => tester
        .widget<TabBar>(
          find.descendant(
            of: find.byKey(EventDetailScreen.sectionBarKey),
            matching: find.byType(TabBar),
          ),
        )
        .controller!;

    /// The tab the bars stand on, and under Games the sub-tab.
    EventScreenTab shown(WidgetTester tester) {
      final tab = EventDetailTab.values[tabs(tester).index];
      return EventScreenTab.of(
        tab,
        // The sub-tabs' bar is built on Games alone.
        tab == EventDetailTab.games
            ? EventGamesSection.values[sections(tester).index]
            : EventGamesSection.nominations,
      );
    }

    /// Shows the hosted event on whichever tab is chosen, and lets the read
    /// it starts end.
    Future<void> showingOnAnyTab(WidgetTester tester) async {
      cache.add(hosted);
      await tester.pumpAndSettle();
      expect(find.byKey(EventDetailScreen.tabBarKey), findsOneWidget);
    }

    /// Shows [twoDated], with its row of dates (#1042), on whichever tab is
    /// chosen, and lets the read it starts end.
    Future<void> showingDated(WidgetTester tester) async {
      cache.add(twoDated);
      await tester.pumpAndSettle();
      expect(find.byKey(EventDetailScreen.tabBarKey), findsOneWidget);
    }

    /// The Games tab's controller, which holds the date view (#1042).
    EventGamesTabController games(WidgetTester tester) => EventGamesTabScope.of(
      tester.element(find.byKey(EventDetailScreen.tabBarKey)),
    );

    /// Taps [control], then lets one frame and a third of the indicator's
    /// move run: mid-change.
    Future<void> tapAndHold(WidgetTester tester, Finder control) async {
      await tester.tap(control);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('tab: pool opens Games on Pool', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await open(tester, 'pool', pool: const [azul]);
        await showingOnAnyTab(tester);

        expect(
          tester.getSemantics(tab(EventDetailTab.games)),
          isSemantics(isSelected: true),
        );
        expect(
          tester.getSemantics(tab(EventDetailTab.details)),
          isSemantics(isSelected: false),
        );
        expect(
          tester.getSemantics(section(EventGamesSection.pool)),
          isSemantics(isSelected: true),
        );
        expect(
          tester.getSemantics(section(EventGamesSection.nominations)),
          isSemantics(isSelected: false),
        );
        expect(
          find.byKey(
            EventDetailScreen.poolRowKey(azul.id),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(reports, isEmpty);
      } finally {
        handle.dispose();
      }
    });

    testWidgets('tab: pool reads the pool and the nominations once the '
        'detail is ready', (tester) async {
      final remote = FakeEventRemote.detail(
        (_) => hosted.snapshot,
        pool: (_) => const [azul],
      );
      await open(tester, 'pool', remote: remote);
      // Past the first frame. The loading spinner never settles.
      await tester.pump();
      await tester.pump();

      // Nothing to read them for while the detail loads.
      expect(remote.poolRequests, isEmpty);
      expect(remote.nominationReads, isEmpty);

      await showingOnAnyTab(tester);

      // No tab was pressed.
      expect(remote.poolRequests, hasLength(1));
      expect(remote.poolRequests.single.eventId, 'e-1');
      expect(remote.nominationReads, ['e-1']);
    });

    testWidgets('an unknown tab opens Details', (tester) async {
      await open(tester, 'nonsense');
      await showing(tester);

      expect(shown(tester), EventScreenTab.details);
      expect(find.byKey(EventDetailScreen.datesKey), findsOneWidget);
      expect(gamesBody(), findsNothing);
      expect(reports, isEmpty);
    });

    testWidgets('a local-only event with tab: pool shows Details with no '
        'bar, drops the tab at once, and shows Details once it reaches the '
        'server', (tester) async {
      final remote = FakeEventRemote.detail(
        (_) => hosted.snapshot,
        pool: (_) => const [azul],
      );
      final moved = StreamController<EventDetail?>.broadcast();
      addTearDown(moved.close);
      when(
        () => repository.watchEvent('srv-1'),
      ).thenAnswer((_) => moved.stream);
      EventDetail withEvent(Event Function(Event event) change) =>
          hosted.copyWith(
            snapshot: hosted.snapshot.copyWith(
              event: change(hosted.snapshot.event),
            ),
          );

      await open(tester, 'pool', remote: remote);
      cache.add(withEvent((event) => event.copyWith(isLocalOnly: true)));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(EventDetailScreen.tabBarKey), findsNothing);
      expect(find.byType(TabBar), findsNothing);
      expect(find.byKey(EventDetailScreen.datesKey), findsOneWidget);
      expect(gamesBody(), findsNothing);
      // The tab it can't show is dropped, not held for later: the screen
      // stands on Details, with no move to watch, and says so, so the
      // location loses it.
      expect(tester.hasRunningAnimations, isFalse);
      expect(reports, [EventScreenTab.details]);
      location.value = null;
      await tester.pumpAndSettle();
      expect(reports, [EventScreenTab.details]);
      expect(remote.poolRequests, isEmpty);
      expect(remote.nominationReads, isEmpty);

      // The create reaches the server, which knows the event by its own id,
      // and the detail follows it there (#499).
      when(() => repository.reconciledEventId('e-1')).thenReturn('srv-1');
      cache.add(null);
      await tester.pump();
      moved.add(withEvent((event) => event.copyWith(id: 'srv-1')));
      await tester.pumpAndSettle();

      // The bar shows, on Details, and nothing was read for Games.
      expect(tester.takeException(), isNull);
      expect(shown(tester), EventScreenTab.details);
      expect(find.byKey(EventDetailScreen.datesKey), findsOneWidget);
      expect(gamesBody(), findsNothing);
      expect(remote.poolRequests, isEmpty);
      expect(remote.nominationReads, isEmpty);
      expect(reports, [EventScreenTab.details]);

      // Games opens on its first sub-tab, not the one the location named.
      await tester.tap(tab(EventDetailTab.games));
      await tester.pumpAndSettle();
      expect(shown(tester), EventScreenTab.lineup);
      expect(reports, [EventScreenTab.details, EventScreenTab.lineup]);
    });

    testWidgets('choosing a tab reports it once it settles', (tester) async {
      await open(tester, null);
      await showing(tester);

      await tapAndHold(tester, tab(EventDetailTab.games));
      expect(tabs(tester).indexIsChanging, isTrue);
      expect(reports, isEmpty);
      await tester.pumpAndSettle();
      expect(reports, [EventScreenTab.lineup]);

      await tapAndHold(tester, section(EventGamesSection.pool));
      expect(sections(tester).indexIsChanging, isTrue);
      expect(reports, [EventScreenTab.lineup]);
      await tester.pumpAndSettle();
      expect(reports, [EventScreenTab.lineup, EventScreenTab.pool]);

      await tapAndHold(tester, tab(EventDetailTab.details));
      expect(tabs(tester).indexIsChanging, isTrue);
      expect(reports, [EventScreenTab.lineup, EventScreenTab.pool]);
      await tester.pumpAndSettle();
      expect(reports, [
        EventScreenTab.lineup,
        EventScreenTab.pool,
        EventScreenTab.details,
      ]);
    });

    testWidgets('a new tab from the location moves the bars, and reports '
        'nothing', (tester) async {
      final remote = FakeEventRemote.detail(
        (_) => hosted.snapshot,
        pool: (_) => const [azul],
      );
      await open(tester, null, remote: remote);
      await showing(tester);

      location.value = 'pool';
      await tester.pumpAndSettle();

      expect(shown(tester), EventScreenTab.pool);
      expect(
        find.byKey(EventDetailScreen.poolRowKey(azul.id), skipOffstage: false),
        findsOneWidget,
      );
      // Games' first showing, as a press of it would be.
      expect(remote.poolRequests, hasLength(1));
      expect(remote.nominationReads, hasLength(1));

      location.value = null;
      await tester.pumpAndSettle();

      expect(shown(tester), EventScreenTab.details);
      expect(find.byKey(EventDetailScreen.datesKey), findsOneWidget);
      expect(reports, isEmpty);
    });

    testWidgets('the tab the screen reported, given back, changes nothing', (
      tester,
    ) async {
      await open(tester, null);
      await showing(tester);
      await tester.tap(tab(EventDetailTab.games));
      await tester.pumpAndSettle();
      await tester.tap(section(EventGamesSection.pool));
      await tester.pumpAndSettle();
      expect(reports, [EventScreenTab.lineup, EventScreenTab.pool]);

      location.value = 'pool';
      await tester.pump();

      expect(tester.hasRunningAnimations, isFalse);
      expect(tabs(tester).indexIsChanging, isFalse);
      expect(sections(tester).indexIsChanging, isFalse);
      expect(shown(tester), EventScreenTab.pool);
      await tester.pumpAndSettle();
      expect(reports, [EventScreenTab.lineup, EventScreenTab.pool]);
    });

    // Until the location a report asks for comes back, the screen is built
    // with the one it had, as when the motion setting changes meanwhile.
    testWidgets('built again with the location it had, the screen keeps the '
        'tab chosen', (tester) async {
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await open(tester, null);
      await showing(tester);
      await tester.tap(tab(EventDetailTab.games));
      await tester.pumpAndSettle();
      expect(reports, [EventScreenTab.lineup]);

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pumpAndSettle();

      expect(location.value, isNull);
      expect(shown(tester), EventScreenTab.lineup);
      expect(reports, [EventScreenTab.lineup]);
    });

    // The location a report asked for can come back after the user has
    // already chosen again: it is the report's echo, not a new location.
    testWidgets('a report given back mid-change leaves the newer choice', (
      tester,
    ) async {
      await open(tester, null);
      await showing(tester);
      await tester.tap(tab(EventDetailTab.games));
      await tester.pumpAndSettle();
      expect(reports, [EventScreenTab.lineup]);

      await tester.tap(section(EventGamesSection.pool));
      await tester.pump();
      expect(sections(tester).indexIsChanging, isTrue);
      location.value = 'lineup';
      await tester.pumpAndSettle();

      expect(shown(tester), EventScreenTab.pool);
      expect(reports, [EventScreenTab.lineup, EventScreenTab.pool]);
    });

    // The scope replaces the sub-tabs' controller when the motion setting
    // changes, and the screen's tab controller is replaced too; a change
    // either was making ends on the new one, which never says it settled.
    testWidgets('a change the motion setting cuts short is still reported', (
      tester,
    ) async {
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await open(tester, null);
      await showing(tester);

      await tapAndHold(tester, tab(EventDetailTab.games));
      expect(tabs(tester).indexIsChanging, isTrue);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pumpAndSettle();
      expect(reports, [EventScreenTab.lineup]);

      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
      await tester.pumpAndSettle();
      await tapAndHold(tester, section(EventGamesSection.pool));
      expect(sections(tester).indexIsChanging, isTrue);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pumpAndSettle();

      expect(shown(tester), EventScreenTab.pool);
      expect(reports, [EventScreenTab.lineup, EventScreenTab.pool]);
    });

    // A report puts the tab in the location on top, which is another
    // route's while one covers the screen, and while the screen leaves.
    testWidgets('a change that settles under a dialog is reported once the '
        'screen is on top again', (tester) async {
      await open(tester, null);
      await showing(tester);

      await tapAndHold(tester, tab(EventDetailTab.games));
      expect(tabs(tester).indexIsChanging, isTrue);
      unawaited(
        showDialog<void>(
          context: tester.element(tab(EventDetailTab.games)),
          builder: (_) => const AlertDialog(content: Text('Over the event')),
        ),
      );
      await tester.pumpAndSettle();
      expect(tabs(tester).indexIsChanging, isFalse);
      expect(reports, isEmpty);

      Navigator.of(tester.element(find.text('Over the event'))).pop();
      await tester.pumpAndSettle();

      expect(reports, [EventScreenTab.lineup]);
    });

    testWidgets('a change that settles as the screen leaves reports nothing', (
      tester,
    ) async {
      await open(tester, null);
      await showing(tester);

      await tapAndHold(tester, tab(EventDetailTab.games));
      expect(tabs(tester).indexIsChanging, isTrue);
      Navigator.of(tester.element(tab(EventDetailTab.games))).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const Text('Elsewhere')),
      );
      // The screen stays built while it leaves, and its change settles
      // before it goes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(EventDetailScreen), findsOneWidget);
      expect(tabs(tester).indexIsChanging, isFalse);
      await tester.pumpAndSettle();

      expect(find.byType(EventDetailScreen), findsNothing);
      expect(reports, isEmpty);
    });

    // The date beside the tab (#1042): the screen opens on the date the
    // location names, tells the location the date it shows where the two
    // differ, and keeps it as the tab changes.
    testWidgets('choosing a sub-tab keeps the date in the location', (
      tester,
    ) async {
      await open(tester, 'lineup', date: 'o-2');
      await showingDated(tester);
      expect(games(tester).dateView, const OneDateView('o-2'));
      expect(reports, isEmpty);

      await tester.tap(section(EventGamesSection.pool));
      await tester.pumpAndSettle();
      await tester.tap(tab(EventDetailTab.details));
      await tester.pumpAndSettle();

      expect(reports, [EventScreenTab.pool, EventScreenTab.details]);
      expect(reportedDates, ['o-2', 'o-2']);
    });

    testWidgets('a date the event lacks opens the default, and the location '
        'is told it', (tester) async {
      await open(tester, 'pool', date: 'gone');
      await showingDated(tester);

      expect(games(tester).dateView, const OneDateView('o-1'));
      expect(shown(tester), EventScreenTab.pool);
      expect(reports, [EventScreenTab.pool]);
      expect(reportedDates, ['o-1']);
    });

    // None opens the default again, so the location stays as it is.
    testWidgets('a location that names no date opens the default, and is '
        'told nothing', (tester) async {
      await open(tester, null);
      await showingDated(tester);

      expect(games(tester).dateView, const OneDateView('o-1'));
      expect(reports, isEmpty);

      await tester.tap(tab(EventDetailTab.games));
      await tester.pumpAndSettle();
      expect(reports, [EventScreenTab.lineup]);
      expect(reportedDates, [null]);
    });

    testWidgets('a date on an event with one date is dropped from the '
        'location', (tester) async {
      await open(tester, 'lineup', date: 'o-1');
      await showingOnAnyTab(tester);

      expect(games(tester).dateView, isNull);
      expect(reports, [EventScreenTab.lineup]);
      expect(reportedDates, [null]);
    });

    testWidgets('a date chosen is told beside the tab shown', (tester) async {
      await open(tester, 'lineup', date: 'o-2');
      await showingDated(tester);

      games(tester).chooseDate(const EveryDateView());
      await tester.pump();

      expect(reports, [EventScreenTab.lineup]);
      expect(reportedDates, ['all']);
    });

    testWidgets('a date chosen while a sub-tab change runs is told with it, '
        'once it settles', (tester) async {
      await open(tester, 'lineup', date: 'o-2');
      await showingDated(tester);

      await tapAndHold(tester, section(EventGamesSection.pool));
      games(tester).chooseDate(const EveryDateView());
      await tester.pump();
      expect(sections(tester).indexIsChanging, isTrue);
      expect(reports, isEmpty);
      await tester.pumpAndSettle();

      expect(reports, [EventScreenTab.pool]);
      expect(reportedDates, ['all']);
    });

    testWidgets('a new date from the location moves the view, reports '
        'nothing, and goes with the next tab told', (tester) async {
      await open(tester, null, date: 'o-1');
      await showingDated(tester);
      expect(reports, isEmpty);

      dateLocation.value = 'o-2';
      await tester.pumpAndSettle();
      expect(games(tester).dateView, const OneDateView('o-2'));
      expect(reports, isEmpty);

      await tester.tap(tab(EventDetailTab.games));
      await tester.pumpAndSettle();
      expect(reports, [EventScreenTab.lineup]);
      expect(reportedDates, ['o-2']);
    });

    // None opens the default, which the location goes on naming none for.
    testWidgets('a location that moves from a date to none opens the '
        'default, and the next tab told carries none', (tester) async {
      await open(tester, 'lineup', date: 'o-2');
      await showingDated(tester);
      expect(games(tester).dateView, const OneDateView('o-2'));

      dateLocation.value = null;
      await tester.pumpAndSettle();
      expect(games(tester).dateView, const OneDateView('o-1'));
      expect(reports, isEmpty);

      await tester.tap(section(EventGamesSection.pool));
      await tester.pumpAndSettle();
      expect(reports, [EventScreenTab.pool]);
      expect(reportedDates, [null]);
    });

    testWidgets('a new date from the location that the event lacks opens the '
        'default, and the location is told it once', (tester) async {
      await open(tester, 'lineup', date: 'o-2');
      await showingDated(tester);

      dateLocation.value = 'gone';
      await tester.pumpAndSettle();

      expect(games(tester).dateView, const OneDateView('o-1'));
      expect(reports, [EventScreenTab.lineup]);
      expect(reportedDates, ['o-1']);

      // The location the report asked for, given back, changes nothing.
      dateLocation.value = 'o-1';
      await tester.pumpAndSettle();
      expect(games(tester).dateView, const OneDateView('o-1'));
      expect(reports, [EventScreenTab.lineup]);
    });

    testWidgets('a read that changes no date tells nothing', (tester) async {
      // On Details, where the title shows.
      await open(tester, null, date: 'o-2');
      await showingDated(tester);

      cache.add(
        twoDated.copyWith(
          snapshot: twoDated.snapshot.copyWith(
            event: twoDated.snapshot.event.copyWith(title: 'Azul night'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Azul night'), findsOneWidget);

      expect(games(tester).dateView, const OneDateView('o-2'));
      expect(reports, isEmpty);
    });

    // A link to a date added since the event was last read: the cache lacks
    // it, so it isn't judged until the open's read has ended.
    group('a date the cache lacks', () {
      /// The server's answer to the open's read, held until a test gives it.
      late Completer<EventSnapshot> answer;

      /// A few frames, while the read is held: the Pool waits on it with a
      /// spinner, which never settles.
      Future<void> frames(WidgetTester tester) async {
        for (var i = 0; i < 3; i++) {
          await tester.pump();
        }
      }

      /// Opens the screen on Pool and [date], with the cache's dates, older
      /// than the server's, and the open's read held.
      Future<void> openHeld(WidgetTester tester, String date) async {
        answer = Completer<EventSnapshot>();
        await open(
          tester,
          'pool',
          date: date,
          remote: FakeEventRemote.detail(
            (_) => answer.future,
            pool: (_) => const [],
          ),
        );
        cache.add(twoDated);
        await frames(tester);
        expect(games(tester).dateView, const OneDateView('o-1'));
        expect(reports, isEmpty);
      }

      testWidgets('shows once the read brings it, and the location keeps '
          'naming it', (tester) async {
        await openHeld(tester, 'o-3');

        // What the read wrote reaches the cache, and then the read ends.
        cache.add(threeDated);
        await frames(tester);
        expect(games(tester).dateView, const OneDateView('o-3'));
        answer.complete(threeDated.snapshot);
        await tester.pumpAndSettle();

        expect(games(tester).dateView, const OneDateView('o-3'));
        expect(shown(tester), EventScreenTab.pool);
        expect(reports, isEmpty);
      });

      testWidgets("shows once the read's own answer brings it, after the "
          'read has ended', (tester) async {
        await openHeld(tester, 'o-3');

        // The read ends before the cache delivers what it wrote, and the
        // location is told the default meanwhile.
        answer.complete(threeDated.snapshot);
        await tester.pumpAndSettle();
        expect(games(tester).dateView, const OneDateView('o-1'));
        expect(reports, [EventScreenTab.pool]);
        expect(reportedDates, ['o-1']);

        cache.add(threeDated);
        await tester.pumpAndSettle();

        expect(games(tester).dateView, const OneDateView('o-3'));
        expect(shown(tester), EventScreenTab.pool);
        expect(reports, [EventScreenTab.pool, EventScreenTab.pool]);
        expect(reportedDates, ['o-1', 'o-3']);
      });

      testWidgets("opens the default where the read doesn't bring it either, "
          'and the location names that once the read has ended', (
        tester,
      ) async {
        await openHeld(tester, 'gone');

        answer.complete(twoDated.snapshot);
        await tester.pumpAndSettle();

        expect(games(tester).dateView, const OneDateView('o-1'));
        expect(reports, [EventScreenTab.pool]);
        expect(reportedDates, ['o-1']);
      });

      testWidgets('keeps the location as it is where the read fails', (
        tester,
      ) async {
        await openHeld(tester, 'o-3');

        answer.completeError(Exception('offline'));
        await tester.pumpAndSettle();

        expect(games(tester).dateView, const OneDateView('o-1'));
        expect(reports, isEmpty);
      });
    });

    testWidgets('the event losing its second date drops the date from the '
        'location, and keeps the sub-tab', (tester) async {
      await open(tester, 'pool', date: 'o-2');
      await showingDated(tester);

      cache.add(hosted);
      await tester.pumpAndSettle();

      expect(games(tester).dateView, isNull);
      expect(shown(tester), EventScreenTab.pool);
      expect(reports, [EventScreenTab.pool]);
      expect(reportedDates, [null]);
    });
  });
}
