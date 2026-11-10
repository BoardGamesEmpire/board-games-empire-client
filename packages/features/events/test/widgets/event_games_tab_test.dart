import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';
import '../support/fake_event_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

const _onlineOnlyCopy = "Available when you're online";
const _offline = EventRemoteTransientException('offline');
const _stillSuppliesCopy =
    'Catan is nominated, or in the lineup for a date still to come, so it '
    "can't come off your games yet.";
const _notGoingCopy =
    "You've said you're not going, so a game you offer couldn't be picked. "
    'Change your answer to offer games.';
const _longTitle =
    'Twilight Imperium: Fourth Edition, Prophecy of Kings and the Codex '
    'Volumes';

/// A row of `e-1`'s roster, answered Going unless a test says otherwise.
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

/// A game [attendeeId] offers, from their collection entry `col-[id]`.
OfferedGame _game(
  String id,
  String attendeeId,
  String title, {
  String platform = 'Tabletop',
  GameMedium? medium = GameMedium.physical,
}) => OfferedGame(
  id: id,
  attendeeId: attendeeId,
  collectionId: 'col-$id',
  platformGameId: 'pg-$id',
  gameId: 'g-$id',
  title: title,
  platformName: platform,
  medium: medium,
);

/// The Games tab of an event's screen (#516): when the pool is read, what
/// it shows in each state, its rows, the filter and the people sheet, Take
/// back and its outcomes in the page's footer, and the Offer games button.
void main() {
  // Local, as the device's clock reads it.
  final now = DateTime(2026, 10, 23, 18);

  late _MockEventRepository repository;
  late StreamController<EventDetail?> cache;

  /// What each pool read answers, unless a test sets [poolAnswer].
  late List<OfferedGame> served;
  late FutureOr<List<OfferedGame>> Function(GamesPoolRequest request)
  poolAnswer;
  late FutureOr<void> Function(TakeBackGameRequest request) takeBackAnswer;

  /// A detail read held until a test completes it, while set.
  Completer<EventSnapshot>? heldRead;
  late FakeEventRemote remote;

  // The viewer, Ada and Bo, in the roster's order.
  final me = _row('att-me', name: 'Me');
  final ada = _row('att-ada', name: 'Ada');
  final bo = _row('att-bo', name: 'Bo');

  final catanMine = _game('o-1', 'att-me', 'Catan');
  final azul = _game('o-2', 'att-ada', 'Azul');
  final catanAdas = _game(
    'o-3',
    'att-ada',
    'Catan',
    platform: 'Board Game Arena',
    medium: GameMedium.digital,
  );
  final root = _game('o-4', 'att-bo', 'Root', medium: null);
  final wingspanMine = _game('o-5', 'att-me', 'Wingspan');

  /// Event `e-1`, Scheduled with a date ahead, as the viewer [viewer] sees
  /// it, with [roster] on it.
  EventDetail detailOf({
    EventAttendee? viewer,
    List<EventAttendee>? roster,
    bool rosterGiven = true,
    EventStatus status = EventStatus.scheduled,
  }) {
    final self = viewer ?? me;
    return EventDetail(
      snapshot: EventSnapshot(
        event: item(
          'e-1',
          title: 'Catan night',
        ).event.copyWith(status: status),
        occurrences: [
          confirmed('o-1', DateTime(2026, 11, 6, 19)).copyWith(eventId: 'e-1'),
        ],
        attendees: rosterGiven ? (roster ?? [self, ada, bo]) : null,
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
    served = [catanMine, azul, catanAdas, root];
    poolAnswer = (_) => served;
    takeBackAnswer = (_) {};
    heldRead = null;
  });

  tearDown(() {
    unawaited(cache.close());
  });

  /// Offer games' press, which records what it was given and answers with
  /// no picks.
  final offerArgs = <OfferGamesArgs>[];
  Future<List<OfferPick>?> recordOffer(
    BuildContext context,
    OfferGamesArgs args,
  ) async {
    offerArgs.add(args);
    return null;
  }

  Widget harness({
    required EventDetail detail,
    ValueListenable<bool>? offline,
    bool offers = true,
    ThemeData? theme,
  }) {
    remote = FakeEventRemote.detail(
      (_) => heldRead?.future ?? detail.snapshot,
      pool: (request) => poolAnswer(request),
      takenBack: (request) => takeBackAnswer(request),
    );
    return MaterialApp(
      theme: theme ?? BgeTheme.light(),
      locale: const Locale('en', 'US'),
      localizationsDelegates: EventsLocalizations.localizationsDelegates,
      supportedLocales: EventsLocalizations.supportedLocales,
      builder: (context, child) {
        if (offline == null) return child!;
        return ValueListenableBuilder<bool>(
          valueListenable: offline,
          child: child,
          builder: (context, isOffline, app) => BgeConnectivityScope(
            offline: isOffline,
            noticeShowing: isOffline,
            onlineOnlyReason: _onlineOnlyCopy,
            child: app!,
          ),
        );
      },
      home: EventDetailScreen(
        eventId: 'e-1',
        repository: repository,
        remote: remote,
        onBack: (_) {},
        onOfferGames: offers ? recordOffer : null,
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

  /// Shows [detail] (the viewer's, by default) on Details, with the read
  /// every open makes ended.
  Future<void> show(
    WidgetTester tester, {
    EventDetail? detail,
    ValueListenable<bool>? offline,
    bool offers = true,
  }) async {
    offerArgs.clear();
    final shown = detail ?? detailOf();
    await tester.pumpWidget(
      harness(detail: shown, offline: offline, offers: offers),
    );
    cache.add(shown);
    await settle(tester);
    await settle(tester);
  }

  Finder tab(EventDetailTab which) =>
      find.byKey(EventDetailScreen.tabKey(which));

  Future<void> chooseGames(WidgetTester tester) async {
    await tester.tap(tab(EventDetailTab.games));
    await animate(tester);
  }

  /// Shows [detail] and opens the Games tab, with the pool's read ended.
  Future<void> showGames(
    WidgetTester tester, {
    EventDetail? detail,
    ValueListenable<bool>? offline,
    bool offers = true,
  }) async {
    await show(tester, detail: detail, offline: offline, offers: offers);
    await chooseGames(tester);
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

  // Rows below the view are built all the same, a viewport past its edge,
  // and a finder that skips what isn't on screen would pass them over.
  Finder row(String id) =>
      find.byKey(EventDetailScreen.poolRowKey(id), skipOffstage: false);
  Finder takeBack(String id) =>
      find.byKey(EventDetailScreen.poolTakeBackKey(id), skipOffstage: false);

  /// The pool reads made, as event id and attendee ids.
  List<(String, List<String>)> poolReads() => [
    for (final (:eventId, :attendeeIds) in remote.poolRequests)
      (eventId, attendeeIds),
  ];
  Finder outcome() => find.byKey(EventDetailScreen.poolOutcomeKey);
  Finder offerGames() => find.byKey(EventDetailScreen.offerGamesKey);
  Finder search() => find.byKey(EventDetailScreen.poolSearchKey);
  Finder people() => find.byKey(EventDetailScreen.poolPeopleKey);
  Finder notMine() => find.byKey(EventDetailScreen.poolNotMineKey);
  Finder inUse(String attendeeId) =>
      find.byKey(EventDetailScreen.poolInUseKey(attendeeId));

  /// The footer's stale-data banner.
  Finder stale() => find.byKey(EventDetailScreen.poolRefreshBannerKey);

  /// [finder] is in the page's footer: below its one scroll view.
  void expectInFooter(WidgetTester tester, Finder finder) {
    expect(finder, findsOneWidget);
    expect(
      tester.getRect(finder).top,
      greaterThanOrEqualTo(
        tester.getRect(find.byType(CustomScrollView)).bottom,
      ),
    );
  }

  /// Activates the node [label] names, with the tap action, as a screen
  /// reader's double-tap does: no pointer, and no input focus moved.
  void screenReaderTap(WidgetTester tester, String label) =>
      tester.semantics.tap(
        find.semantics.byPredicate(
          (node) =>
              node.label == label &&
              node.getSemanticsData().hasAction(SemanticsAction.tap),
          describeMatch: (_) => 'a node "$label" with a tap',
        ),
      );

  /// Takes focus off every control: on nothing but the page.
  Future<void> focusNothing(WidgetTester tester) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      anyOf(isNull, isA<FocusScopeNode>()),
    );
  }

  /// The rows shown, by offered game id, in order down the page.
  List<String> rowsShown(WidgetTester tester) {
    final ids = [
      for (final game in [catanMine, azul, catanAdas, root, wingspanMine])
        if (row(game.id).evaluate().isNotEmpty) game.id,
    ];
    return ids..sort(
      (a, b) =>
          tester.getTopLeft(row(a)).dy.compareTo(tester.getTopLeft(row(b)).dy),
    );
  }

  /// The page's one scroll view, whose count a screen reader reads.
  CustomScrollView scrollView(WidgetTester tester) =>
      tester.widget<CustomScrollView>(find.byType(CustomScrollView));

  FocusNode takeBackFocus(WidgetTester tester, String id) =>
      tester.widget<ButtonStyleButton>(takeBack(id)).focusNode!;

  FocusNode peopleFocus(WidgetTester tester) =>
      tester.widget<ButtonStyleButton>(people()).focusNode!;

  FocusNode chipFocus(WidgetTester tester, String attendeeId) =>
      tester.widget<InputChip>(inUse(attendeeId)).focusNode!;

  FocusNode searchFocus(WidgetTester tester) =>
      tester.widget<TextField>(search()).focusNode!;

  /// Opens the people sheet, chooses each of [ids], and closes it.
  Future<void> choosePeople(WidgetTester tester, List<String> ids) async {
    await tester.tap(people());
    await animate(tester);
    for (final id in ids) {
      await tester.tap(find.byKey(EventDetailScreen.poolPersonKey(id)));
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await animate(tester);
  }

  group('when the pool is read', () {
    testWidgets("the pool isn't read until the Games tab is opened", (
      tester,
    ) async {
      await show(tester);

      expect(remote.poolRequests, isEmpty);

      await chooseGames(tester);

      expect(poolReads(), hasLength(1));
      expect(poolReads().single.$1, 'e-1');
      expect(poolReads().single.$2, ['att-me', 'att-ada', 'att-bo']);
      expect(row(azul.id), findsOneWidget);
    });

    testWidgets('a detail refresh after that reads it again', (tester) async {
      await showGames(tester);

      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await settle(tester);

      expect(remote.poolRequests, hasLength(2));

      // On Details too, once the tab has been shown.
      await tester.tap(tab(EventDetailTab.details));
      await animate(tester);
      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await settle(tester);

      expect(remote.poolRequests, hasLength(3));
    });

    testWidgets('a refresh before the tab was opened reads nothing', (
      tester,
    ) async {
      await show(tester);

      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await settle(tester);

      expect(remote.detailRequests, hasLength(2));
      expect(remote.poolRequests, isEmpty);
    });

    testWidgets("a withheld roster reads the viewer's own games", (
      tester,
    ) async {
      await showGames(tester, detail: detailOf(roster: const []));

      expect(poolReads(), hasLength(1));
      expect(poolReads().single.$2, ['att-me']);
    });

    testWidgets(
      "with no ids to read nothing is read, and the games aren't shown",
      (tester) async {
        await showGames(
          tester,
          detail: EventDetail(
            snapshot: detailOf().snapshot.copyWith(attendees: const []),
          ),
        );

        expect(remote.poolRequests, isEmpty);
        expect(find.text("The games aren't shown to you"), findsOneWidget);
        expect(search(), findsNothing);
      },
    );
  });

  group('states', () {
    testWidgets('loading, with nothing yet, is a spinner and no header', (
      tester,
    ) async {
      final read = Completer<List<OfferedGame>>();
      poolAnswer = (_) => read.future;

      await showGames(tester);

      expect(find.byType(BgeLoadingState), findsOneWidget);
      expect(find.bySemanticsLabel('Loading the games'), findsOneWidget);
      expect(search(), findsNothing);
      expect(scrollView(tester).semanticChildCount, 0);

      read.complete(served);
      await animate(tester);
      expect(find.byType(BgeLoadingState), findsNothing);
      expect(row(azul.id), findsOneWidget);
    });

    testWidgets('loaded and empty says no games are offered, under the '
        'header', (tester) async {
      served = [];

      await showGames(tester);

      expect(find.text('No games offered yet'), findsOneWidget);
      expect(
        find.text('Games people offer to bring will show here.'),
        findsOneWidget,
      );
      expect(search(), findsOneWidget);
      expect(scrollView(tester).semanticChildCount, 0);
    });

    testWidgets('an empty pool read again shows no spinner meanwhile', (
      tester,
    ) async {
      served = [];
      await showGames(tester);
      final read = Completer<List<OfferedGame>>();
      poolAnswer = (_) => read.future;

      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await settle(tester);

      expect(find.byType(BgeLoadingState), findsNothing);
      expect(find.text('No games offered yet'), findsOneWidget);
      read.complete([]);
      await settle(tester);
    });

    testWidgets('a filter that leaves nothing says so, and Clear filters '
        'clears the search and the people and focuses the search', (
      tester,
    ) async {
      await showGames(tester);
      await tester.tap(notMine());
      await tester.pump();
      await tester.enterText(search(), 'wingspan');
      await tester.pump();

      expect(find.text('No games match'), findsOneWidget);
      expect(scrollView(tester).semanticChildCount, 0);

      await tester.tap(find.byKey(EventDetailScreen.poolClearFiltersKey));
      await animate(tester);

      expect(find.text('No games match'), findsNothing);
      expect(rowsShown(tester), ['o-1', 'o-2', 'o-3', 'o-4']);
      expect(tester.widget<TextField>(search()).controller!.text, isEmpty);
      expect(
        tester.widget<FilterChip>(notMine()).selected,
        isFalse,
      );
      expect(searchFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('failed, with nothing to show, offers Try again, which reads '
        'again', (tester) async {
      poolAnswer = (_) => throw _offline;

      await showGames(tester);

      expect(find.text("Couldn't load the games"), findsOneWidget);
      expect(find.text('Check your connection and try again.'), findsOneWidget);
      // The header stays above it.
      expect(search(), findsOneWidget);

      poolAnswer = (_) => served;
      await tester.tap(find.byKey(EventDetailScreen.poolRetryKey));
      await animate(tester);

      expect(remote.poolRequests, hasLength(2));
      expect(row(azul.id), findsOneWidget);
    });

    testWidgets("hidden says the games aren't shown, with no header", (
      tester,
    ) async {
      poolAnswer = (_) =>
          throw const EventRemoteForbiddenException('no', statusCode: 403);

      await showGames(tester);

      expect(find.text("The games aren't shown to you"), findsOneWidget);
      expect(search(), findsNothing);
      expect(offerGames(), findsNothing);
      expect(scrollView(tester).semanticChildCount, 0);
    });

    testWidgets('gone reads the event again, as the poll does, and claims '
        'nothing meanwhile', (tester) async {
      poolAnswer = (_) =>
          throw const EventRemoteNotFoundException('gone', statusCode: 404);
      await show(tester);
      final reads = remote.detailRequests.length;

      await chooseGames(tester);
      await settle(tester);

      expect(remote.detailRequests, hasLength(reads + 1));
      // What the wait for a first answer draws: a 404 can mean only a stale
      // roster, so nothing says the pool is empty.
      expect(find.byType(BgeLoadingState), findsOneWidget);
      expect(find.byType(BgeEmptyState), findsNothing);
      expect(find.textContaining('No games'), findsNothing);
      expect(search(), findsNothing);
      expect(scrollView(tester).semanticChildCount, 0);
    });

    testWidgets("gone, then the read after the event's own finds games, "
        'shows them', (tester) async {
      poolAnswer = (_) =>
          throw const EventRemoteNotFoundException('gone', statusCode: 404);
      await show(tester);
      await chooseGames(tester);
      poolAnswer = (_) => served;

      // The event's read again, which the 404 asked for, ends; its end reads
      // the pool.
      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await animate(tester);

      expect(find.byType(BgeLoadingState), findsNothing);
      expect(row(azul.id), findsOneWidget);
    });

    testWidgets('a failed read again keeps the rows, with a refresh banner '
        'in the footer whose retry reads again', (tester) async {
      await showGames(tester);
      poolAnswer = (_) => throw _offline;

      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await settle(tester);

      expect(
        find.descendant(
          of: stale(),
          matching: find.text(
            "Couldn't update the games. These may be out of date.",
          ),
        ),
        findsOneWidget,
      );
      expectInFooter(tester, stale());
      expect(row(azul.id), findsOneWidget);

      poolAnswer = (_) => served;
      await tester.tap(find.byKey(EventDetailScreen.poolRetryKey));
      await animate(tester);

      expect(
        find.text("Couldn't update the games. These may be out of date."),
        findsNothing,
      );
    });
  });

  group('rows', () {
    testWidgets("a row says the game, where it's played, and who brings it, "
        'as one node', (tester) async {
      final handle = tester.ensureSemantics();
      await showGames(tester);

      expect(
        tester.getSemantics(
          find.descendant(of: row(catanAdas.id), matching: find.text('Catan')),
        ),
        matchesSemantics(
          label: 'Catan\nBoard Game Arena, Digital\nAda is bringing this',
        ),
      );
      expect(
        find.descendant(
          of: row(catanAdas.id),
          matching: find.text('Board Game Arena · Digital'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(
          find.descendant(of: row(catanMine.id), matching: find.text('Catan')),
        ),
        matchesSemantics(
          label: "Catan\nTabletop, Physical\nYou're bringing this",
        ),
      );
      // No medium: the platform alone.
      expect(
        find.descendant(
          of: row(root.id),
          matching: find.text('Tabletop', skipOffstage: false),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets("two people's copies of one game are two rows", (tester) async {
      await showGames(tester);

      expect(rowsShown(tester), ['o-1', 'o-2', 'o-3', 'o-4']);
      expect(find.text('Catan'), findsNWidgets(2));
      expect(scrollView(tester).semanticChildCount, 4);
    });

    testWidgets("someone the roster doesn't name is this person", (
      tester,
    ) async {
      served = [_game('o-9', 'att-nn', 'Azul')];

      await showGames(
        tester,
        detail: detailOf(roster: [me, _row('att-nn')]),
      );

      expect(find.text('This person is bringing this'), findsOneWidget);
    });

    testWidgets("only the viewer's rows have Take back", (tester) async {
      await showGames(tester);

      expect(takeBack(catanMine.id), findsOneWidget);
      for (final game in [azul, catanAdas, root]) {
        expect(takeBack(game.id), findsNothing, reason: game.title);
      }
      expect(
        tester.getSemantics(takeBack(catanMine.id)),
        matchesSemantics(
          label: 'Take back Catan',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasFocusAction: true,
          hasTapAction: true,
        ),
      );
    });

    testWidgets("a spectator's own rows have none", (tester) async {
      final spectator = _row('att-me', name: 'Me', role: EventRole.spectator);

      await showGames(tester, detail: detailOf(viewer: spectator));

      expect(row(catanMine.id), findsOneWidget);
      expect(find.text("You're bringing this"), findsOneWidget);
      expect(takeBack(catanMine.id), findsNothing);
    });
  });

  group('the filter', () {
    testWidgets("Not mine leaves the viewer's games out", (tester) async {
      served = [catanMine, azul, wingspanMine, root];
      await showGames(tester);

      await tester.tap(notMine());
      await tester.pump();

      expect(rowsShown(tester), ['o-2', 'o-4']);
      expect(tester.widget<FilterChip>(notMine()).selected, isTrue);
      expect(scrollView(tester).semanticChildCount, 2);
      expect(find.text('People: 1'), findsOneWidget);

      await tester.tap(notMine());
      await tester.pump();

      expect(rowsShown(tester), ['o-1', 'o-2', 'o-5', 'o-4']);
      expect(find.text('People'), findsOneWidget);
    });

    testWidgets('choosing a person shows only theirs, and the chip removes '
        'it', (tester) async {
      await showGames(tester);

      await choosePeople(tester, ['att-ada']);

      expect(rowsShown(tester), ['o-2', 'o-3']);
      expect(find.text('People: 1'), findsOneWidget);
      expect(inUse('att-ada'), findsOneWidget);
      expect(
        find.descendant(of: inUse('att-ada'), matching: find.text('Ada')),
        findsOneWidget,
      );

      await tester.tap(inUse('att-ada'));
      await tester.pump();

      expect(inUse('att-ada'), findsNothing);
      expect(rowsShown(tester), ['o-1', 'o-2', 'o-3', 'o-4']);
    });

    testWidgets('leaving a person out says "Not" on their chip', (
      tester,
    ) async {
      await showGames(tester);
      await tester.tap(people());
      await animate(tester);

      final leaveOut = find.byKey(EventDetailScreen.poolLeaveOutKey);
      expect(tester.widget<SwitchListTile>(leaveOut).onChanged, isNull);
      await tester.tap(find.byKey(EventDetailScreen.poolPersonKey('att-ada')));
      await tester.pump();
      expect(tester.widget<SwitchListTile>(leaveOut).onChanged, isNotNull);
      await tester.tap(leaveOut);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);

      expect(rowsShown(tester), ['o-1', 'o-4']);
      expect(
        find.descendant(of: inUse('att-ada'), matching: find.text('Not Ada')),
        findsOneWidget,
      );
    });

    testWidgets('the sheet lists the viewer first, then the roster, and only '
        'people with a game; focus returns to People', (tester) async {
      served = [root, azul, catanMine];
      await showGames(tester);

      await tester.tap(people());
      await animate(tester);

      final chips = [
        for (final id in ['att-me', 'att-ada', 'att-bo'])
          find.byKey(EventDetailScreen.poolPersonKey(id)),
      ];
      for (final chip in chips) {
        expect(chip, findsOneWidget);
      }
      final xs = [for (final chip in chips) tester.getTopLeft(chip)];
      for (var i = 1; i < xs.length; i++) {
        expect(
          xs[i].dy > xs[i - 1].dy ||
              (xs[i].dy == xs[i - 1].dy && xs[i].dx > xs[i - 1].dx),
          isTrue,
          reason: 'chip $i follows chip ${i - 1}',
        );
      }
      expect(
        find.descendant(of: chips.first, matching: find.text('You')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Whose games'), findsWidgets);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);

      expect(peopleFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('with nothing offered, Not mine shows no count', (
      tester,
    ) async {
      served = [];
      await showGames(tester);

      await tester.tap(notMine());
      await tester.pump();

      expect(tester.widget<FilterChip>(notMine()).selected, isTrue);
      expect(find.byKey(EventDetailScreen.poolCountKey), findsNothing);
      expect(find.text('0 games of 0'), findsNothing);
      expect(find.text('No games offered yet'), findsOneWidget);
    });

    testWidgets('the count is a live region', (tester) async {
      final handle = tester.ensureSemantics();
      await showGames(tester);

      expect(find.byKey(EventDetailScreen.poolCountKey), findsNothing);

      await tester.enterText(search(), 'catan');
      await tester.pump();

      final count = find.byKey(EventDetailScreen.poolCountKey);
      expect(find.text('2 games of 4'), findsOneWidget);
      expect(
        tester.getSemantics(count),
        matchesSemantics(label: '2 games of 4', isLiveRegion: true),
      );

      await tester.enterText(search(), 'azul');
      await tester.pump();
      expect(find.text('1 game of 4'), findsOneWidget);
      handle.dispose();
    });

    group('a chip removed', () {
      Future<void> chooseAll(WidgetTester tester) =>
          choosePeople(tester, ['att-me', 'att-ada', 'att-bo']);

      testWidgets('with focus on it hands focus to the chip in its place', (
        tester,
      ) async {
        await showGames(tester);
        await chooseAll(tester);
        chipFocus(tester, 'att-ada').requestFocus();
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);

        expect(inUse('att-ada'), findsNothing);
        expect(chipFocus(tester, 'att-bo').hasPrimaryFocus, isTrue);
      });

      testWidgets('the last, with focus on it, hands focus to the one before', (
        tester,
      ) async {
        await showGames(tester);
        await chooseAll(tester);
        chipFocus(tester, 'att-bo').requestFocus();
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);

        expect(chipFocus(tester, 'att-ada').hasPrimaryFocus, isTrue);
      });

      testWidgets('the only one, with focus on it, hands focus to People', (
        tester,
      ) async {
        await showGames(tester);
        await choosePeople(tester, ['att-ada']);
        chipFocus(tester, 'att-ada').requestFocus();
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);

        expect(inUse('att-ada'), findsNothing);
        expect(peopleFocus(tester).hasPrimaryFocus, isTrue);
      });

      testWidgets('by pointer, with focus on another chip, moves no focus', (
        tester,
      ) async {
        await showGames(tester);
        await chooseAll(tester);
        final kept = chipFocus(tester, 'att-me')..requestFocus();
        await tester.pump();

        await tester.tap(inUse('att-ada'));
        await animate(tester);

        expect(inUse('att-ada'), findsNothing);
        expect(kept.hasPrimaryFocus, isTrue);
      });

      testWidgets('by pointer, with focus on nothing, hands focus to the chip '
          'in its place', (tester) async {
        await showGames(tester);
        await chooseAll(tester);
        await focusNothing(tester);

        await tester.tap(inUse('att-ada'));
        await animate(tester);

        expect(inUse('att-ada'), findsNothing);
        expect(chipFocus(tester, 'att-bo').hasPrimaryFocus, isTrue);
      });

      testWidgets("by a screen reader's activation hands focus to the chip in "
          'its place', (tester) async {
        final handle = tester.ensureSemantics();
        await showGames(tester);
        await chooseAll(tester);
        await focusNothing(tester);

        screenReaderTap(tester, 'Ada');
        await animate(tester);

        expect(inUse('att-ada'), findsNothing);
        expect(chipFocus(tester, 'att-bo').hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets("the only one, by a screen reader's activation, hands focus "
          'to People', (tester) async {
        final handle = tester.ensureSemantics();
        await showGames(tester);
        await choosePeople(tester, ['att-ada']);
        await focusNothing(tester);

        screenReaderTap(tester, 'Ada');
        await animate(tester);

        expect(inUse('att-ada'), findsNothing);
        expect(peopleFocus(tester).hasPrimaryFocus, isTrue);
        handle.dispose();
      });
    });
  });

  group('Take back', () {
    testWidgets('sends the viewer, the event and the game, and the footer says '
        "it's off", (tester) async {
      await showGames(tester);
      served = [azul, catanAdas, root];

      await tester.tap(takeBack(catanMine.id));
      await animate(tester);

      expect(remote.takeBacks, [
        (eventId: 'e-1', attendeeId: 'att-me', offeredGameId: 'o-1'),
      ]);
      expect(row(catanMine.id), findsNothing);
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text('Catan is off your games.'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(of: outcome(), matching: find.text('Dismiss')),
      );
      await tester.pump();
      expect(outcome(), findsNothing);
    });

    testWidgets('a 409 says the game is nominated or in the lineup, in the '
        'footer', (tester) async {
      takeBackAnswer = (_) => throw const EventWriteConflictException(
        'supplies',
        statusCode: 409,
      );
      await showGames(tester);

      await tester.tap(takeBack(catanMine.id));
      await animate(tester);

      expect(
        find.descendant(of: outcome(), matching: find.text(_stillSuppliesCopy)),
        findsOneWidget,
      );
      expect(row(catanMine.id), findsOneWidget);
      // In the footer: below the page's one scroll view.
      expect(
        tester.getRect(outcome()).top,
        greaterThanOrEqualTo(
          tester.getRect(find.byType(CustomScrollView)).bottom,
        ),
      );
    });

    testWidgets('a refusal and a failure each say so', (tester) async {
      takeBackAnswer = (_) =>
          throw const EventWriteRefusedException('no', statusCode: 403);
      await showGames(tester);

      await tester.tap(takeBack(catanMine.id));
      await animate(tester);
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text("You can't take Catan back."),
        ),
        findsOneWidget,
      );

      takeBackAnswer = (_) => throw _offline;
      await tester.tap(takeBack(catanMine.id));
      await animate(tester);
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text("Couldn't take Catan back. Try again."),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the same outcome twice is a new banner', (tester) async {
      takeBackAnswer = (_) => throw _offline;
      await showGames(tester);
      await tester.tap(takeBack(catanMine.id));
      await animate(tester);
      final first = tester.element(outcome());

      await tester.tap(takeBack(catanMine.id));
      await animate(tester);

      expect(remote.takeBacks, hasLength(2));
      expect(tester.element(outcome()), isNot(same(first)));
    });

    testWidgets('the same drop twice is announced twice', (tester) async {
      final handle = tester.ensureSemantics();
      await showGames(tester);
      const dropped = EventGamesWriteDropped(
        EventGamesWrite.takeBack,
        title: 'Catan',
      );
      const copy = "Catan wasn't taken back: the event changed first.";

      blocOf<EventGamesBloc>(tester).add(dropped);
      await settle(tester);
      final first = tester.element(outcome());
      // The banner's message: its one live-region node.
      SemanticsNode message() => tester.getSemantics(
        find.descendant(of: outcome(), matching: find.text(copy)),
      );
      final firstNode = message().id;
      expect(message(), isSemantics(isLiveRegion: true));
      blocOf<EventGamesBloc>(tester).add(dropped);
      await settle(tester);

      // A new banner, whose live region is a node of its own, which appears
      // and so is announced, though its words are the same.
      expect(tester.element(outcome()), isNot(same(first)));
      expect(message().id, isNot(firstNode));
      expect(message(), isSemantics(isLiveRegion: true, label: copy));
      handle.dispose();
    });

    testWidgets('a take-back that lands, then a read that fails: the outcome '
        'and the stale banner are both in the footer, the outcome first', (
      tester,
    ) async {
      await showGames(tester);
      poolAnswer = (_) => throw _offline;

      await tester.tap(takeBack(catanMine.id));
      await animate(tester);

      expect(remote.takeBacks, hasLength(1));
      // The read after it failed: Catan's row is still shown.
      expect(row(catanMine.id), findsOneWidget);
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text('Catan is off your games.'),
        ),
        findsOneWidget,
      );
      expectInFooter(tester, outcome());
      expectInFooter(tester, stale());
      expect(
        tester.getRect(outcome()).top,
        lessThan(tester.getRect(stale()).top),
      );
      // The tab's header holds no stale banner.
      expect(
        find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.text(
            "Couldn't update the games. These may be out of date.",
            skipOffstage: false,
          ),
          skipOffstage: false,
        ),
        findsNothing,
      );
    });

    testWidgets('Take back sends nothing if the row left while a read was '
        'running, and the footer says so', (tester) async {
      await showGames(tester);
      final detail = blocOf<EventDetailBloc>(tester);
      heldRead = Completer<EventSnapshot>();

      // A read starts, and the press lands before a frame shows it.
      detail.add(const EventDetailRetryRequested());
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      expect((detail.state as EventDetailReady).reading, isTrue);
      await tester.tap(takeBack(catanMine.id));

      // Meanwhile a read of the pool finds the game gone.
      served = [azul, catanAdas, root];
      blocOf<EventGamesBloc>(tester).add(
        const EventGamesRequested('e-1', ['att-me', 'att-ada', 'att-bo']),
      );
      await settle(tester);
      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);

      expect(remote.takeBacks, isEmpty);
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text(
            "Catan wasn't taken back: the event changed "
            'first.',
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('is disabled while a detail read runs', (tester) async {
      await showGames(tester);
      heldRead = Completer<EventSnapshot>();

      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);

      expect(
        tester.widget<ButtonStyleButton>(takeBack(catanMine.id)).onPressed,
        isNull,
      );

      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await settle(tester);
      await settle(tester);
      expect(
        tester.widget<ButtonStyleButton>(takeBack(catanMine.id)).onPressed,
        isNotNull,
      );
    });

    group('after a take back, focus goes', () {
      Future<void> takeBackByKeyboard(WidgetTester tester, String id) async {
        takeBackFocus(tester, id).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);
        await animate(tester);
      }

      testWidgets("to the next row's Take back", (tester) async {
        served = [catanMine, azul, wingspanMine];
        await showGames(tester);
        served = [azul, wingspanMine];

        await takeBackByKeyboard(tester, catanMine.id);

        expect(row(catanMine.id), findsNothing);
        expect(takeBackFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
      });

      testWidgets("to the previous row's, from the last", (tester) async {
        served = [catanMine, azul, wingspanMine];
        await showGames(tester);
        served = [catanMine, azul];

        await takeBackByKeyboard(tester, wingspanMine.id);

        expect(takeBackFocus(tester, catanMine.id).hasPrimaryFocus, isTrue);
      });

      testWidgets('to Offer games, from the only one', (tester) async {
        await showGames(tester);
        served = [azul, catanAdas, root];

        await takeBackByKeyboard(tester, catanMine.id);

        expect(
          tester
              .widget<ButtonStyleButton>(offerGames())
              .focusNode!
              .hasPrimaryFocus,
          isTrue,
        );
      });

      testWidgets('nowhere, when something else took focus meanwhile', (
        tester,
      ) async {
        await showGames(tester);
        final read = Completer<List<OfferedGame>>();
        poolAnswer = (_) => read.future;
        takeBackFocus(tester, catanMine.id).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);

        searchFocus(tester).requestFocus();
        await tester.pump();
        read.complete([azul, catanAdas, root]);
        await animate(tester);

        expect(searchFocus(tester).hasPrimaryFocus, isTrue);
      });

      testWidgets("by a screen reader's activation, with focus on nothing, "
          "to the next row's Take back", (tester) async {
        final handle = tester.ensureSemantics();
        served = [catanMine, azul, wingspanMine];
        await showGames(tester);
        served = [azul, wingspanMine];
        await focusNothing(tester);

        screenReaderTap(tester, 'Take back Catan');
        await animate(tester);
        await animate(tester);

        expect(remote.takeBacks, hasLength(1));
        expect(row(catanMine.id), findsNothing);
        expect(takeBackFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets("by pointer, with focus on nothing, to the next row's Take "
          'back', (tester) async {
        served = [catanMine, azul, wingspanMine];
        await showGames(tester);
        served = [azul, wingspanMine];
        await focusNothing(tester);

        await tester.tap(takeBack(catanMine.id));
        await animate(tester);
        await animate(tester);

        expect(takeBackFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
      });

      testWidgets('to the search field, with no Offer games built', (
        tester,
      ) async {
        await showGames(tester, offers: false);
        served = [azul, catanAdas, root];

        await takeBackByKeyboard(tester, catanMine.id);

        expect(offerGames(), findsNothing);
        expect(searchFocus(tester).hasPrimaryFocus, isTrue);
      });

      testWidgets('nowhere of the tab, when the pool turns hidden: it stays '
          'on the page', (tester) async {
        await showGames(tester);
        poolAnswer = (_) =>
            throw const EventRemoteForbiddenException('no', statusCode: 403);

        await takeBackByKeyboard(tester, catanMine.id);

        expect(find.text("The games aren't shown to you"), findsOneWidget);
        expect(search(), findsNothing);
        expect(tester.takeException(), isNull);
        expect(FocusManager.instance.primaryFocus, isA<FocusScopeNode>());
      });

      testWidgets('nowhere, when the take-back is refused and its row stays', (
        tester,
      ) async {
        takeBackAnswer = (_) =>
            throw const EventWriteRefusedException('no', statusCode: 403);
        served = [catanMine, azul, wingspanMine];
        await showGames(tester);
        await focusNothing(tester);
        await tester.tap(takeBack(catanMine.id));
        await animate(tester);

        // A later read that takes the row away, with no press of its own.
        served = [azul, wingspanMine];
        blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
        await settle(tester);
        await animate(tester);

        expect(row(catanMine.id), findsNothing);
        expect(
          FocusManager.instance.primaryFocus,
          anyOf(isNull, isA<FocusScopeNode>()),
        );
      });
    });

    testWidgets('Take back is disabled offline and says why once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      served = [catanMine, azul, wingspanMine];
      await showGames(tester, offline: offline);

      for (final game in [catanMine, wingspanMine]) {
        await tester.ensureVisible(takeBack(game.id));
        await tester.pump();
        expect(
          tester.widget<ButtonStyleButton>(takeBack(game.id)).onPressed,
          isNull,
        );
        expect(
          tester.getSemantics(takeBack(game.id)),
          matchesSemantics(
            label: 'Take back ${game.title}',
            hint: _onlineOnlyCopy,
            isButton: true,
            hasEnabledState: true,
          ),
        );
      }
      // Drawn once for the tab, not once a row.
      expect(find.text(_onlineOnlyCopy), findsOneWidget);

      offline.value = false;
      await tester.pump();

      expect(find.text(_onlineOnlyCopy), findsNothing);
      expect(
        tester.widget<ButtonStyleButton>(takeBack(catanMine.id)).onPressed,
        isNotNull,
      );
      handle.dispose();
    });
  });

  group('Offer games', () {
    testWidgets('is not built for a spectator', (tester) async {
      await showGames(
        tester,
        detail: detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.spectator),
        ),
      );

      expect(search(), findsOneWidget);
      expect(offerGames(), findsNothing);
    });

    testWidgets('is not built with no way to the page', (tester) async {
      await showGames(tester, offers: false);

      expect(search(), findsOneWidget);
      expect(offerGames(), findsNothing);
      // Take back doesn't need the page.
      expect(takeBack(catanMine.id), findsOneWidget);
    });

    testWidgets('is disabled with its reason when the viewer is not going', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await showGames(
        tester,
        detail: detailOf(
          viewer: _row(
            'att-me',
            name: 'Me',
            status: EventParticipationStatus.notAttending,
          ),
        ),
      );

      expect(tester.widget<ButtonStyleButton>(offerGames()).onPressed, isNull);
      expect(find.text(_notGoingCopy), findsOneWidget);
      expect(
        tester.getSemantics(offerGames()),
        matchesSemantics(
          label: 'Offer games',
          hint: _notGoingCopy,
          isButton: true,
          hasEnabledState: true,
        ),
      );
      // Take back is still theirs.
      expect(
        tester.widget<ButtonStyleButton>(takeBack(catanMine.id)).onPressed,
        isNotNull,
      );
      handle.dispose();
    });

    testWidgets('is disabled offline, and says why', (tester) async {
      final handle = tester.ensureSemantics();
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      await showGames(tester, offline: offline);

      expect(tester.widget<ButtonStyleButton>(offerGames()).onPressed, isNull);
      expect(
        tester.getSemantics(offerGames()),
        matchesSemantics(
          label: 'Offer games',
          hint: _onlineOnlyCopy,
          isButton: true,
          hasEnabledState: true,
        ),
      );

      offline.value = false;
      await tester.pump();
      expect(
        tester.widget<ButtonStyleButton>(offerGames()).onPressed,
        isNotNull,
      );
      handle.dispose();
    });

    testWidgets('is disabled while a take-back is out', (tester) async {
      final held = Completer<void>();
      takeBackAnswer = (_) => held.future;
      await showGames(tester);
      expect(
        tester.widget<ButtonStyleButton>(offerGames()).onPressed,
        isNotNull,
      );

      await tester.tap(takeBack(catanMine.id));
      await settle(tester);

      expect(tester.widget<ButtonStyleButton>(offerGames()).onPressed, isNull);

      held.complete();
      await animate(tester);
      expect(
        tester.widget<ButtonStyleButton>(offerGames()).onPressed,
        isNotNull,
      );
    });

    testWidgets('is disabled while a detail read runs', (tester) async {
      await showGames(tester);
      heldRead = Completer<EventSnapshot>();

      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);

      expect(tester.widget<ButtonStyleButton>(offerGames()).onPressed, isNull);

      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await settle(tester);
      await settle(tester);
      expect(
        tester.widget<ButtonStyleButton>(offerGames()).onPressed,
        isNotNull,
      );
    });

    testWidgets("a press passes the viewer's offered collection ids", (
      tester,
    ) async {
      served = [catanMine, azul, wingspanMine];
      await showGames(tester);

      await tester.tap(offerGames());
      await animate(tester);

      expect(offerArgs, [
        const OfferGamesArgs(offeredCollectionIds: {'col-o-1', 'col-o-5'}),
      ]);
    });
  });

  group('accessibility audit', () {
    testWidgets('at 320×640 and 200% text, the footer holds an outcome and '
        'the stale banner, and both their buttons are reached by pointer and '
        'by keyboard', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await showGames(tester);
      poolAnswer = (_) => throw _offline;
      takeBackAnswer = (_) => throw const EventWriteConflictException(
        'supplies',
        statusCode: 409,
      );
      await tester.ensureVisible(takeBack(catanMine.id));
      await tester.pump();
      await tester.tap(takeBack(catanMine.id));
      await animate(tester);
      // The 409 reads nothing again; a detail read's end does, and fails.
      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await animate(tester);

      expect(tester.takeException(), isNull);
      final dismiss = find.descendant(
        of: outcome(),
        matching: find.byType(TextButton),
      );
      final retry = find.byKey(EventDetailScreen.poolRetryKey);
      expect(dismiss, findsOneWidget);
      expect(retry, findsOneWidget);
      // The footer holds at most half the body and scrolls within it.
      final view = tester.getRect(find.byType(CustomScrollView));
      final body = tester.getRect(
        find
            .descendant(
              of: find.byType(Scaffold).first,
              matching: find.byType(SafeArea),
            )
            .first,
      );
      expect(view.height, greaterThanOrEqualTo(body.height / 2 - 1));

      // By keyboard: Dismiss, then Tab to Try again, each brought into view.
      final dismissFocus = Focus.of(
        tester.element(
          find.descendant(of: dismiss, matching: find.byType(Text)),
        ),
      )..requestFocus();
      await tester.pump();
      expect(dismissFocus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await animate(tester);
      final retryFocus = tester.widget<ButtonStyleButton>(retry).focusNode!;
      expect(retryFocus.hasPrimaryFocus, isTrue);
      expect(tester.getRect(retry).bottom, lessThanOrEqualTo(640));
      expect(tester.getRect(retry).top, greaterThanOrEqualTo(view.bottom));

      // By pointer: each scrolled to and pressed.
      poolAnswer = (_) => served;
      await tester.ensureVisible(retry);
      await tester.pump();
      await tester.tap(retry);
      await animate(tester);
      expect(stale(), findsNothing);
      await tester.ensureVisible(dismiss);
      await tester.pump();
      await tester.tap(dismiss);
      await tester.pump();
      expect(outcome(), findsNothing);
    });

    testWidgets('the Games tab at 320×640 and 200% text, with a long title: '
        'no overflow, the guidelines pass, and the count is the rows', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final handle = tester.ensureSemantics();
      served = [_game('o-1', 'att-me', _longTitle), azul, root];

      await showGames(tester);

      expect(tester.takeException(), isNull);
      expect(scrollView(tester).semanticChildCount, 3);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text(_longTitle),
          matching: find.byType(RichText),
        ),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      await expectMeetsAccessibilityGuidelines(tester);
      handle.dispose();
    });

    /// The cache's answer, then the Games tab.
    Future<void> arrangeGames(WidgetTester tester) async {
      cache.add(detailOf());
      await settle(tester);
      await settle(tester);
      await chooseGames(tester);
    }

    auditScreen(
      'EventDetailScreen, on the Games tab with a pool',
      build: (theme) => harness(detail: detailOf(), theme: theme),
      arrange: (tester) async {
        await arrangeGames(tester);
        expect(row(azul.id), findsOneWidget);
      },
    );

    auditScreen(
      'EventDetailScreen, the Games tab with Whose games open',
      build: (theme) => harness(detail: detailOf(), theme: theme),
      arrange: (tester) async {
        await arrangeGames(tester);
        await tester.tap(people());
        await animate(tester);
        expect(
          find.byKey(EventDetailScreen.poolPersonKey('att-bo')),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'EventDetailScreen, the Games tab when no game matches',
      build: (theme) => harness(detail: detailOf(), theme: theme),
      arrange: (tester) async {
        await arrangeGames(tester);
        await tester.enterText(search(), 'gloomhaven');
        await tester.pump();
        expect(find.text('No games match'), findsOneWidget);
      },
    );

    auditScreen(
      'EventDetailScreen, the Games tab when the pool failed',
      build: (theme) => harness(detail: detailOf(), theme: theme),
      arrange: (tester) async {
        poolAnswer = (_) => throw _offline;
        await arrangeGames(tester);
        expect(find.text("Couldn't load the games"), findsOneWidget);
      },
    );

    auditScreen(
      'EventDetailScreen, the Games tab when the games are hidden',
      build: (theme) => harness(detail: detailOf(), theme: theme),
      arrange: (tester) async {
        poolAnswer = (_) =>
            throw const EventRemoteForbiddenException('no', statusCode: 403);
        await arrangeGames(tester);
        expect(find.text("The games aren't shown to you"), findsOneWidget);
      },
    );

    auditScreen(
      'EventDetailScreen, the Games tab while the pool loads',
      build: (theme) => harness(detail: detailOf(), theme: theme),
      settle: false,
      arrange: (tester) async {
        poolAnswer = (_) => Completer<List<OfferedGame>>().future;
        await arrangeGames(tester);
        expect(find.byType(BgeLoadingState), findsOneWidget);
      },
    );
  });
}
