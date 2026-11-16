import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/l10n/events_localizations_en.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
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
/// labels are largest: at 320dp and 200% text.
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
  /// The pool is [pool], none unless a test says otherwise.
  Widget app({
    ThemeData? theme,
    bool longLabel = false,
    List<OfferedGame> pool = const [],
  }) => MaterialApp(
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
    home: EventDetailScreen(
      eventId: 'e-1',
      repository: repository,
      session: FakeSessionLease(),
      // Nobody has offered a game, unless a test says otherwise: the pool is
      // the empty state, under its header. Its rows are audited with the
      // tab's own suite.
      remote: FakeEventRemote.detail(
        (_) => hosted.snapshot,
        pool: (_) => pool,
      ),
      onBack: (_) {},
      now: () => now,
    ),
  );

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
    }) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(app(longLabel: longLabel));
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

    testWidgets('the sub-tab bar lays out with no overflow and whole labels '
        'at 320dp and 200% text', (tester) async {
      await showNarrow(tester);
      await tester.tap(tab(EventDetailTab.games));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final bar = tester.getRect(find.byKey(EventDetailScreen.sectionBarKey));
      expect(bar.left, greaterThanOrEqualTo(0));
      expect(bar.right, lessThanOrEqualTo(320));
      for (final which in EventGamesSection.values) {
        final label = sectionLabels[which]!;
        final tabRect = tester.getRect(section(which));
        expect(tabRect.left, greaterThanOrEqualTo(bar.left), reason: label);
        expect(tabRect.right, lessThanOrEqualTo(bar.right), reason: label);
        expectWholeLabel(tester, section(which), label);
      }
    });

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

    testWidgets('Games opens on Nominations', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(app(pool: const [azul]));
        await showing(tester);

        await tester.tap(tab(EventDetailTab.games));
        await tester.pumpAndSettle();

        expect(
          tester.getSemantics(section(EventGamesSection.nominations)),
          isSemantics(isSelected: true),
        );
        expect(
          tester.getSemantics(section(EventGamesSection.pool)),
          isSemantics(isSelected: false),
        );
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
        expect(
          find.text("Couldn't load nominations", skipOffstage: false),
          findsOneWidget,
        );

        await activateByKeyboard(tester, section(EventGamesSection.pool));

        // The pool under the bar, and the nominations gone from it.
        expect(find.text('Games pool', skipOffstage: false), findsOneWidget);
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
}
