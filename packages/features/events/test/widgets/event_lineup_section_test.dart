import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_filters/game_filters.dart' show GameFiltersLocalizations;
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';
import '../support/fake_event_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

const _offline = EventRemoteTransientException('offline');
const _longTitle =
    'Twilight Imperium: Fourth Edition, Prophecy of Kings and the Codex '
    'Volumes';

/// A row of `e-1`'s roster, answered Going.
EventAttendee _row(String id, {String? name}) => EventAttendee(
  id: id,
  eventId: 'e-1',
  userId: 'user-$id',
  displayName: name,
  role: EventRole.participant,
  status: EventParticipationStatus.attending,
  createdAt: kItemInstant,
  updatedAt: kItemInstant,
);

/// A game on `e-1`'s lineup, Primary and brought by Ada, on the event itself
/// unless [occurrenceId] names a date.
LineupGame _lineupGame(
  String id, {
  String title = 'Catan',
  String? subtitle,
  String? occurrenceId,
  ScheduledGameRole role = ScheduledGameRole.primary,
  int? maxPlayTime,
  String? notes,
  String? nominationId,
  String supplier = 'att-ada',
  String? supplierName = 'Ada Lovelace',
}) => LineupGame(
  id: id,
  occurrenceId: occurrenceId,
  platformGameId: 'pg-$id',
  gameId: 'g-$id',
  title: title,
  subtitle: subtitle,
  platformName: 'Tabletop',
  role: role,
  sortOrder: 0,
  notes: notes,
  maxPlayTime: maxPlayTime,
  nominationId: nominationId,
  suppliedById: 'o-$id',
  supplierAttendeeId: supplier,
  supplierName: supplierName,
);

