import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/held_spinner.dart';
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

/// A row of `e-1`'s roster, a participant answered Going unless a test says
/// otherwise.
EventAttendee _row(
  String id, {
  String? name,
  EventRole role = EventRole.participant,
  EventParticipationStatus status = EventParticipationStatus.attending,
}) => EventAttendee(
  id: id,
  eventId: 'e-1',
  userId: 'user-$id',
  displayName: name,
  role: role,
  status: status,
  createdAt: kItemInstant,
  updatedAt: kItemInstant,
);

/// A game [attendeeId] offers to `e-1`'s pool, from their collection.
OfferedGame _offered(String id, String attendeeId, String title) => OfferedGame(
  id: id,
  attendeeId: attendeeId,
  collectionId: 'col-$id',
  platformGameId: 'pg-$id',
  gameId: 'g-$id',
  title: title,
  platformName: 'Tabletop',
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

  /// What each read of the games pool answers: none, unless a test says
  /// otherwise.
  late List<OfferedGame> pool;

  /// How each read of the games pool answers: with [pool], unless a test
  /// holds it or has it fail.
  late FutureOr<List<OfferedGame>> Function() poolAnswer;

  /// What each read of the event throws, while set: none, unless a test has
  /// the server stop showing it.
  Object? detailFailure;

  /// Holds each lineup removal's answer while set (#520).
  Completer<void>? removeHold;

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

  /// Event `e-1` as the viewer sees it, on [dates] (Friday alone by
  /// default), with the viewer, Ada and someone unnamed on its roster, or
  /// [roster]. The viewer is [viewer], a participant by default.
  EventDetail detailOf({
    List<EventOccurrence>? dates,
    EventAttendee? viewer,
    List<EventAttendee>? roster,
  }) {
    final self = viewer ?? me;
    return EventDetail(
      snapshot: EventSnapshot(
        event: item('e-1', title: 'Catan night').event,
        occurrences: dates ?? [friday],
        attendees: roster ?? [self, ada, unnamed],
      ),
      attendance: self,
    );
  }

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
    when(
      () => repository.forgetEvent(any(), lastWrite: any(named: 'lastWrite')),
    ).thenAnswer((_) async => true);
    detailFailure = null;
    removeHold = null;
    lineupAnswer = (_) => const [];
    pool = const [];
    poolAnswer = () => pool;
    openedGames.clear();
  });

  tearDown(() {
    unawaited(cache.close());
  });

  /// The date the screen's location names (#1042), which a test moves as
  /// Back or Forward would.
  late ValueNotifier<String?> location;

  Widget harness(EventDetail detail, {ThemeData? theme}) {
    location = ValueNotifier(null);
    addTearDown(location.dispose);
    remote = FakeEventRemote.detail(
      (_) {
        // The fake throws what a test hands it.
        // ignore: only_throw_errors
        if (detailFailure case final failure?) throw failure;
        return detail.snapshot;
      },
      pool: (_) => poolAnswer(),
      nominations: (_) => const [],
      lineup: (eventId) => lineupAnswer(eventId),
      directAdded: (request) => _lineupGame(
        'l-${request.suppliedById}',
        occurrenceId: request.occurrenceId,
        role: request.role,
      ),
      lineupRemoved: (request) async {
        await removeHold?.future;
        return _lineupGame(request.lineupGameId);
      },
    );
    return MaterialApp(
      theme: theme ?? BgeTheme.light(),
      locale: const Locale('en', 'US'),
      localizationsDelegates: const [
        ...EventsLocalizations.localizationsDelegates,
        GameFiltersLocalizations.delegate,
      ],
      supportedLocales: EventsLocalizations.supportedLocales,
      home: ValueListenableBuilder(
        valueListenable: location,
        builder: (context, date, _) => EventDetailScreen(
          eventId: 'e-1',
          repository: repository,
          session: FakeSessionLease(),
          remote: remote,
          date: date,
          onBack: (_) {},
          onOpenGame: (context, gameId) => openedGames.add(gameId),
          now: () => now,
        ),
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

  /// Chooses the date [id] from the row of dates (#1042), Every date where
  /// it is null.
  Future<void> chooseDate(WidgetTester tester, String? id) async {
    final chip = find.byKey(
      EventDetailScreen.dateChipKey(id),
      skipOffstage: false,
    );
    await tester.ensureVisible(chip);
    await tester.pump();
    await tester.tap(chip);
    await animate(tester);
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

    // An event of two or more dates has a row of them (#1042), and the
    // lineup follows its choice: a date's games, then the event's own,
    // marked; or the event's own alone under Every date.
    testWidgets("a date lists its games, then the event's own marked every "
        'date', (tester) async {
      lineupAnswer = (_) => [
        _lineupGame('l-3', title: 'Root', occurrenceId: 'd-2'),
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-1'),
        _lineupGame('l-1'),
      ];

      await showLineup(tester, detail: detailOf(dates: [saturday, friday]));

      // Friday, the next date still to come: its own game, then the
      // event's, with no headings.
      expect(row('l-2'), findsOneWidget);
      expect(row('l-1'), findsOneWidget);
      expect(row('l-3'), findsNothing);
      expect(headings(), findsNothing);
      expect(topOf(tester, row('l-2')), lessThan(topOf(tester, row('l-1'))));
      expect(inRow('l-2', 'Primary · Ada is bringing this'), findsOneWidget);
      expect(
        inRow('l-1', 'Primary · Ada is bringing this · Every date'),
        findsOneWidget,
      );

      await chooseDate(tester, 'd-2');

      expect(row('l-3'), findsOneWidget);
      expect(row('l-2'), findsNothing);
      expect(topOf(tester, row('l-3')), lessThan(topOf(tester, row('l-1'))));
      expect(headings(), findsNothing);
    });

    testWidgets("Every date lists only the event's own lineup", (
      tester,
    ) async {
      lineupAnswer = (_) => [
        _lineupGame('l-3', title: 'Root', occurrenceId: 'd-2'),
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-1'),
        _lineupGame('l-1'),
      ];
      await showLineup(tester, detail: detailOf(dates: [friday, saturday]));

      await chooseDate(tester, null);

      expect(row('l-1'), findsOneWidget);
      expect(row('l-2'), findsNothing);
      expect(row('l-3'), findsNothing);
      // The view says it: no heading, and no mark on the row.
      expect(headings(), findsNothing);
      expect(inRow('l-1', 'Primary · Ada is bringing this'), findsOneWidget);
    });

    testWidgets('Every date keeps a game for a date the event no longer '
        'lists, under its heading', (tester) async {
      lineupAnswer = (_) => [
        _lineupGame('l-9', title: 'Root', occurrenceId: 'd-gone'),
        _lineupGame('l-1'),
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-1'),
      ];
      await showLineup(tester, detail: detailOf(dates: [friday, saturday]));
      // No date's view holds it.
      expect(row('l-9'), findsNothing);

      await chooseDate(tester, null);

      expect(tester.takeException(), isNull);
      final order = [
        heading('Every date'),
        row('l-1'),
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
      expect(headings(), findsNWidgets(2));
      expect(row('l-2'), findsNothing);
    });

    testWidgets('a date with nothing in view says the lineup is empty', (
      tester,
    ) async {
      lineupAnswer = (_) => [
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-2'),
      ];

      await showLineup(tester, detail: detailOf(dates: [friday, saturday]));

      expect(row('l-2'), findsNothing);
      expect(find.text('Nothing in the lineup yet'), findsOneWidget);

      await chooseDate(tester, 'd-2');
      expect(row('l-2'), findsOneWidget);
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
        _lineupGame('l-3', title: 'Root', occurrenceId: 'd-gone'),
      ];

      await showLineup(tester);

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
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-gone'),
      ];
      await showLineup(tester);
      headFocus(tester, 'l-1').requestFocus();
      await tester.pump();

      // Someone else took it out: a read finds it gone.
      lineupAnswer = (_) => [
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-gone'),
      ];
      await readEvent(tester);

      expect(row('l-1'), findsNothing);
      expect(headFocus(tester, 'l-2').hasPrimaryFocus, isTrue);
    });

    // A view that leaves the focused row out hands focus on as a read
    // that takes the row away does (#1042).
    testWidgets("a row the location's date leaves out, as Back or Forward "
        "names another, hands focus to the next row's head", (tester) async {
      lineupAnswer = (_) => [
        _lineupGame('l-3', title: 'Root', occurrenceId: 'd-2'),
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-1'),
        _lineupGame('l-1'),
      ];
      await showLineup(tester, detail: detailOf(dates: [friday, saturday]));
      headFocus(tester, 'l-2').requestFocus();
      await tester.pump();

      location.value = 'd-2';
      await animate(tester);

      // Saturday's own game takes the place of Friday's.
      expect(row('l-2'), findsNothing);
      expect(headFocus(tester, 'l-3').hasPrimaryFocus, isTrue);
    });

    testWidgets('a row whose date a read takes away hands focus to the next '
        "row's head", (tester) async {
      lineupAnswer = (_) => [
        _lineupGame('l-3', title: 'Root', occurrenceId: 'd-2'),
        _lineupGame('l-2', title: 'Azul', occurrenceId: 'd-1'),
        _lineupGame('l-1'),
      ];
      await showLineup(tester, detail: detailOf(dates: [friday, saturday]));
      headFocus(tester, 'l-2').requestFocus();
      await tester.pump();

      // Friday is gone, so the view falls back to Saturday.
      final sunday = confirmed(
        'd-3',
        DateTime(2026, 11, 8, 19),
        sortOrder: 2,
      ).copyWith(eventId: 'e-1');
      cache.add(detailOf(dates: [saturday, sunday]));
      await settle(tester);
      await animate(tester);

      expect(row('l-2'), findsNothing);
      expect(headFocus(tester, 'l-3').hasPrimaryFocus, isTrue);
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

  group('Add a game (#519)', () {
    final host = _row('att-me', name: 'Me', role: EventRole.host);
    final azul = _offered('o-2', 'att-ada', 'Azul');
    final catan = _offered('o-1', 'att-me', 'Catan');
    final root = _offered('o-3', 'att-nn', 'Root');
    final addGame = find.byKey(EventDetailScreen.lineupAddKey);
    final picker = find.byKey(EventDetailScreen.lineupPickerKey);
    Finder pick(String id) => find.byKey(EventDetailScreen.lineupPickKey(id));
    Finder inPick(String id, String text) =>
        find.descendant(of: pick(id), matching: find.text(text));
    final confirm = find.byKey(EventDetailScreen.addToLineupConfirmKey);
    Finder scopeChoice(String? occurrenceId) =>
        find.byKey(EventDetailScreen.addToLineupScopeKey(occurrenceId));

    /// Add a game's focus.
    FocusNode addFocus(WidgetTester tester) =>
        tester.widget<ButtonStyleButton>(addGame).focusNode!;

    /// Presses Add a game and picks [id] from the pool.
    Future<void> pickGame(WidgetTester tester, String id) async {
      await tester.tap(addGame);
      await animate(tester);
      expect(picker, findsOneWidget);
      await tester.ensureVisible(pick(id));
      await tester.pump();
      await tester.tap(pick(id));
      await animate(tester);
      expect(picker, findsNothing);
    }

    testWidgets('a participant has no Add a game', (tester) async {
      pool = [azul];
      await showLineup(tester);

      expect(find.text('Nothing in the lineup yet'), findsOneWidget);
      expect(addGame, findsNothing);
    });

    testWidgets('Add a game picks from the pool and adds for the chosen date', (
      tester,
    ) async {
      pool = [catan, azul, root];
      await showLineup(tester, detail: detailOf(viewer: host));

      expect(addGame, findsOneWidget);
      // Above the lineup, empty as it is.
      expect(find.text('Nothing in the lineup yet'), findsOneWidget);
      await tester.tap(addGame);
      await animate(tester);

      // Every copy in the pool, named with who brings it.
      expect(picker, findsOneWidget);
      expect(inPick('o-1', 'Catan'), findsOneWidget);
      expect(inPick('o-1', "You're bringing this"), findsOneWidget);
      expect(inPick('o-2', 'Azul'), findsOneWidget);
      expect(inPick('o-2', 'Ada is bringing this'), findsOneWidget);
      expect(inPick('o-3', 'This person is bringing this'), findsOneWidget);

      await tester.tap(pick('o-2'));
      await animate(tester);
      expect(picker, findsNothing);

      // One date and no row of dates: the whole event, or Friday.
      expect(scopeChoice(null), findsOneWidget);
      await tester.tap(scopeChoice('d-1'));
      await animate(tester);
      await tester.ensureVisible(confirm);
      await tester.pump();
      await tester.tap(confirm);
      await animate(tester);

      expect(remote.directAdds, [
        (
          eventId: 'e-1',
          platformGameId: 'pg-o-2',
          suppliedById: 'o-2',
          occurrenceId: 'd-1',
          role: ScheduledGameRole.primary,
          notes: null,
          maxPlayTime: null,
        ),
      ]);
      // The lineup is read again, and shows it.
      expect(remote.lineupRequests, hasLength(2));
      expect(
        find.byKey(EventDetailScreen.lineupOutcomeKey),
        findsOneWidget,
      );
    });

    testWidgets("a copy whose supplier isn't going can't be picked, and says "
        'why', (tester) async {
      final handle = tester.ensureSemantics();
      pool = [catan, azul];
      await showLineup(
        tester,
        detail: detailOf(
          viewer: host,
          roster: [
            host,
            _row(
              'att-ada',
              name: 'Ada',
              status: EventParticipationStatus.notAttending,
            ),
          ],
        ),
      );
      await tester.tap(addGame);
      await animate(tester);

      expect(tester.widget<ListTile>(pick('o-2')).enabled, isFalse);
      expect(inPick('o-2', "Whoever brings it isn't going"), findsOneWidget);
      // Its name to a screen reader says why, as the row draws it.
      final spoken = tester.getSemantics(pick('o-2'));
      expect(spoken, isSemantics(isEnabled: false));
      expect(spoken.label, contains('Azul'));
      expect(spoken.label, contains('Ada is bringing this'));
      expect(spoken.label, contains("Whoever brings it isn't going"));
      expect(tester.widget<ListTile>(pick('o-1')).enabled, isTrue);

      // A press on it picks nothing.
      await tester.tap(pick('o-2'), warnIfMissed: false);
      await animate(tester);
      expect(picker, findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      handle.dispose();
    });

    testWidgets('adding under a date view adds to that date without asking', (
      tester,
    ) async {
      pool = [catan, azul];
      await showLineup(
        tester,
        detail: detailOf(viewer: host, dates: [friday, saturday]),
      );

      // Friday, the next date still to come, opens.
      await pickGame(tester, 'o-2');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(scopeChoice(null), findsNothing);
      expect(scopeChoice('d-1'), findsNothing);
      await tester.tap(confirm);
      await animate(tester);

      expect(remote.directAdds.single.occurrenceId, 'd-1');

      // Under Every date, the event's own lineup.
      await chooseDate(tester, null);
      await pickGame(tester, 'o-1');
      expect(scopeChoice(null), findsNothing);
      await tester.tap(confirm);
      await animate(tester);

      expect(remote.directAdds, hasLength(2));
      expect(remote.directAdds.last.occurrenceId, isNull);
      expect(remote.directAdds.last.suppliedById, 'o-1');
    });

    testWidgets('under a date called off, Add a game is disabled and says '
        'why', (tester) async {
      final handle = tester.ensureSemantics();
      pool = [azul];
      await showLineup(
        tester,
        detail: detailOf(
          viewer: host,
          dates: [
            friday,
            saturday.copyWith(status: OccurrenceStatus.cancelled),
          ],
        ),
      );
      await chooseDate(tester, 'd-2');

      const reason = "This date isn't happening, so games can't be added to it";
      const unread = "Games can't be added to this date";
      expect(tester.widget<ButtonStyleButton>(addGame).onPressed, isNull);
      expect(
        tester.getSemantics(addGame),
        isSemantics(label: 'Add a game', hint: reason, isEnabled: false),
      );
      expect(find.text(reason), findsOneWidget);
      // A date called off says so: not only that nothing can be added.
      expect(find.text(unread), findsNothing);

      await chooseDate(tester, 'd-1');
      expect(tester.widget<ButtonStyleButton>(addGame).onPressed, isNotNull);
      expect(find.text(reason), findsNothing);
      handle.dispose();
    });

    testWidgets('a date that has started still takes an add, from its own '
        'view', (tester) async {
      pool = [azul];
      // Earlier this month: the night itself, or the morning after.
      final started = confirmed(
        'd-0',
        DateTime(2026, 10, 2, 19),
      ).copyWith(eventId: 'e-1');
      await showLineup(
        tester,
        detail: detailOf(viewer: host, dates: [started, friday]),
      );
      await chooseDate(tester, 'd-0');

      expect(tester.widget<ButtonStyleButton>(addGame).onPressed, isNotNull);
      expect(
        find.text("This date isn't happening, so games can't be added to it"),
        findsNothing,
      );
      await pickGame(tester, 'o-2');
      expect(scopeChoice('d-0'), findsNothing);
      await tester.tap(confirm);
      await animate(tester);

      expect(remote.directAdds.single.occurrenceId, 'd-0');
    });

    testWidgets("Add a game's list shows the pool's read as it goes: a "
        'spinner, then the games', (tester) async {
      final held = Completer<List<OfferedGame>>();
      poolAnswer = () => held.future;
      await showLineup(tester, detail: detailOf(viewer: host));
      await tester.tap(addGame);
      await animate(tester);

      expect(
        find.descendant(
          of: picker,
          matching: find.bySemanticsLabel('Loading the games'),
        ),
        findsOneWidget,
      );
      expect(find.text('No games offered yet'), findsNothing);

      held.complete([azul]);
      await animate(tester);

      expect(pick('o-2'), findsOneWidget);
      expect(find.bySemanticsLabel('Loading the games'), findsNothing);
    });

    testWidgets("Add a game's list says when the pool couldn't be read, and "
        'Try again reads it', (tester) async {
      poolAnswer = () => throw _offline;
      await showLineup(tester, detail: detailOf(viewer: host));
      await tester.tap(addGame);
      await animate(tester);

      expect(
        find.descendant(
          of: picker,
          matching: find.text("Couldn't load the games"),
        ),
        findsOneWidget,
      );
      expect(find.text('No games offered yet'), findsNothing);

      poolAnswer = () => [azul];
      final reads = remote.poolRequests.length;
      await tester.tap(find.byKey(EventDetailScreen.lineupPickerRetryKey));
      await animate(tester);

      expect(remote.poolRequests, hasLength(reads + 1));
      expect(pick('o-2'), findsOneWidget);
    });

    testWidgets("Add a game's list says when the games aren't shown, and when "
        'none are offered', (tester) async {
      poolAnswer = () => throw const EventRemoteForbiddenException('no');
      await showLineup(tester, detail: detailOf(viewer: host));
      await tester.tap(addGame);
      await animate(tester);

      expect(
        find.descendant(
          of: picker,
          matching: find.text("The games aren't shown to you"),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);

      // None offered, as the pool's read answers.
      await tester.pumpWidget(const SizedBox());
      poolAnswer = () => const [];
      await showLineup(tester, detail: detailOf(viewer: host));
      await tester.tap(addGame);
      await animate(tester);

      expect(
        find.descendant(
          of: picker,
          matching: find.text('No games offered yet'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Once someone offers to bring a game, it can be added to the lineup '
          'from here.',
        ),
        findsOneWidget,
      );
    });

    testWidgets("under a date whose status this client can't read, Add a "
        'game is disabled, saying only that no game can be added', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      pool = [azul];
      await showLineup(
        tester,
        detail: detailOf(
          viewer: host,
          dates: [
            friday,
            saturday.copyWith(status: OccurrenceStatus.unknown),
          ],
        ),
      );
      await chooseDate(tester, 'd-2');

      const neutral = "Games can't be added to this date";
      expect(tester.widget<ButtonStyleButton>(addGame).onPressed, isNull);
      expect(
        tester.getSemantics(addGame),
        isSemantics(label: 'Add a game', hint: neutral, isEnabled: false),
      );
      expect(find.text(neutral), findsOneWidget);
      expect(
        find.text("This date isn't happening, so games can't be added to it"),
        findsNothing,
      );
      handle.dispose();
    });

    testWidgets("Add a game's list says the event can't be found, where it "
        'goes while the list is open', (tester) async {
      pool = [azul];
      await showLineup(tester, detail: detailOf(viewer: host));
      await tester.tap(addGame);
      await animate(tester);
      expect(pick('o-2'), findsOneWidget);

      // The server no longer shows the event: its forget empties the cache.
      detailFailure = const EventRemoteNotFoundException(
        'gone',
        statusCode: 404,
      );
      await readEvent(tester);
      cache.add(null);
      await settle(tester);
      await animate(tester);

      expect(
        blocOf<EventDetailBloc>(tester).state,
        isA<EventDetailNotFound>(),
      );
      expect(
        find.descendant(
          of: picker,
          matching: find.text("We couldn't find this event"),
        ),
        findsOneWidget,
      );
      expect(pick('o-2'), findsNothing);
      expect(
        find.descendant(
          of: picker,
          matching: find.bySemanticsLabel('Loading the games'),
        ),
        findsNothing,
      );
    });

    testWidgets("focus is back on Add a game after the dialog's Cancel, and "
        'after an add is sent', (tester) async {
      pool = [azul];
      await showLineup(tester, detail: detailOf(viewer: host));
      addFocus(tester).requestFocus();
      await tester.pump();

      // Cancel: nothing sent.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      await tester.tap(pick('o-2'));
      await animate(tester);
      await tester.tap(find.text('Cancel'));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.directAdds, isEmpty);
      expect(addFocus(tester).hasPrimaryFocus, isTrue);

      // Sent: held through the add, focus kept.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      await tester.tap(pick('o-2'));
      await animate(tester);
      await tester.tap(confirm);
      await animate(tester);

      expect(remote.directAdds, hasLength(1));
      expect(addFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('closed with nothing picked, focus is back on Add a game, and '
        'nothing is sent', (tester) async {
      pool = [azul];
      await showLineup(tester, detail: detailOf(viewer: host));
      addFocus(tester).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(picker, findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);

      expect(picker, findsNothing);
      expect(remote.directAdds, isEmpty);
      expect(addFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('the last row to leave while it holds focus hands it to Add a '
        'game', (tester) async {
      pool = [azul];
      lineupAnswer = (_) => [_lineupGame('l-1')];
      await showLineup(tester, detail: detailOf(viewer: host));
      headFocus(tester, 'l-1').requestFocus();
      await tester.pump();

      // Someone else took it out: a read finds it gone.
      lineupAnswer = (_) => const [];
      await readEvent(tester);

      expect(row('l-1'), findsNothing);
      expect(addFocus(tester).hasPrimaryFocus, isTrue);
    });
  });

  group('Remove from lineup (#520)', () {
    final host = _row('att-me', name: 'Me', role: EventRole.host);
    Finder remove(String id) => find.byKey(
      EventDetailScreen.lineupRemoveKey(id),
      skipOffstage: false,
    );
    final removeInQuickLook = find.byKey(
      EventDetailScreen.quickLookLineupRemoveKey,
    );
    final confirm = find.byKey(EventDetailScreen.lineupRemoveConfirmKey);
    final keep = find.byKey(EventDetailScreen.lineupRemoveKeepKey);
    final outcome = find.byKey(EventDetailScreen.lineupOutcomeKey);
    const startedHint =
        "This lineup has started or was called off, so it can't be changed.";

    bool enabled(WidgetTester tester, Finder button) =>
        tester.widget<ButtonStyleButton>(button).onPressed != null;

    testWidgets('a host sees Remove on each lineup row', (tester) async {
      lineupAnswer = (_) => [_lineupGame('l-1'), _lineupGame('l-2')];
      await showLineup(tester, detail: detailOf(viewer: host));

      for (final id in ['l-1', 'l-2']) {
        expect(remove(id), findsOneWidget, reason: id);
        expect(
          find.descendant(
            of: remove(id),
            matching: find.text('Remove from lineup', skipOffstage: false),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(enabled(tester, remove(id)), isTrue);
      }
    });

    testWidgets("a started date's game shows Remove disabled with its reason", (
      tester,
    ) async {
      final begun = confirmed(
        'd-0',
        DateTime(2026, 10, 22, 19),
      ).copyWith(eventId: 'e-1');
      // Under the date that has begun, with the event's own game, which has
      // Friday still ahead.
      lineupAnswer = (_) => [
        _lineupGame('l-1', occurrenceId: 'd-0'),
        _lineupGame('l-2'),
      ];
      await showLineup(
        tester,
        detail: detailOf(viewer: host, dates: [begun, friday]),
      );
      await chooseDate(tester, 'd-0');

      expect(remove('l-1'), findsOneWidget);
      expect(enabled(tester, remove('l-1')), isFalse);
      expect(inRow('l-1', startedHint), findsOneWidget);
      // The date still to come is open.
      expect(enabled(tester, remove('l-2')), isTrue);
      expect(inRow('l-2', startedHint), findsNothing);
    });

    FocusNode removeFocus(WidgetTester tester, String id) =>
        tester.widget<ButtonStyleButton>(remove(id)).focusNode!;

    testWidgets('Remove asks first, naming the subtitle', (tester) async {
      lineupAnswer = (_) => [_lineupGame('l-1', subtitle: 'Seafarers')];
      await showLineup(tester, detail: detailOf(viewer: host));
      removeFocus(tester, 'l-1').requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(
        find.text('Take Catan: Seafarers out of the lineup?'),
        findsOneWidget,
      );

      // Keep it sends nothing, and focus is back on Remove.
      await tester.tap(keep);
      await animate(tester);
      expect(remote.lineupRemovals, isEmpty);
      expect(row('l-1'), findsOneWidget);
      expect(removeFocus(tester, 'l-1').hasPrimaryFocus, isTrue);

      lineupAnswer = (_) => const [];
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      await tester.tap(confirm);
      await animate(tester);

      expect(remote.lineupRemovals, [(eventId: 'e-1', lineupGameId: 'l-1')]);
      expect(row('l-1'), findsNothing);
      expect(
        find.descendant(
          of: outcome,
          matching: find.text('Catan: Seafarers is out of the lineup.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets("a row removed hands focus to the next row's Remove", (
      tester,
    ) async {
      lineupAnswer = (_) => [_lineupGame('l-1'), _lineupGame('l-2')];
      await showLineup(tester, detail: detailOf(viewer: host));
      removeFocus(tester, 'l-1').requestFocus();
      await tester.pump();

      lineupAnswer = (_) => [_lineupGame('l-2')];
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      await tester.tap(confirm);
      await animate(tester);

      expect(row('l-1'), findsNothing);
      expect(removeFocus(tester, 'l-2').hasPrimaryFocus, isTrue);
    });

    testWidgets("a screen reader's Remove hands focus to the next row", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      lineupAnswer = (_) => [_lineupGame('l-1'), _lineupGame('l-2')];
      await showLineup(tester, detail: detailOf(viewer: host));
      await tester.ensureVisible(remove('l-1'));
      await tester.pump();
      // Activated as a screen reader does: no input focus moves.
      expect(removeFocus(tester, 'l-1').hasFocus, isFalse);

      lineupAnswer = (_) => [_lineupGame('l-2')];
      tester.semantics.tap(
        find.semantics.byLabel('Remove Catan from the lineup').first,
      );
      await animate(tester);
      await tester.tap(confirm);
      await animate(tester);

      expect(row('l-1'), findsNothing);
      expect(removeFocus(tester, 'l-2').hasPrimaryFocus, isTrue);
      handle.dispose();
    });

    testWidgets('Remove keeps focus, inert, while its removal is out', (
      tester,
    ) async {
      final hold = removeHold = Completer<void>();
      lineupAnswer = (_) => [_lineupGame('l-1')];
      await showLineup(tester, detail: detailOf(viewer: host));
      removeFocus(tester, 'l-1').requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      await tester.tap(confirm);
      await animate(tester);

      expect(remote.lineupRemovals, hasLength(1));
      expect(removeFocus(tester, 'l-1').hasPrimaryFocus, isTrue);
      expect(enabled(tester, remove('l-1')), isTrue);
      expect(
        find.descendant(of: remove('l-1'), matching: find.byType(HeldSpinner)),
        findsOneWidget,
      );
      // A press meanwhile sends nothing more.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.lineupRemovals, hasLength(1));

      lineupAnswer = (_) => const [];
      hold.complete();
      await animate(tester);
      expect(row('l-1'), findsNothing);
    });

    testWidgets('a participant sees no Remove', (tester) async {
      lineupAnswer = (_) => [_lineupGame('l-1')];
      await showLineup(tester);

      expect(row('l-1'), findsOneWidget);
      expect(remove('l-1'), findsNothing);
    });

    testWidgets('the quick look carries Remove, and a removal sent from it '
        'is said there', (tester) async {
      lineupAnswer = (_) => [_lineupGame('l-1'), _lineupGame('l-2')];
      await showLineup(tester, detail: detailOf(viewer: host));
      await openQuickLook(tester, 'l-1');
      expect(removeInQuickLook, findsOneWidget);

      lineupAnswer = (_) => [_lineupGame('l-2')];
      await tester.tap(removeInQuickLook);
      await animate(tester);
      await tester.tap(confirm);
      await animate(tester);

      expect(remote.lineupRemovals, [(eventId: 'e-1', lineupGameId: 'l-1')]);
      // Gone from the quick look, which says so and holds the outcome.
      expect(find.byKey(EventDetailScreen.quickLookGoneKey), findsOneWidget);
      expect(textIn('Catan is out of the lineup.'), findsOneWidget);
    });

    testWidgets('a started game in the quick look is disabled with its '
        'reason', (tester) async {
      final begun = confirmed(
        'd-0',
        DateTime(2026, 10, 22, 19),
      ).copyWith(eventId: 'e-1');
      lineupAnswer = (_) => [_lineupGame('l-1', occurrenceId: 'd-0')];
      await showLineup(
        tester,
        detail: detailOf(viewer: host, dates: [begun, friday]),
      );
      await chooseDate(tester, 'd-0');
      await openQuickLook(tester, 'l-1');

      expect(removeInQuickLook, findsOneWidget);
      expect(enabled(tester, removeInQuickLook), isFalse);
      expect(textIn(startedHint), findsOneWidget);
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
    /// The event's own, its one date's, and two for dates no longer listed:
    /// every kind of header drawn.
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
        final detail = detailOf();
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
      "EventDetailScreen, a host's Lineup sub-tab with Add a game (#519)",
      pump: (tester, theme) async {
        lineupAnswer = (_) => [_lineupGame('l-1')];
        final detail = detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.host),
        );
        await tester.pumpWidget(harness(detail, theme: theme));
        await arrangeGames(tester, detail);
      },
      arrange: (tester) async {
        await tester.ensureVisible(find.byKey(EventDetailScreen.lineupAddKey));
        await tester.pumpAndSettle();
      },
    );

    auditScreen(
      "EventDetailScreen, a host's Lineup sub-tab with Remove from lineup, "
      'one game started (#520)',
      pump: (tester, theme) async {
        final begun = confirmed(
          'd-0',
          DateTime(2026, 10, 22, 19),
        ).copyWith(eventId: 'e-1');
        lineupAnswer = (_) => [
          _lineupGame('l-1', title: _longTitle),
          _lineupGame('l-2', occurrenceId: 'd-0'),
        ];
        final detail = detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.host),
          dates: [begun, friday],
        );
        await tester.pumpWidget(harness(detail, theme: theme));
        await arrangeGames(tester, detail);
      },
      arrange: (tester) async {
        await tester.ensureVisible(
          find.byKey(EventDetailScreen.lineupRemoveKey('l-1')),
        );
        await tester.pumpAndSettle();
      },
    );

    auditScreen(
      "EventDetailScreen, a lineup game's quick look with Remove from "
      'lineup (#520)',
      pump: (tester, theme) async {
        lineupAnswer = (_) => [_lineupGame('l-1', title: _longTitle)];
        final detail = detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.host),
        );
        await tester.pumpWidget(harness(detail, theme: theme));
        await arrangeGames(tester, detail);
      },
      arrange: (tester) async {
        await openQuickLook(tester, 'l-1');
        expect(
          find.byKey(EventDetailScreen.quickLookLineupRemoveKey),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'EventDetailScreen, the games Add a game picks from, one whose '
      "supplier isn't going (#519)",
      pump: (tester, theme) async {
        pool = [
          _offered('o-1', 'att-me', 'Catan'),
          _offered('o-2', 'att-ada', _longTitle),
        ];
        final host = _row('att-me', name: 'Me', role: EventRole.host);
        final detail = detailOf(
          viewer: host,
          roster: [
            host,
            _row(
              'att-ada',
              name: 'Ada',
              status: EventParticipationStatus.notAttending,
            ),
          ],
        );
        await tester.pumpWidget(harness(detail, theme: theme));
        await arrangeGames(tester, detail);
      },
      arrange: (tester) async {
        final add = find.byKey(EventDetailScreen.lineupAddKey);
        await tester.ensureVisible(add);
        await tester.pumpAndSettle();
        await tester.tap(add);
        await tester.pumpAndSettle();
        expect(find.byKey(EventDetailScreen.lineupPickerKey), findsOneWidget);
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

    for (final MapEntry(key: themeName, value: theme) in kAuditThemes.entries) {
      testWidgets("at 320×640 and 200% text, a date's rows and the event's "
          'own, marked, lay out with no overflow — $themeName', (tester) async {
        useViewSize(tester, const Size(320, 640));
        tester.platformDispatcher.textScaleFactorTestValue =
            BgeTextScale.maxScaleFactor;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        // The longest status line: a Filler's minutes, a long name, and the
        // every-date mark.
        lineupAnswer = (_) => [
          _lineupGame(
            'l-1',
            title: _longTitle,
            role: ScheduledGameRole.filler,
            maxPlayTime: 120,
            supplierName: _longTitle,
          ),
          _lineupGame('l-2', title: _longTitle, occurrenceId: 'd-1'),
        ];

        await showLineup(
          tester,
          detail: detailOf(dates: [friday, saturday]),
          theme: theme(),
        );

        expect(tester.takeException(), isNull);
        for (final id in ['l-2', 'l-1']) {
          await tester.scrollUntilVisible(
            row(id),
            100,
            scrollable: scrollable(),
          );
          await tester.ensureVisible(row(id));
          await tester.pump();
          expect(tester.takeException(), isNull, reason: id);
          for (final paragraph in tester.renderObjectList<RenderParagraph>(
            find.descendant(
              of: head(id),
              matching: find.byType(RichText, skipOffstage: false),
              skipOffstage: false,
            ),
          )) {
            expect(paragraph.didExceedMaxLines, isFalse, reason: id);
          }
          expect(tester.getRect(row(id)).right, lessThanOrEqualTo(320));
        }
        expect(
          find.descendant(
            of: row('l-1'),
            matching: find.textContaining(
              'Every date',
              skipOffstage: false,
            ),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
      });
    }

    testWidgets('group headers are headers to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      lineupAnswer = (_) => grouped();

      await showLineup(tester);

      for (final title in [
        'Every date',
        fridayName,
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
