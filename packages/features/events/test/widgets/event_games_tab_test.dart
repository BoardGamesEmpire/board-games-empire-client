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

  /// What each offer answers: the game as the server holds it, unless a
  /// test says otherwise.
  late FutureOr<OfferedGame> Function(OfferGameRequest request) offerAnswer;

  /// What the Offer games page answers with, once opened.
  late Future<List<OfferPick>?> Function(BuildContext context) pageAnswer;

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
    offerAnswer = (request) => _game(
      'o-${request.collectionId}',
      request.attendeeId,
      request.collectionId,
    );
    pageAnswer = (_) async => null;
    heldRead = null;
  });

  tearDown(() {
    unawaited(cache.close());
  });

  /// Offer games' press, which records what it was given and answers as
  /// [pageAnswer] does: with no picks, unless a test says otherwise.
  final offerArgs = <OfferGamesArgs>[];
  Future<List<OfferPick>?> recordOffer(
    BuildContext context,
    OfferGamesArgs args,
  ) {
    offerArgs.add(args);
    return pageAnswer(context);
  }

  /// The session check's answers, in order, once a test guards the
  /// screen with one; yes once they run out.
  final sessionAnswers = <bool>[];
  Future<bool> confirmSession() async =>
      sessionAnswers.isEmpty || sessionAnswers.removeAt(0);

  Widget harness({
    required EventDetail detail,
    ValueListenable<bool>? offline,
    bool offers = true,
    bool guarded = false,
    ThemeData? theme,
  }) {
    remote = FakeEventRemote.detail(
      (_) => heldRead?.future ?? detail.snapshot,
      pool: (request) => poolAnswer(request),
      offered: (request) => offerAnswer(request),
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
        confirmSession: guarded ? confirmSession : null,
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
    bool guarded = false,
  }) async {
    offerArgs.clear();
    sessionAnswers.clear();
    final shown = detail ?? detailOf();
    await tester.pumpWidget(
      harness(
        detail: shown,
        offline: offline,
        offers: offers,
        guarded: guarded,
      ),
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
    bool guarded = false,
  }) async {
    await show(
      tester,
      detail: detail,
      offline: offline,
      offers: offers,
      guarded: guarded,
    );
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

    testWidgets('opened while the opening read is out, the pool is read once, '
        'after it', (tester) async {
      heldRead = Completer<EventSnapshot>();
      await show(tester);
      expect(
        (blocOf<EventDetailBloc>(tester).state as EventDetailReady).reading,
        isTrue,
      );

      await chooseGames(tester);

      // Waiting for the read, whose roster it reads.
      expect(remote.poolRequests, isEmpty);
      expect(find.byType(BgeLoadingState), findsOneWidget);

      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);
      await animate(tester);

      expect(poolReads(), hasLength(1));
      expect(poolReads().single.$1, 'e-1');
      expect(poolReads().single.$2, ['att-me', 'att-ada', 'att-bo']);
      expect(row(azul.id), findsOneWidget);
    });

    // A read of the event settles before the cache delivers what it wrote,
    // so the roster can arrive a beat after the read has ended.
    group('the roster arriving after its read has ended', () {
      testWidgets('a roster not cached, arriving after the opening read, is '
          'read for once, with no failure drawn meanwhile', (tester) async {
        heldRead = Completer<EventSnapshot>();
        await show(
          tester,
          detail: EventDetail(snapshot: detailOf(rosterGiven: false).snapshot),
        );
        await chooseGames(tester);

        heldRead!.complete(detailOf().snapshot);
        heldRead = null;
        await animate(tester);

        expect(remote.poolRequests, isEmpty);
        expect(find.byType(BgeLoadingState), findsOneWidget);
        expect(find.text("Couldn't load the games"), findsNothing);

        cache.add(detailOf());
        await animate(tester);
        await animate(tester);

        expect(poolReads(), hasLength(1));
        expect(poolReads().single.$2, ['att-me', 'att-ada', 'att-bo']);
        expect(row(azul.id), findsOneWidget);
      });

      testWidgets('a roster with someone new, arriving after a later read, is '
          'read for again', (tester) async {
        await showGames(tester);
        expect(remote.poolRequests, hasLength(1));

        blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
        await animate(tester);
        expect(remote.poolRequests, hasLength(2));

        final cy = _row('att-cy', name: 'Cy');
        cache.add(detailOf(roster: [me, ada, bo, cy]));
        await animate(tester);

        expect(remote.poolRequests, hasLength(3));
        expect(poolReads().last.$2, ['att-me', 'att-ada', 'att-bo', 'att-cy']);
      });

      testWidgets('the same roster, arriving after a read, is not read for '
          'twice', (tester) async {
        await showGames(tester);

        blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
        await animate(tester);
        cache.add(detailOf());
        await animate(tester);

        expect(remote.poolRequests, hasLength(2));
      });

      // Through the screen's own detail bloc: the read answers a roster
      // withheld from this viewer, and the cache, which keeps no rows for
      // an empty roster, answers none before and after it.
      testWidgets('a roster the read withholds, with none cached, says the '
          "games aren't shown, with no spinner left and no pool read", (
        tester,
      ) async {
        final uncached = EventDetail(
          snapshot: detailOf(rosterGiven: false).snapshot,
        );
        heldRead = Completer<EventSnapshot>();
        await show(tester, detail: uncached);
        await chooseGames(tester);

        heldRead!.complete(uncached.snapshot.copyWith(attendees: const []));
        heldRead = null;
        await animate(tester);
        await animate(tester);

        expect(find.text("The games aren't shown to you"), findsOneWidget);
        expect(find.byType(BgeLoadingState), findsNothing);
        expect(remote.poolRequests, isEmpty);
      });

      testWidgets('a roster taken away reads nothing', (tester) async {
        await showGames(tester);

        cache.add(
          EventDetail(snapshot: detailOf().snapshot.copyWith(attendees: [])),
        );
        await animate(tester);

        expect(remote.poolRequests, hasLength(1));
        expect(find.text("The games aren't shown to you"), findsOneWidget);
      });

      // The games it showed before are as old as the roster's absence.
      testWidgets('a roster taken away and given back unchanged is read for '
          'again', (tester) async {
        await showGames(tester);

        cache.add(
          EventDetail(snapshot: detailOf().snapshot.copyWith(attendees: [])),
        );
        await animate(tester);
        cache.add(detailOf());
        await animate(tester);

        expect(remote.poolRequests, hasLength(2));
        expect(poolReads().last.$2, ['att-me', 'att-ada', 'att-bo']);
        expect(row(azul.id), findsOneWidget);
      });
    });

    // What a read again draws is the last read's end, whichever tab was
    // showing as it ended.
    testWidgets('a read again draws the last answer, though that one landed '
        'while Details was showing', (tester) async {
      poolAnswer = (_) => throw _offline;
      await showGames(tester);
      expect(find.text("Couldn't load the games"), findsOneWidget);

      await tester.tap(tab(EventDetailTab.details));
      await animate(tester);
      poolAnswer = (_) => const [];
      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await animate(tester);
      await animate(tester);
      expect(blocOf<EventGamesBloc>(tester).state.load, EventGamesLoad.loaded);

      final held = Completer<List<OfferedGame>>();
      poolAnswer = (_) => held.future;
      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await animate(tester);
      await animate(tester);
      expect(blocOf<EventGamesBloc>(tester).state.load, EventGamesLoad.loading);

      await chooseGames(tester);

      expect(find.text("Couldn't load the games"), findsNothing);
      expect(find.text('No games offered yet'), findsOneWidget);

      held.complete(const []);
      await animate(tester);
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

    group('a roster not read, as an event cached from the list has', () {
      // No roster and no row of the viewer's: nothing to read the pool for
      // until the event's read brings the roster.
      final unread = EventDetail(
        snapshot: detailOf(rosterGiven: false).snapshot,
      );

      testWidgets("is loading while the event's read runs, not hidden, and "
          'reads the pool once that brings the roster', (tester) async {
        heldRead = Completer<EventSnapshot>();
        await show(tester, detail: unread);

        await chooseGames(tester);

        expect(find.text("The games aren't shown to you"), findsNothing);
        expect(find.byType(BgeLoadingState), findsOneWidget);
        expect(remote.poolRequests, isEmpty);

        // The read writes the roster to the cache, then ends.
        cache.add(detailOf());
        await settle(tester);
        heldRead!.complete(detailOf().snapshot);
        heldRead = null;
        await animate(tester);
        await animate(tester);

        expect(poolReads(), hasLength(1));
        expect(poolReads().single.$2, ['att-me', 'att-ada', 'att-bo']);
        expect(row(azul.id), findsOneWidget);
      });

      testWidgets("once the event's read has failed, says it couldn't load "
          'the games, and Try again reads the event', (tester) async {
        heldRead = Completer<EventSnapshot>();
        await show(tester, detail: unread);
        heldRead!.completeError(_offline);
        heldRead = null;
        await settle(tester);
        final reads = remote.detailRequests.length;

        await chooseGames(tester);

        expect(find.text("The games aren't shown to you"), findsNothing);
        expect(find.text("Couldn't load the games"), findsOneWidget);
        expect(remote.poolRequests, isEmpty);

        heldRead = Completer<EventSnapshot>();
        await tester.tap(find.byKey(EventDetailScreen.poolRetryKey));
        await settle(tester);

        // The event, not the pool, which has no one to read for.
        expect(remote.detailRequests, hasLength(reads + 1));
        expect(remote.poolRequests, isEmpty);
        expect(find.byType(BgeLoadingState), findsOneWidget);

        cache.add(detailOf());
        await settle(tester);
        heldRead!.complete(detailOf().snapshot);
        heldRead = null;
        await animate(tester);
        await animate(tester);

        expect(poolReads(), hasLength(1));
        expect(row(azul.id), findsOneWidget);
      });
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
        'clears the search and the people and hands focus to People, with '
        'no keyboard left open', (tester) async {
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
      expect(searchFocus(tester).hasFocus, isFalse);
      expect(peopleFocus(tester).hasPrimaryFocus, isTrue);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    group('Clear filters hands focus to People', () {
      final clearFilters = find.byKey(EventDetailScreen.poolClearFiltersKey);

      /// "Not mine" on, and a search for a game only the viewer brings:
      /// nothing matches.
      Future<void> noneMatch(WidgetTester tester) async {
        await showGames(tester);
        await tester.tap(notMine());
        await tester.pump();
        await tester.enterText(search(), 'wingspan');
        await animate(tester);
        expect(clearFilters, findsOneWidget);
      }

      testWidgets('from the keyboard', (tester) async {
        await noneMatch(tester);

        await activateByKeyboard(tester, clearFilters);
        await animate(tester);

        expect(clearFilters, findsNothing);
        expect(peopleFocus(tester).hasPrimaryFocus, isTrue);
      });

      testWidgets("from a screen reader's activation, with focus on nothing", (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await noneMatch(tester);
        await focusNothing(tester);

        screenReaderTap(tester, 'Clear filters');
        await animate(tester);

        expect(clearFilters, findsNothing);
        expect(peopleFocus(tester).hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets('a pointer press while focus sits on another control '
          'moves nothing', (tester) async {
        await noneMatch(tester);
        final notMineFocus = Focus.of(
          tester.element(
            find.descendant(of: notMine(), matching: find.text('Not mine')),
          ),
        )..requestFocus();
        await tester.pump();
        expect(notMineFocus.hasPrimaryFocus, isTrue);

        await tester.tap(clearFilters);
        await animate(tester);

        expect(clearFilters, findsNothing);
        expect(notMineFocus.hasPrimaryFocus, isTrue);
        expect(peopleFocus(tester).hasFocus, isFalse);
      });
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
      final again = Completer<List<OfferedGame>>();
      var answered = 0;
      poolAnswer = (_) => answered++ == 0
          ? throw const EventRemoteNotFoundException('gone', statusCode: 404)
          : again.future;
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
      again.complete(served);
      await animate(tester);
    });

    testWidgets('a pool still not found once the event reads fine says it '
        "couldn't load the games, and Try again reads twice and stops", (
      tester,
    ) async {
      // As a server without the pool's routes answers.
      poolAnswer = (_) =>
          throw const EventRemoteNotFoundException('gone', statusCode: 404);
      await show(tester);
      final reads = remote.detailRequests.length;

      await chooseGames(tester);
      await animate(tester);

      expect(remote.detailRequests, hasLength(reads + 1));
      expect(remote.poolRequests, hasLength(2));
      expect(find.byType(BgeLoadingState), findsNothing);
      expect(find.text("Couldn't load the games"), findsOneWidget);
      expect(find.byKey(EventDetailScreen.poolRetryKey), findsOneWidget);
      // The header is back above it.
      expect(search(), findsOneWidget);
      expect(scrollView(tester).semanticChildCount, 0);

      await tester.tap(find.byKey(EventDetailScreen.poolRetryKey));
      await animate(tester);
      await animate(tester);

      // Gone, the event read again, then failed: and no more.
      expect(remote.poolRequests, hasLength(4));
      expect(remote.detailRequests, hasLength(reads + 2));
      expect(find.text("Couldn't load the games"), findsOneWidget);
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

    testWidgets("leaving out someone the roster doesn't name says \"Not this "
        'person", mid-phrase', (tester) async {
      served = [catanMine, _game('o-9', 'att-nn', 'Azul')];
      await showGames(tester, detail: detailOf(roster: [me, _row('att-nn')]));
      await tester.tap(people());
      await animate(tester);
      await tester.tap(find.byKey(EventDetailScreen.poolPersonKey('att-nn')));
      await tester.pump();
      await tester.tap(find.byKey(EventDetailScreen.poolLeaveOutKey));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);

      expect(
        find.descendant(
          of: inUse('att-nn'),
          matching: find.text('Not this person'),
        ),
        findsOneWidget,
      );
      expect(find.text('Not This person'), findsNothing);
      // Chosen and kept, the chip names them as a list does.
      await tester.tap(people());
      await animate(tester);
      await tester.tap(find.byKey(EventDetailScreen.poolLeaveOutKey));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);
      expect(
        find.descendant(
          of: inUse('att-nn'),
          matching: find.text('This person'),
        ),
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
      // Catan's row leaves with the outcome, though the read after it
      // failed.
      expect(row(catanMine.id), findsNothing);
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

    testWidgets('Take back sends nothing, and says nothing, if an offer run '
        'started while a read was running', (tester) async {
      final send = Completer<void>();
      offerAnswer = (request) async {
        await send.future;
        return _game('o-new', request.attendeeId, request.collectionId);
      };
      await showGames(tester);
      final detail = blocOf<EventDetailBloc>(tester);
      final pool = blocOf<EventGamesBloc>(tester);
      heldRead = Completer<EventSnapshot>();

      // A read starts, and the press lands before a frame shows it.
      detail.add(const EventDetailRetryRequested());
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      expect((detail.state as EventDetailReady).reading, isTrue);
      await tester.tap(takeBack(catanMine.id));

      // Meanwhile an offer run goes out, and holds the one write.
      pool.add(
        const EventGamesOffered(
          'e-1',
          'att-me',
          [OfferPick(collectionId: 'c-new', title: 'New')],
          attendeeIds: ['att-me', 'att-ada', 'att-bo'],
        ),
      );
      await settle(tester);
      expect(pool.state.busy, isTrue);
      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await settle(tester);

      // The run's own outcome will say what happened; the press adds none.
      expect(remote.takeBacks, isEmpty);
      expect(pool.state.outcome, isNull);

      send.complete();
      await animate(tester);
      expect(remote.takeBacks, isEmpty);
      expect(pool.state.outcome, isA<EventOfferOutcome>());
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
        // Held, so the user moves focus while it is out: the row leaves as
        // it ends.
        final answer = Completer<void>();
        takeBackAnswer = (_) => answer.future;
        served = [azul, catanAdas, root];
        takeBackFocus(tester, catanMine.id).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);

        searchFocus(tester).requestFocus();
        await tester.pump();
        answer.complete();
        await animate(tester);

        expect(row(catanMine.id), findsNothing);
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

      // The row leaves with the take-back's done outcome, so what the read
      // after it does can't keep the hand-off from running.
      testWidgets("to the next row's, by pointer with focus on nothing, when "
          'the take-back is done and the read after it fails', (tester) async {
        served = [catanMine, azul, wingspanMine];
        await showGames(tester);
        poolAnswer = (_) => throw _offline;
        await focusNothing(tester);
        await tester.tap(takeBack(catanMine.id));
        await animate(tester);
        await animate(tester);

        expect(
          find.descendant(
            of: outcome(),
            matching: find.text('Catan is off your games.'),
          ),
          findsOneWidget,
        );
        expect(stale(), findsOneWidget);
        expect(row(catanMine.id), findsNothing);
        expect(takeBackFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
      });

      testWidgets("to the next row's, by pointer with focus on nothing, when "
          'the take-back is done over a failed read and the session stops '
          'the read after it', (tester) async {
        served = [catanMine, azul, wingspanMine];
        await showGames(tester, guarded: true);
        // A read that fails: the rows stay, under the stale banner.
        poolAnswer = (_) => throw _offline;
        blocOf<EventGamesBloc>(tester).add(
          const EventGamesRequested('e-1', ['att-me', 'att-ada', 'att-bo']),
        );
        await animate(tester);
        expect(stale(), findsOneWidget);
        await focusNothing(tester);

        // The take-back goes, and the read after it is stopped by the
        // session check.
        sessionAnswers.addAll([true, false]);
        await tester.tap(takeBack(catanMine.id));
        await animate(tester);
        await animate(tester);

        expect(remote.takeBacks, hasLength(1));
        expect(sessionAnswers, isEmpty);
        expect(row(catanMine.id), findsNothing);
        expect(takeBackFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
      });

      testWidgets("to the next row's, by a screen reader's activation, when "
          'the take-back is done over a failed read and the read after it '
          'takes the row away', (tester) async {
        final handle = tester.ensureSemantics();
        served = [catanMine, azul, wingspanMine];
        await showGames(tester);
        poolAnswer = (_) => throw _offline;
        blocOf<EventGamesBloc>(tester).add(
          const EventGamesRequested('e-1', ['att-me', 'att-ada', 'att-bo']),
        );
        await animate(tester);
        expect(stale(), findsOneWidget);
        served = [azul, wingspanMine];
        poolAnswer = (_) => served;
        await focusNothing(tester);

        screenReaderTap(tester, 'Take back Catan');
        await animate(tester);
        await animate(tester);

        expect(row(catanMine.id), findsNothing);
        expect(takeBackFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets("from the last of the viewer's rows, by a screen reader's "
          'activation with focus on nothing, to Offer games', (tester) async {
        final handle = tester.ensureSemantics();
        served = [catanMine, azul];
        await showGames(tester);
        served = [azul];
        await focusNothing(tester);

        screenReaderTap(tester, 'Take back Catan');
        await animate(tester);
        await animate(tester);

        expect(row(catanMine.id), findsNothing);
        expect(
          tester
              .widget<ButtonStyleButton>(offerGames())
              .focusNode!
              .hasPrimaryFocus,
          isTrue,
        );
        handle.dispose();
      });

      testWidgets("from the last of the viewer's rows, by a screen reader's "
          'activation with focus on nothing, to the search field with no '
          'Offer games', (tester) async {
        final handle = tester.ensureSemantics();
        served = [catanMine, azul];
        await showGames(tester, offers: false);
        served = [azul];
        await focusNothing(tester);

        screenReaderTap(tester, 'Take back Catan');
        await animate(tester);
        await animate(tester);

        expect(row(catanMine.id), findsNothing);
        expect(offerGames(), findsNothing);
        expect(searchFocus(tester).hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets('on, from a focused Take back whose row a read of the pool '
          'takes away, with no press of its own', (tester) async {
        served = [catanMine, azul, wingspanMine];
        await showGames(tester);
        takeBackFocus(tester, catanMine.id).requestFocus();
        await tester.pump();

        // Taken back from another device: the next read of the pool, which
        // holds no control back, comes without it.
        served = [azul, wingspanMine];
        blocOf<EventGamesBloc>(tester).add(
          const EventGamesRequested('e-1', ['att-me', 'att-ada', 'att-bo']),
        );
        await animate(tester);

        expect(remote.takeBacks, isEmpty);
        expect(row(catanMine.id), findsNothing);
        expect(takeBackFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
      });

      testWidgets("by pointer on one row while keyboard focus is on another's "
          'Take back: that one is disabled for the write, drops focus, and '
          'takes it back once the pressed row has gone', (tester) async {
        served = [catanMine, azul, wingspanMine];
        await showGames(tester);
        final held = Completer<void>();
        takeBackAnswer = (_) => held.future;
        final catan = takeBackFocus(tester, catanMine.id)..requestFocus();
        await tester.pump();

        await tester.ensureVisible(takeBack(wingspanMine.id));
        await tester.pump();
        await tester.tap(takeBack(wingspanMine.id));
        await settle(tester);

        // One write at a time: Catan's Take back is disabled while
        // Wingspan's is out, and a disabled button holds no focus.
        expect(remote.takeBacks, hasLength(1));
        expect(
          tester.widget<ButtonStyleButton>(takeBack(catanMine.id)).onPressed,
          isNull,
        );
        expect(catan.hasFocus, isFalse);
        expect(
          FocusManager.instance.primaryFocus,
          anyOf(isNull, isA<FocusScopeNode>()),
        );

        // Wingspan's row goes, and focus, free, goes to the one before it.
        served = [catanMine, azul];
        held.complete();
        await animate(tester);
        await animate(tester);

        expect(row(wingspanMine.id), findsNothing);
        expect(takeBackFocus(tester, catanMine.id).hasPrimaryFocus, isTrue);
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

    testWidgets("Offer games opens the page with the viewer's offered ids", (
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

  group('offering', () {
    const picks = [
      OfferPick(collectionId: 'c-azul', title: 'Azul'),
      OfferPick(collectionId: 'c-root', title: 'Root'),
    ];
    const roster = ['att-me', 'att-ada', 'att-bo'];

    Finder progress() => find.byKey(EventDetailScreen.poolProgressKey);

    /// The footer's outcome says [copy].
    void expectOutcome(String copy) {
      expect(
        find.descendant(of: outcome(), matching: find.text(copy)),
        findsOneWidget,
      );
    }

    /// Presses Offer games, and lets what the page answers with go.
    Future<void> offer(WidgetTester tester) async {
      await tester.ensureVisible(offerGames());
      await tester.pump();
      await tester.tap(offerGames());
      await animate(tester);
      await animate(tester);
    }

    testWidgets("the picks are sent with the viewer's attendee id", (
      tester,
    ) async {
      pageAnswer = (_) async => picks;
      await showGames(tester);
      final reads = remote.poolRequests.length;

      await offer(tester);

      expect(remote.offers, [
        (eventId: 'e-1', attendeeId: 'att-me', collectionId: 'c-azul'),
        (eventId: 'e-1', attendeeId: 'att-me', collectionId: 'c-root'),
      ]);
      expectOutcome('2 games offered.');
      expectInFooter(tester, outcome());
      // The pool is read again once the run ends, for the roster.
      expect(remote.poolRequests, hasLength(reads + 1));
      expect(poolReads().last.$1, 'e-1');
      expect(poolReads().last.$2, roster);
    });

    testWidgets('no picks, or Back, send nothing and say nothing', (
      tester,
    ) async {
      await showGames(tester);

      await offer(tester);
      pageAnswer = (_) async => const [];
      await offer(tester);

      expect(offerArgs, hasLength(2));
      expect(remote.offers, isEmpty);
      expect(outcome(), findsNothing);
      expect(progress(), findsNothing);
    });

    testWidgets('progress shows in the footer while they go', (tester) async {
      final answers = [Completer<void>(), Completer<void>()];
      var sent = 0;
      offerAnswer = (request) async {
        await answers[sent++].future;
        return _game('o-new', request.attendeeId, 'x');
      };
      pageAnswer = (_) async => picks;
      await showGames(tester);

      await offer(tester);

      expectInFooter(tester, progress());
      expect(
        find.descendant(
          of: progress(),
          matching: find.text('Offering 0 of 2…'),
        ),
        findsOneWidget,
      );
      expect(outcome(), findsNothing);

      answers[0].complete();
      await settle(tester);
      expect(
        find.descendant(
          of: progress(),
          matching: find.text('Offering 1 of 2…'),
        ),
        findsOneWidget,
      );

      answers[1].complete();
      await animate(tester);
      // The outcome takes its place.
      expect(progress(), findsNothing);
      expectOutcome('2 games offered.');
    });

    testWidgets('the progress line and the outcome stay in the footer on '
        'Details; the stale-data banner does not', (tester) async {
      final answers = [Completer<void>(), Completer<void>()];
      var sent = 0;
      offerAnswer = (request) async {
        await answers[sent++].future;
        return _game('o-new', request.attendeeId, 'x');
      };
      pageAnswer = (_) async => picks;
      await showGames(tester);
      await offer(tester);

      // A run of forty can outlast the stay on Games.
      Future<void> choose(EventDetailTab which) async {
        await tester.ensureVisible(
          find.byKey(EventDetailScreen.tabKey(which), skipOffstage: false),
        );
        await tester.pump();
        await tester.tap(tab(which));
        await animate(tester);
      }

      await choose(EventDetailTab.details);
      expectInFooter(tester, progress());

      answers[0].complete();
      await settle(tester);
      expect(
        find.descendant(
          of: progress(),
          matching: find.text('Offering 1 of 2…'),
        ),
        findsOneWidget,
      );

      // The read after the run fails, over the games shown.
      poolAnswer = (_) => throw _offline;
      answers[1].complete();
      await animate(tester);

      expect(progress(), findsNothing);
      expectInFooter(tester, outcome());
      expectOutcome('2 games offered.');
      expect(stale(), findsNothing);

      await choose(EventDetailTab.games);
      expectInFooter(tester, outcome());
      expectInFooter(tester, stale());
    });

    testWidgets('the progress line is one live region, which says a step at '
        'most every two seconds, and the latest', (tester) async {
      final handle = tester.ensureSemantics();
      final answers = [for (var n = 0; n < 6; n++) Completer<void>()];
      var sent = 0;
      offerAnswer = (request) async {
        await answers[sent++].future;
        return _game('o-new-$sent', request.attendeeId, 'x');
      };
      pageAnswer = (_) async => [
        for (var n = 0; n < 6; n++)
          OfferPick(collectionId: 'c-$n', title: 'Game $n'),
      ];
      await showGames(tester);
      await offer(tester);

      SemanticsNode line() => tester.getSemantics(progress());
      final id = line().id;
      expect(
        line(),
        isSemantics(label: 'Offering 0 of 6…', isLiveRegion: true),
      );

      // The first answer, more than two seconds on: said at once.
      answers[0].complete();
      await settle(tester);
      expect(line().label, 'Offering 1 of 6…');

      // Two more in quick succession: drawn at once, said once the two
      // seconds since the last are up, as the latest.
      for (var n = 1; n < 3; n++) {
        answers[n].complete();
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(
        find.descendant(
          of: progress(),
          matching: find.text('Offering 3 of 6…'),
        ),
        findsOneWidget,
      );
      expect(line().label, 'Offering 1 of 6…');
      await tester.pump(const Duration(seconds: 2));
      expect(
        line(),
        isSemantics(label: 'Offering 3 of 6…', isLiveRegion: true),
      );
      expect(line().id, id);

      // One more, after a pause: said at once.
      await tester.pump(const Duration(seconds: 2));
      answers[3].complete();
      await settle(tester);
      expect(line().label, 'Offering 4 of 6…');
      expect(line().id, id);

      answers[4].complete();
      answers[5].complete();
      await animate(tester);
      expect(progress(), findsNothing);
      expectOutcome('6 games offered.');
      handle.dispose();
    });

    testWidgets("picks aren't sent if the viewer answered Not going "
        'meanwhile', (tester) async {
      final page = Completer<List<OfferPick>?>();
      pageAnswer = (_) => page.future;
      await showGames(tester);
      await offer(tester);

      // While the page is open, a sync brings the viewer's Not going.
      cache.add(
        detailOf(
          viewer: _row(
            'att-me',
            name: 'Me',
            status: EventParticipationStatus.notAttending,
          ),
        ),
      );
      await settle(tester);
      page.complete(picks);
      await animate(tester);

      expect(remote.offers, isEmpty);
      expectOutcome(
        "Those games weren't offered: the event changed while you were "
        'choosing.',
      );
    });

    testWidgets('the picks wait for a detail read running as the page closes, '
        'and go for the event as it is then', (tester) async {
      final page = Completer<List<OfferPick>?>();
      pageAnswer = (_) => page.future;
      await showGames(tester);
      await offer(tester);

      heldRead = Completer<EventSnapshot>();
      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      page.complete(picks);
      await animate(tester);
      expect(remote.offers, isEmpty);

      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);
      await animate(tester);

      expect(remote.offers, hasLength(2));
      expectOutcome('2 games offered.');
    });

    group('each end of a run says how it went', () {
      const conflict = EventWriteConflictException('gone', statusCode: 400);
      const refused = EventWriteRefusedException('no', statusCode: 403);
      final rows = [
        (
          name: 'done',
          answers: <EventRemoteException?>[null, null],
          copy: '2 games offered.',
        ),
        (
          name: 'partly',
          answers: <EventRemoteException?>[null, conflict],
          copy: "1 game offered. 1 couldn't be offered.",
        ),
        (
          name: 'none',
          answers: <EventRemoteException?>[conflict, conflict],
          copy: 'None of those 2 games could be offered.',
        ),
        (
          name: 'refused, with some offered',
          answers: <EventRemoteException?>[null, refused],
          copy: "1 game offered. 1 couldn't be offered.",
        ),
        (
          name: 'refused, with none offered',
          answers: <EventRemoteException?>[refused],
          copy: "You can't offer games to this event any more.",
        ),
        (
          name: 'failed, with some offered',
          answers: <EventRemoteException?>[null, _offline],
          copy: "1 game offered. 1 couldn't be offered.",
        ),
        (
          name: 'failed, with none offered',
          answers: <EventRemoteException?>[_offline],
          copy: 'None of those 2 games could be offered.',
        ),
      ];

      for (final (:name, :answers, :copy) in rows) {
        testWidgets('$name: "$copy"', (tester) async {
          var sent = 0;
          offerAnswer = (request) {
            final thrown = answers[sent++];
            if (thrown != null) throw thrown;
            return _game('o-new-$sent', request.attendeeId, 'x');
          };
          pageAnswer = (_) async => picks;
          await showGames(tester);

          await offer(tester);

          expectOutcome(copy);
          expectInFooter(tester, outcome());
        });
      }

      testWidgets("none, of one: \"That game couldn't be offered.\"", (
        tester,
      ) async {
        offerAnswer = (_) => throw conflict;
        pageAnswer = (_) async => [picks.first];
        await showGames(tester);

        await offer(tester);

        expectOutcome("That game couldn't be offered.");
      });

      testWidgets('dropped: "Those games weren\'t offered: the event changed '
          'while you were choosing."', (tester) async {
        await showGames(tester);

        blocOf<EventGamesBloc>(tester).add(
          const EventGamesWriteDropped(EventGamesWrite.offer),
        );
        await settle(tester);

        expectOutcome(
          "Those games weren't offered: the event changed while you were "
          'choosing.',
        );
      });
    });

    testWidgets('the stale banner keeps its place after the progress line', (
      tester,
    ) async {
      final held = Completer<void>();
      offerAnswer = (request) async {
        await held.future;
        return _game('o-new', request.attendeeId, 'x');
      };
      pageAnswer = (_) async => picks;
      await showGames(tester);
      poolAnswer = (_) => throw _offline;
      blocOf<EventGamesBloc>(tester).add(
        const EventGamesRequested('e-1', roster),
      );
      await animate(tester);
      expectInFooter(tester, stale());

      await offer(tester);

      expectInFooter(tester, progress());
      expectInFooter(tester, stale());
      expect(
        tester.getRect(progress()).top,
        lessThan(tester.getRect(stale()).top),
      );
      held.complete();
      await animate(tester);
    });

    testWidgets('Offer games lets its press go once its run and the read '
        'after it have ended: a detail read running then disables it, and '
        "it doesn't say it is offering", (tester) async {
      final last = Completer<void>();
      var sent = 0;
      offerAnswer = (request) async {
        if (sent++ == 1) await last.future;
        return _game('o-new-$sent', request.attendeeId, 'x');
      };
      pageAnswer = (_) async => picks;
      await showGames(tester);
      await offer(tester);
      expect(
        find.descendant(of: offerGames(), matching: find.text('Offering…')),
        findsOneWidget,
      );

      // A detail read starts while the run is out, and is still running as
      // the run, and the pool read after it, end.
      heldRead = Completer<EventSnapshot>();
      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      last.complete();
      await animate(tester);

      expectOutcome('2 games offered.');
      expect(
        find.descendant(of: offerGames(), matching: find.text('Offer games')),
        findsOneWidget,
      );
      expect(tester.widget<ButtonStyleButton>(offerGames()).onPressed, isNull);

      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);
      expect(
        tester.widget<ButtonStyleButton>(offerGames()).onPressed,
        isNotNull,
      );
    });

    testWidgets('Offer games is available through the read of the pool after '
        'its run, as the tab is through any read of the pool, and a press '
        'then opens the page', (tester) async {
      pageAnswer = (_) async => picks;
      await showGames(tester);
      final read = Completer<List<OfferedGame>>();
      poolAnswer = (_) => read.future;

      await offer(tester);

      // The run is over; the read after it is out.
      expectOutcome('2 games offered.');
      expect(remote.poolRequests.length, greaterThan(1));
      expect(
        find.descendant(of: offerGames(), matching: find.text('Offer games')),
        findsOneWidget,
      );
      expect(
        tester.widget<ButtonStyleButton>(offerGames()).onPressed,
        isNotNull,
      );
      // So are the Take backs.
      expect(
        tester.widget<ButtonStyleButton>(takeBack(catanMine.id)).onPressed,
        isNotNull,
      );

      pageAnswer = (_) async => null;
      await tester.tap(offerGames());
      await animate(tester);

      expect(offerArgs, hasLength(2));
      read.complete(served);
      await animate(tester);
    });

    testWidgets('the stale banner keeps its place after the outcome', (
      tester,
    ) async {
      pageAnswer = (_) async => picks;
      await showGames(tester);
      poolAnswer = (_) => throw _offline;

      await offer(tester);

      expectOutcome('2 games offered.');
      expectInFooter(tester, outcome());
      expectInFooter(tester, stale());
      expect(
        tester.getRect(outcome()).top,
        lessThan(tester.getRect(stale()).top),
      );
    });

    testWidgets('focus is on Offer games after the page closes, and stays '
        'there through the run', (tester) async {
      final handle = tester.ensureSemantics();
      final held = Completer<void>();
      offerAnswer = (request) async {
        await held.future;
        return _game('o-new', request.attendeeId, 'x');
      };
      // A page of its own, which pops with the picks.
      pageAnswer = (context) => Navigator.of(context).push<List<OfferPick>>(
        MaterialPageRoute(
          builder: (page) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(page).pop(picks),
              child: const Text('Send them'),
            ),
          ),
        ),
      );
      await showGames(tester);
      final focus = tester.widget<ButtonStyleButton>(offerGames()).focusNode!
        ..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Send them'), findsOneWidget);

      await tester.tap(find.text('Send them'));
      // Fixed pumps: the held button's spinner never settles.
      await animate(tester);
      await animate(tester);

      // Back on the tab, with the run out.
      expect(find.text('Send them'), findsNothing);
      expect(remote.offers, hasLength(1));
      expect(focus.hasPrimaryFocus, isTrue);
      expect(
        find.descendant(of: offerGames(), matching: find.text('Offering…')),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(offerGames()),
        isSemantics(label: 'Offering…', isEnabled: false, isFocused: true),
      );
      // A press meanwhile opens nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(offerArgs, hasLength(1));

      held.complete();
      await animate(tester);
      await animate(tester);

      expect(remote.offers, hasLength(2));
      expect(focus.hasPrimaryFocus, isTrue);
      expect(
        find.descendant(of: offerGames(), matching: find.text('Offer games')),
        findsOneWidget,
      );
      expect(
        tester.widget<ButtonStyleButton>(offerGames()).onPressed,
        isNotNull,
      );
      expectOutcome('2 games offered.');
      handle.dispose();
    });

    testWidgets("is disabled, not held, while another control's take-back is "
        'out', (tester) async {
      final held = Completer<void>();
      takeBackAnswer = (_) => held.future;
      await showGames(tester);

      await tester.tap(takeBack(catanMine.id));
      await settle(tester);

      expect(tester.widget<ButtonStyleButton>(offerGames()).onPressed, isNull);
      expect(
        find.descendant(of: offerGames(), matching: find.text('Offer games')),
        findsOneWidget,
      );
      held.complete();
      await animate(tester);
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