/// The Lineup sub-tab of an event's Games tab (#519): the games lined up for
/// the event and its dates, grouped by date, what each row says about its
/// game, the states the read can leave it in, and the quick look each row
/// opens.
void main() {
  // Local, as the device's clock reads it.
  final now = DateTime(2026, 10, 23, 18);

  late _MockEventRepository repository;
  late StreamController<EventDetail?> cache;
  late FakeEventRemote remote;

  /// What each lineup read answers.
  late FutureOr<List<LineupGame>> Function(String eventId) lineupAnswer;

  /// Each game page a quick look's View game asked for, by the game's id.
  final openedGames = <String>[];

  // The viewer, Ada, and someone with no name, in the roster's order.
  final me = _row('att-me', name: 'Me');
  final ada = _row('att-ada', name: 'Ada');
  final unnamed = _row('att-nn');

  /// `e-1`'s dates: Friday the 6th at seven, then Saturday the 7th.
  final friday = confirmed(
    'd-1',
    DateTime(2026, 11, 6, 19),
  ).copyWith(eventId: 'e-1');
  final saturday = confirmed(
    'd-2',
    DateTime(2026, 11, 7, 19),
    sortOrder: 1,
  ).copyWith(eventId: 'e-1');
  const fridayName = 'Fri, Nov 6 · 7:00 PM';
  const saturdayName = 'Sat, Nov 7 · 7:00 PM';

  /// Event `e-1` as the viewer sees it, on [dates] (Friday alone by
  /// default), with the viewer, Ada and someone unnamed on its roster.
  EventDetail detailOf({List<EventOccurrence>? dates}) => EventDetail(
    snapshot: EventSnapshot(
      event: item('e-1', title: 'Catan night').event,
      occurrences: dates ?? [friday],
      attendees: [me, ada, unnamed],
    ),
    attendance: me,
  );

  setUpAll(() {
    registerFallbackValue(detailOf().snapshot);
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
    lineupAnswer = (_) => const [];
    openedGames.clear();
  });

  tearDown(() {
    unawaited(cache.close());
  });

  Widget harness(EventDetail detail, {ThemeData? theme}) {
    remote = FakeEventRemote.detail(
      (_) => detail.snapshot,
      pool: (_) => const [],
      nominations: (_) => const [],
      lineup: (eventId) => lineupAnswer(eventId),
    );
    return MaterialApp(
      theme: theme ?? BgeTheme.light(),
      locale: const Locale('en', 'US'),
      localizationsDelegates: const [
        ...EventsLocalizations.localizationsDelegates,
        GameFiltersLocalizations.delegate,
      ],
      supportedLocales: EventsLocalizations.supportedLocales,
      home: EventDetailScreen(
        eventId: 'e-1',
        repository: repository,
        session: FakeSessionLease(),
        remote: remote,
        onBack: (_) {},
        onOpenGame: (context, gameId) => openedGames.add(gameId),
        now: () => now,
      ),
    );
  }

  /// Lets the cache's answer reach the bloc, and its state the screen.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  /// Fixed pumps, not pumpAndSettle: a spinner never settles.
  Future<void> animate(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  /// The cache's answer, [detail], then the Games tab, which opens on its
  /// Lineup sub-tab (#519), with the reads that starts ended.
  Future<void> arrangeGames(WidgetTester tester, EventDetail detail) async {
    cache.add(detail);
    await settle(tester);
    await settle(tester);
    await tester.tap(
      find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
    );
    await animate(tester);
  }

  /// Shows [detail] (on Friday alone, by default) and opens the Games tab
  /// on Lineup.
  Future<void> showLineup(
    WidgetTester tester, {
    EventDetail? detail,
    ThemeData? theme,
  }) async {
    final shown = detail ?? detailOf();
    await tester.pumpWidget(harness(shown, theme: theme));
    await arrangeGames(tester, shown);
  }

  /// The screen's blocs. Their providers are inside the screen, so the
  /// lookup starts from a widget it builds.
  T blocOf<T extends StateStreamableSource<Object?>>(WidgetTester tester) =>
      BlocProvider.of<T>(
        tester.element(
          find
              .descendant(
                of: find.byType(EventDetailScreen),
                matching: find.byType(Scaffold),
              )
              .first,
        ),
      );

  /// Reads the event again, whose end reads the lineup again (#519).
  Future<void> readEvent(WidgetTester tester) async {
    blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
    await settle(tester);
    await animate(tester);
  }

  // Rows below the view are built all the same, a viewport past its edge,
  // and a finder that skips what isn't on screen would pass them over.
  Finder row(String id) =>
      find.byKey(EventDetailScreen.lineupRowKey(id), skipOffstage: false);
  Finder inRow(String id, String text) => find.descendant(
    of: row(id),
    matching: find.text(text, skipOffstage: false),
    skipOffstage: false,
  );
  Finder head(String id) =>
      find.byKey(EventDetailScreen.lineupRowHeadKey(id), skipOffstage: false);
  Finder retry() => find.byKey(EventDetailScreen.lineupRetryKey);
  final gamesBody = find.byKey(EventDetailScreen.gamesBodyKey);
  final quickLook = find.byKey(EventDetailScreen.quickLookKey);
  Finder textIn(String text) =>
      find.descendant(of: quickLook, matching: find.text(text));

  /// The heading [title] on the Games tab: a header to a screen reader.
  Finder heading(String title) => find.ancestor(
    of: find.text(title, skipOffstage: false),
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && (widget.properties.header ?? false),
      description: 'a heading',
      skipOffstage: false,
    ),
  );

  /// Every heading under the Games tab's bars.
  Finder headings() => find.descendant(
    of: gamesBody,
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && (widget.properties.header ?? false),
      description: 'a heading',
      skipOffstage: false,
    ),
    skipOffstage: false,
  );

  /// The top of [finder]'s first match, for comparing where things are.
  double topOf(WidgetTester tester, Finder finder) =>
      tester.getRect(finder.first).top;

  /// The page's one scroll view.
  Finder scrollable() => find
      .descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      )
      .first;

  /// The focus of [id]'s row head.
  FocusNode headFocus(WidgetTester tester, String id) => tester
      .widget<InkWell>(
        find.descendant(
          of: head(id),
          matching: find.byType(InkWell, skipOffstage: false),
          skipOffstage: false,
        ),
      )
      .focusNode!;

  /// Opens [id]'s quick look with a tap on its row's cover, scrolled to and
  /// brought on screen first.
  Future<void> openQuickLook(WidgetTester tester, String id) async {
    await tester.scrollUntilVisible(head(id), 100, scrollable: scrollable());
    final cover = find.descendant(
      of: head(id),
      matching: find.byType(BgeThumbnail, skipOffstage: false),
      skipOffstage: false,
    );
    await tester.ensureVisible(cover);
    await tester.pump();
    await tester.tap(cover);
    await animate(tester);
    expect(quickLook, findsOneWidget);
  }

  /// Closes the quick look with Escape.
  Future<void> closeQuickLook(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await animate(tester);
    expect(quickLook, findsNothing);
  }

  group('grouping by date', () {
    testWidgets("a one-date event draws no header and marks the event's own "
        'games', (tester) async {
      lineupAnswer = (_) => [
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-1'),
        _lineupGame('l-1'),
      ];

      await showLineup(tester);

      expect(row('l-1'), findsOneWidget);
      expect(row('l-2'), findsOneWidget);
      // One list, the event's own games first, with no headers.
      expect(headings(), findsNothing);
      expect(topOf(tester, row('l-1')), lessThan(topOf(tester, row('l-2'))));
      // The event's own game is marked, last on its status line; the
      // date's isn't.
      expect(
        inRow('l-1', 'Primary · Ada is bringing this · Every date'),
        findsOneWidget,
      );
      expect(inRow('l-2', 'Primary · Ada is bringing this'), findsOneWidget);
    });

    testWidgets('an event with no dates draws no header and marks its own '
        'games', (tester) async {
      lineupAnswer = (_) => [_lineupGame('l-1')];

      await showLineup(tester, detail: detailOf(dates: const []));

      expect(headings(), findsNothing);
      expect(
        inRow('l-1', 'Primary · Ada is bringing this · Every date'),
        findsOneWidget,
      );
    });

    testWidgets('two dates draw a header each', (tester) async {
      lineupAnswer = (_) => [
        _lineupGame('l-3', title: 'Root', occurrenceId: 'd-2'),
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-1'),
        _lineupGame('l-1'),
      ];

      await showLineup(tester, detail: detailOf(dates: [saturday, friday]));

      // Every date, then each date in order, each over its own games.
      final order = [
        heading('Every date'),
        row('l-1'),
        heading(fridayName),
        row('l-2'),
        heading(saturdayName),
        row('l-3'),
      ];
      for (final finder in order) {
        expect(finder, findsOneWidget);
      }
      for (var i = 1; i < order.length; i++) {
        expect(
          topOf(tester, order[i]),
          greaterThan(topOf(tester, order[i - 1])),
          reason: 'item $i follows item ${i - 1}',
        );
      }
      expect(headings(), findsNWidgets(3));
      // The header says it: the rows carry no mark.
      expect(inRow('l-1', 'Primary · Ada is bringing this'), findsOneWidget);
    });

    testWidgets('a date with no games has no header', (tester) async {
      lineupAnswer = (_) => [
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-2'),
      ];

      await showLineup(tester, detail: detailOf(dates: [friday, saturday]));

      expect(heading(saturdayName), findsOneWidget);
      expect(heading(fridayName), findsNothing);
      expect(heading('Every date'), findsNothing);
    });

    testWidgets('a game for a date the event no longer lists shows under a '
        'header of its own, last, and its quick look says so', (tester) async {
      lineupAnswer = (_) => [
        _lineupGame('l-9', title: 'Root', occurrenceId: 'd-gone'),
        _lineupGame('l-1'),
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-1'),
      ];

      await showLineup(tester);

      expect(tester.takeException(), isNull);
      // On a one-date event the gone date's group brings headers.
      final order = [
        heading('Every date'),
        row('l-1'),
        heading(fridayName),
        row('l-2'),
        heading('A date no longer on the event'),
        row('l-9'),
      ];
      for (final finder in order) {
        expect(finder, findsOneWidget);
      }
      for (var i = 1; i < order.length; i++) {
        expect(
          topOf(tester, order[i]),
          greaterThan(topOf(tester, order[i - 1])),
          reason: 'item $i follows item ${i - 1}',
        );
      }

      await openQuickLook(tester, 'l-9');

      expect(tester.takeException(), isNull);
      expect(textIn('A date no longer on the event'), findsOneWidget);
    });

    testWidgets("the page counts every group's rows, each numbered among "
        'them all', (tester) async {
      final handle = tester.ensureSemantics();
      lineupAnswer = (_) => [
        _lineupGame('l-1'),
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-1'),
        _lineupGame('l-3', title: 'Root', occurrenceId: 'd-2'),
      ];

      await showLineup(tester, detail: detailOf(dates: [friday, saturday]));

      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .semanticChildCount,
        3,
      );
      // Numbered on from the groups before, not from each group's start.
      for (final (index, id) in [(0, 'l-1'), (1, 'l-2'), (2, 'l-3')]) {
        expect(
          tester
              .widget<IndexedSemantics>(
                find
                    .ancestor(
                      of: row(id),
                      matching: find.byType(
                        IndexedSemantics,
                        skipOffstage: false,
                      ),
                    )
                    .first,
              )
              .index,
          index,
          reason: id,
        );
      }
      handle.dispose();
    });
  });

  group('rows', () {
    testWidgets('a row is its cover, its name and one status line, what it '
        'is played as and who brings it, as one button, with no action of '
        'its own', (tester) async {
      final handle = tester.ensureSemantics();
      lineupAnswer = (_) => [_lineupGame('l-1', subtitle: 'Seafarers')];

      await showLineup(tester);

      expect(inRow('l-1', 'Catan: Seafarers'), findsOneWidget);
      // One status line under the name (#946).
      expect(
        find.descendant(
          of: head('l-1'),
          matching: find.byType(Text, skipOffstage: false),
          skipOffstage: false,
        ),
        findsNWidgets(2),
      );
      expect(
        inRow('l-1', 'Primary · Ada is bringing this · Every date'),
        findsOneWidget,
      );
      // Read without the symbols between its parts.
      expect(
        tester.getSemantics(inRow('l-1', 'Catan: Seafarers')),
        matchesSemantics(
          label:
              'Catan: Seafarers\n'
              'Primary, Ada is bringing this, Every date',
          isButton: true,
          isFocusable: true,
          hasFocusAction: true,
          hasTapAction: true,
        ),
      );
      // No main action: nothing on the lineup can be changed here.
      expect(
        find.descendant(
          of: row('l-1'),
          matching: find.byWidgetPredicate(
            (widget) => widget is ButtonStyleButton,
            skipOffstage: false,
          ),
          skipOffstage: false,
        ),
        findsNothing,
      );
      handle.dispose();
    });

    testWidgets('a filler says so, with its longest play where it has one; '
        "a role this client can't read says none", (tester) async {
      // On the one date, so no line is marked every date.
      lineupAnswer = (_) => [
        _lineupGame(
          'l-1',
          occurrenceId: 'd-1',
          role: ScheduledGameRole.filler,
          maxPlayTime: 20,
        ),
        _lineupGame(
          'l-4',
          title: 'Uno',
          occurrenceId: 'd-1',
          role: ScheduledGameRole.filler,
          maxPlayTime: 1,
        ),
        _lineupGame(
          'l-2',
          title: 'Azul',
          occurrenceId: 'd-1',
          role: ScheduledGameRole.filler,
        ),
        _lineupGame(
          'l-3',
          title: 'Root',
          occurrenceId: 'd-1',
          role: ScheduledGameRole.unknown,
        ),
      ];

      await showLineup(tester);

      expect(
        inRow('l-1', 'Filler, up to 20 minutes · Ada is bringing this'),
        findsOneWidget,
      );
      expect(
        inRow('l-4', 'Filler, up to 1 minute · Ada is bringing this'),
        findsOneWidget,
      );
      expect(inRow('l-2', 'Filler · Ada is bringing this'), findsOneWidget);
      // No role: who brings it alone.
      expect(inRow('l-3', 'Ada is bringing this'), findsOneWidget);
    });

    testWidgets("the viewer's own copy says you bring it", (tester) async {
      lineupAnswer = (_) => [
        _lineupGame('l-1', occurrenceId: 'd-1', supplier: 'att-me'),
      ];

      await showLineup(tester);

      expect(inRow('l-1', "Primary · You're bringing this"), findsOneWidget);
    });

    testWidgets("a supplier the viewer can't read is someone", (tester) async {
      lineupAnswer = (_) => [
        // Not on the roster, and served with no name.
        _lineupGame('l-1', supplier: 'att-zz', supplierName: null),
        // Not on the roster, and named by the server.
        _lineupGame(
          'l-2',
          title: 'Azul',
          supplier: 'att-yy',
          supplierName: 'Yo',
        ),
        // On the roster with no name, and served with none.
        _lineupGame(
          'l-3',
          title: 'Root',
          supplier: 'att-nn',
          supplierName: null,
        ),
        // On the roster: its name wins over the server's.
        _lineupGame('l-4', title: 'Uno'),
      ];

      await showLineup(tester);

      for (final (id, who) in [
        ('l-1', 'This person'),
        ('l-2', 'Yo'),
        ('l-3', 'This person'),
        ('l-4', 'Ada'),
      ]) {
        expect(
          inRow(id, 'Primary · $who is bringing this · Every date'),
          findsOneWidget,
          reason: id,
        );
      }
    });

    testWidgets('a row that leaves while it holds focus hands it to the next '
        "row's head, across a date's header", (tester) async {
      lineupAnswer = (_) => [
        _lineupGame('l-1'),
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-2'),
      ];
      await showLineup(tester, detail: detailOf(dates: [friday, saturday]));
      headFocus(tester, 'l-1').requestFocus();
      await tester.pump();

      // Someone else took it out: a read finds it gone.
      lineupAnswer = (_) => [
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-2'),
      ];
      await readEvent(tester);

      expect(row('l-1'), findsNothing);
      expect(headFocus(tester, 'l-2').hasPrimaryFocus, isTrue);
    });
  });

  group('states', () {
    testWidgets('hidden, failed with retry, empty, loading', (tester) async {
      // Loading: the first read held.
      final first = Completer<List<LineupGame>>();
      lineupAnswer = (_) => first.future;

      await showLineup(tester);

      expect(find.bySemanticsLabel('Loading the lineup'), findsOneWidget);
      expect(remote.lineupRequests, ['e-1']);

      // Hidden: the server won't show it.
      first.completeError(const EventRemoteForbiddenException('no'));
      await animate(tester);

      expect(find.bySemanticsLabel('Loading the lineup'), findsNothing);
      expect(find.text("The lineup isn't shown to you"), findsOneWidget);
      expect(retry(), findsNothing);

      // Failed: a later read, the detail read's, fails with nothing read.
      lineupAnswer = (_) => throw _offline;
      await readEvent(tester);

      expect(find.text("Couldn't load the lineup"), findsOneWidget);
      expect(retry(), findsOneWidget);

      // Try again reads it, and an empty lineup says so.
      lineupAnswer = (_) => const [];
      await tester.tap(retry());
      await animate(tester);

      expect(remote.lineupRequests, hasLength(3));
      expect(find.text("Couldn't load the lineup"), findsNothing);
      expect(find.text('Nothing in the lineup yet'), findsOneWidget);
      expect(
        find.text(
          'Games join the lineup when a nomination passes, or when a host '
          'adds one.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .semanticChildCount,
        0,
      );
    });

    testWidgets("a read again keeps what's shown, with no spinner over it", (
      tester,
    ) async {
      lineupAnswer = (_) => [_lineupGame('l-1')];
      await showLineup(tester);
      expect(row('l-1'), findsOneWidget);

      final held = Completer<List<LineupGame>>();
      lineupAnswer = (_) => held.future;
      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await settle(tester);

      expect(row('l-1'), findsOneWidget);
      expect(find.bySemanticsLabel('Loading the lineup'), findsNothing);

      held.complete([_lineupGame('l-1')]);
      await animate(tester);
    });
  });

  group('the quick look', () {
    testWidgets('a row opens the lineup quick look, and focus returns to the '
        'row after', (tester) async {
      lineupAnswer = (_) => [
        _lineupGame(
          'l-1',
          subtitle: 'Seafarers',
          occurrenceId: 'd-1',
          role: ScheduledGameRole.filler,
          maxPlayTime: 30,
          notes: 'Bring the expansion',
          nominationId: 'n-1',
        ),
        _lineupGame('l-2', title: 'Azul'),
      ];

      await showLineup(tester);
      await openQuickLook(tester, 'l-1');

      // Its name as the row gives it, as the pop-up's heading.
      expect(
        find.descendant(
          of: quickLook,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && (widget.properties.header ?? false),
          ),
        ),
        findsOneWidget,
      );
      expect(textIn('Catan: Seafarers'), findsOneWidget);
      for (final line in [
        'Tabletop',
        'Filler, up to 30 minutes',
        'Ada is bringing this',
        fridayName,
        'Note: Bring the expansion',
        'Added from a nomination',
      ]) {
        expect(textIn(line), findsOneWidget, reason: line);
      }
      // No write is offered on the lineup.
      expect(find.byKey(EventDetailScreen.quickLookNominateKey), findsNothing);

      // View game opens the game's page.
      final openGame = find.byKey(EventDetailScreen.quickLookOpenGameKey);
      await tester.ensureVisible(openGame);
      await tester.pump();
      expect(openGame, findsOneWidget);

      await closeQuickLook(tester);

      // Back on the row it was opened from.
      expect(headFocus(tester, 'l-1').hasPrimaryFocus, isTrue);
    });

    testWidgets("the event's own game says every date, and one added "
        'directly says nothing of a nomination', (tester) async {
      lineupAnswer = (_) => [_lineupGame('l-1')];

      await showLineup(tester);
      await openQuickLook(tester, 'l-1');

      expect(textIn('Every date'), findsOneWidget);
      expect(textIn('Primary'), findsOneWidget);
      expect(textIn('Added from a nomination'), findsNothing);
      expect(find.textContaining('Note:'), findsNothing);
    });

    testWidgets("View game opens the game's page", (tester) async {
      lineupAnswer = (_) => [_lineupGame('l-1')];

      await showLineup(tester);
      await openQuickLook(tester, 'l-1');
      final openGame = find.byKey(EventDetailScreen.quickLookOpenGameKey);
      await tester.ensureVisible(openGame);
      await tester.pump();
      await tester.tap(openGame);
      await animate(tester);

      expect(openedGames, ['g-l-1']);
    });

    testWidgets('a game that leaves the lineup while its quick look is open '
        'says so, and the close hands focus to the row in its place', (
      tester,
    ) async {
      lineupAnswer = (_) => [
        _lineupGame('l-1'),
        _lineupGame('l-2', title: 'Azul'),
      ];

      await showLineup(tester);
      await openQuickLook(tester, 'l-1');

      // Someone else took it out: a read finds it gone.
      lineupAnswer = (_) => [_lineupGame('l-2', title: 'Azul')];
      await readEvent(tester);

      expect(
        find.byKey(EventDetailScreen.quickLookGoneKey),
        findsOneWidget,
      );
      expect(textIn('This game is no longer in the lineup.'), findsOneWidget);
      // Still named as it was.
      expect(textIn('Catan'), findsOneWidget);
      expect(find.byKey(EventDetailScreen.quickLookOpenGameKey), findsNothing);

      await closeQuickLook(tester);

      expect(row('l-1'), findsNothing);
      expect(headFocus(tester, 'l-2').hasPrimaryFocus, isTrue);
    });
  });

  group('accessibility audit', () {
    /// Two dates and one no longer listed, each with a game: every header
    /// drawn.
    List<LineupGame> grouped() => [
      _lineupGame('l-1', subtitle: 'Seafarers'),
      _lineupGame(
        'l-2',
        title: 'Azul',
        occurrenceId: 'd-1',
        role: ScheduledGameRole.filler,
        maxPlayTime: 20,
      ),
      _lineupGame(
        'l-3',
        title: 'Root',
        occurrenceId: 'd-2',
        supplier: 'att-me',
      ),
      _lineupGame('l-4', title: 'Uno', occurrenceId: 'd-gone'),
    ];

    auditScreen(
      'EventDetailScreen, on the Lineup sub-tab grouped by date',
      pump: (tester, theme) async {
        lineupAnswer = (_) => grouped();
        final detail = detailOf(dates: [friday, saturday]);
        await tester.pumpWidget(harness(detail, theme: theme));
        await arrangeGames(tester, detail);
      },
      arrange: (tester) async {
        // Under the tab bars, and audited there.
        await tester.scrollUntilVisible(
          row('l-2'),
          100,
          scrollable: scrollable(),
        );
        await tester.pumpAndSettle();
        expect(row('l-2'), findsOneWidget);
      },
    );

    auditScreen(
      "EventDetailScreen, the Lineup sub-tab's quick look",
      pump: (tester, theme) async {
        lineupAnswer = (_) => [
          _lineupGame(
            'l-1',
            occurrenceId: 'd-1',
            role: ScheduledGameRole.filler,
            maxPlayTime: 20,
            notes: 'Bring the expansion',
            nominationId: 'n-1',
          ),
        ];
        await tester.pumpWidget(harness(detailOf(), theme: theme));
        await arrangeGames(tester, detailOf());
      },
      arrange: (tester) async {
        await openQuickLook(tester, 'l-1');
      },
    );

    auditScreen(
      "EventDetailScreen, the Lineup sub-tab's failed state",
      pump: (tester, theme) async {
        lineupAnswer = (_) => throw _offline;
        await tester.pumpWidget(harness(detailOf(), theme: theme));
        await arrangeGames(tester, detailOf());
      },
      arrange: (tester) async {
        expect(retry(), findsOneWidget);
      },
    );

    for (final MapEntry(key: themeName, value: theme) in kAuditThemes.entries) {
      testWidgets('at 320×640 and 200% text, the headers and rows lay out '
          'with no overflow, each row at least 48dp tall — $themeName', (
        tester,
      ) async {
        useViewSize(tester, const Size(320, 640));
        tester.platformDispatcher.textScaleFactorTestValue =
            BgeTextScale.maxScaleFactor;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        lineupAnswer = (_) => [
          for (final game in grouped())
            game.copyWith(title: _longTitle, supplierName: _longTitle),
        ];

        await showLineup(
          tester,
          detail: detailOf(
            dates: [
              friday.copyWith(label: 'The long first evening of the weekend'),
              saturday,
            ],
          ),
          theme: theme(),
        );

        expect(tester.takeException(), isNull);
        for (final id in ['l-1', 'l-2', 'l-3', 'l-4']) {
          await tester.scrollUntilVisible(
            row(id),
            100,
            scrollable: scrollable(),
          );
          await tester.ensureVisible(row(id));
          await tester.pump();
          expect(tester.takeException(), isNull, reason: id);
          final title = tester.renderObject<RenderParagraph>(
            find
                .descendant(
                  of: head(id),
                  matching: find.byType(RichText, skipOffstage: false),
                  skipOffstage: false,
                )
                .first,
          );
          expect(title.didExceedMaxLines, isFalse, reason: id);
          expect(tester.getRect(row(id)).right, lessThanOrEqualTo(320));
          expect(
            tester.getSize(head(id)).height,
            greaterThanOrEqualTo(kMinInteractiveDimension),
            reason: id,
          );
        }
        for (final title in [
          'Every date',
          'The long first evening of the weekend',
          saturdayName,
          'A date no longer on the event',
        ]) {
          await tester.scrollUntilVisible(
            heading(title),
            100,
            scrollable: scrollable(),
          );
          await tester.pump();
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: heading(title),
              matching: find.byType(RichText, skipOffstage: false),
              skipOffstage: false,
            ),
          );
          expect(paragraph.didExceedMaxLines, isFalse, reason: title);
          expect(
            tester.getRect(heading(title)).right,
            lessThanOrEqualTo(320),
            reason: title,
          );
        }
      });
    }

    testWidgets('group headers are headers to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      lineupAnswer = (_) => grouped();

      await showLineup(tester, detail: detailOf(dates: [friday, saturday]));

      for (final title in [
        'Every date',
        fridayName,
        saturdayName,
        'A date no longer on the event',
      ]) {
        await tester.scrollUntilVisible(
          heading(title),
          100,
          scrollable: scrollable(),
        );
        await tester.pump();
        expect(
          tester.getSemantics(find.text(title)),
          matchesSemantics(label: title, isHeader: true),
          reason: title,
        );
      }
      handle.dispose();
    });

    testWidgets('by keyboard, a row opens its quick look, and Escape hands '
        'focus back to the row', (tester) async {
      lineupAnswer = (_) => [
        _lineupGame('l-1'),
        _lineupGame('l-2', title: 'Azul'),
      ];

      await showLineup(tester);
      final focus = headFocus(tester, 'l-2')..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(quickLook, findsOneWidget);
      expect(textIn('Azul'), findsOneWidget);

      await closeQuickLook(tester);

      expect(focus.hasPrimaryFocus, isTrue);
    });

    testWidgets('at 320×640 and 200% text, the quick look lays out with no '
        'overflow', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      lineupAnswer = (_) => [
        _lineupGame(
          'l-1',
          title: _longTitle,
          subtitle: 'Seafarers',
          occurrenceId: 'd-gone',
          role: ScheduledGameRole.filler,
          maxPlayTime: 120,
          notes: _longTitle,
          nominationId: 'n-1',
          supplierName: _longTitle,
          supplier: 'att-zz',
        ),
      ];

      await showLineup(tester);
      await openQuickLook(tester, 'l-1');

      expect(tester.takeException(), isNull);
      final openGame = find.byKey(EventDetailScreen.quickLookOpenGameKey);
      await tester.ensureVisible(openGame);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(openGame).right, lessThanOrEqualTo(320));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: textIn('$_longTitle: Seafarers'),
          matching: find.byType(RichText),
        ),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
    });
  });
}
