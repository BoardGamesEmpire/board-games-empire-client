import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_filters/game_filters.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';
import '../support/fake_event_remote.dart';
import '../support/kept_nominations.dart';

class _MockEventRepository extends Mock implements EventRepository {}

const _onlineOnlyCopy = "Available when you're online";
const _offline = EventRemoteTransientException('offline');
const _stillSuppliesCopy =
    'Catan is nominated, or in the lineup for a date still to come, so it '
    "can't come off your games yet.";
const _stillSuppliesYoursCopy =
    "Catan is nominated, so it can't come off your games yet. Withdraw your "
    'nomination first.';
const _stillSuppliesTheirsCopy =
    "Catan is nominated, so it can't come off your games yet. Only whoever "
    'nominated it can withdraw it.';
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
  String? subtitle,
  String platform = 'Tabletop',
  PlatformType? platformType,
  GameMedium? medium = GameMedium.physical,
}) => OfferedGame(
  id: id,
  attendeeId: attendeeId,
  collectionId: 'col-$id',
  platformGameId: 'pg-$id',
  gameId: 'g-$id',
  title: title,
  subtitle: subtitle,
  platformName: platform,
  platformType: platformType,
  medium: medium,
);

/// A batch offer's answer that offers every entry of [request], each as a
/// game of its own.
List<GameOfferResult> _offeredAll(OfferGamesRequest request) => [
  for (final id in request.collectionIds)
    GameOfferResult.offered(
      collectionId: id,
      alreadyOffered: false,
    ),
];

/// A batch offer's answer that refuses every entry of [request].
List<GameOfferResult> _refusedAll(OfferGamesRequest request) => [
  for (final id in request.collectionIds)
    GameOfferResult.refused(
      collectionId: id,
      reason: GameOfferRefusal.removedFromCollection,
      message: 'No longer in the collection',
    ),
];

/// The Games tab of an event's screen (#516): when the pool is read, what
/// it shows in each state, its rows, the filter and the people sheet, Take
/// back and its outcomes in the page's footer, Take back on someone else's
/// row and the dialog it asks with (#518), the Offer games button, and each
/// row's Nominate and "Nominated" marker (#517).
void main() {
  // Local, as the device's clock reads it.
  final now = DateTime(2026, 10, 23, 18);

  /// What the screen's clock reads: [now], unless a test moves it on.
  late DateTime clock;

  late _MockEventRepository repository;
  late StreamController<EventDetail?> cache;

  /// What each pool read answers, unless a test sets [poolAnswer].
  late List<OfferedGame> served;
  late FutureOr<List<OfferedGame>> Function(GamesPoolRequest request)
  poolAnswer;
  late FutureOr<void> Function(TakeBackGameRequest request) takeBackAnswer;

  /// What each batch offer answers: every entry it sent offered, unless a
  /// test says otherwise.
  late FutureOr<List<GameOfferResult>> Function(OfferGamesRequest request)
  offerAnswer;

  /// What the Offer games page answers with, once opened.
  late Future<List<OfferPick>?> Function(BuildContext context) pageAnswer;

  /// What each nominations read answers (#517): none, unless a test says
  /// otherwise, so the section above the pool says nothing is nominated.
  late FutureOr<List<EventNomination>> Function(String eventId)
  nominationsAnswer;

  /// What each nominate answers (#517): the nomination as the server holds
  /// it, open for votes, unless a test says otherwise.
  late FutureOr<EventNomination> Function(NominateRequest request)
  nominateAnswer;

  /// What each withdrawal answers (#517): the nomination, withdrawn, as the
  /// last nominations read served it.
  late FutureOr<EventNomination> Function(WithdrawRequest request)
  withdrawAnswer;

  /// A detail read held until a test completes it, while set.
  Completer<EventSnapshot>? heldRead;
  late FakeEventRemote remote;

  /// What the fake server answered writes and single reads with, which its
  /// list reads serve.
  final kept = KeptNominations();

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
  /// it, with [roster] on it. [occurrences] replace its one date, and
  /// [policy] is its rules, none by default. With [attending] false the
  /// viewer has no row of their own, as a household owner or admin who
  /// doesn't attend their household's event ([householdId]) has none.
  EventDetail detailOf({
    EventAttendee? viewer,
    List<EventAttendee>? roster,
    bool rosterGiven = true,
    bool attending = true,
    String? householdId,
    EventStatus status = EventStatus.scheduled,
    List<EventOccurrence>? occurrences,
    EventPolicy? policy,
  }) {
    final self = viewer ?? me;
    return EventDetail(
      snapshot: EventSnapshot(
        event: item(
          'e-1',
          title: 'Catan night',
          householdId: householdId,
        ).event.copyWith(status: status),
        occurrences:
            occurrences ??
            [
              confirmed(
                'o-1',
                DateTime(2026, 11, 6, 19),
              ).copyWith(eventId: 'e-1'),
            ],
        attendees: rosterGiven ? (roster ?? [self, ada, bo]) : null,
        policy: policy,
      ),
      attendance: attending ? self : null,
    );
  }

  setUpAll(() {
    registerFallbackValue(detailOf().snapshot);
    registerFallbackValue(EventAccessSource.read);
  });

  setUp(() {
    clock = now;
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
    offerAnswer = _offeredAll;
    pageAnswer = (_) async => null;
    nominationsAnswer = (_) => const [];
    nominateAnswer = (request) => EventNomination(
      id: 'n-${request.suppliedFromId}',
      eventId: request.eventId,
      platformGameId: request.platformGameId,
      gameId: 'g-${request.suppliedFromId}',
      title: served
          .firstWhere((game) => game.id == request.suppliedFromId)
          .title,
      platformName: 'Tabletop',
      status: NominationStatus.open,
      nominatedById: 'att-me',
      suppliedFromId: request.suppliedFromId,
      occurrenceId: request.occurrenceId,
      createdAt: kItemInstant,
    );
    withdrawAnswer = (request) async {
      final read = await nominationsAnswer(request.eventId);
      return read
          .firstWhere((each) => each.id == request.nominationId)
          .copyWith(status: NominationStatus.withdrawn);
    };
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
    Future<HouseholdRole?> Function(String householdId)? householdRole,
  }) {
    remote = FakeEventRemote.detail(
      (_) => heldRead?.future ?? detail.snapshot,
      pool: (request) => poolAnswer(request),
      offeredBatch: (request) => offerAnswer(request),
      takenBack: (request) => takeBackAnswer(request),
      nominations: (eventId) async =>
          kept.over(await nominationsAnswer(eventId)),
      nominated: (request) async => kept.keep(await nominateAnswer(request)),
      withdrawn: (request) async => kept.keep(await withdrawAnswer(request)),
    );
    addTearDown(kept.clear);
    return MaterialApp(
      theme: theme ?? BgeTheme.light(),
      locale: const Locale('en', 'US'),
      localizationsDelegates: const [
        ...EventsLocalizations.localizationsDelegates,
        // The pool's Filters, its sheet and its chips (#851).
        GameFiltersLocalizations.delegate,
      ],
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
        session: FakeSessionLease(),
        remote: remote,
        confirmSession: guarded ? confirmSession : null,
        householdRole: householdRole,
        onBack: (_) {},
        onOfferGames: offers ? recordOffer : null,
        now: () => clock,
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
  /// every open makes ended. [householdRole] answers the viewer's role in
  /// the event's household, where it has one.
  Future<void> show(
    WidgetTester tester, {
    EventDetail? detail,
    ValueListenable<bool>? offline,
    bool offers = true,
    bool guarded = false,
    Future<HouseholdRole?> Function(String householdId)? householdRole,
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
        householdRole: householdRole,
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
    Future<HouseholdRole?> Function(String householdId)? householdRole,
  }) async {
    await show(
      tester,
      detail: detail,
      offline: offline,
      offers: offers,
      guarded: guarded,
      householdRole: householdRole,
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
  List<(String, List<String>?)> poolReads() => [
    for (final (:eventId, :attendeeIds) in remote.poolRequests)
      (eventId, attendeeIds),
  ];
  Finder outcome() => find.byKey(EventDetailScreen.poolOutcomeKey);
  // Above the rows: a press on a row can scroll it out of view, built all
  // the same.
  Finder offerGames() =>
      find.byKey(EventDetailScreen.offerGamesKey, skipOffstage: false);
  Finder search() => find.byKey(EventDetailScreen.poolSearchKey);
  Finder people() => find.byKey(EventDetailScreen.poolPeopleKey);
  Finder notMine() => find.byKey(EventDetailScreen.poolNotMineKey);
  Finder inUse(String attendeeId) =>
      find.byKey(EventDetailScreen.poolInUseKey(attendeeId));

  /// The footer's stale-data banner.
  Finder stale() => find.byKey(EventDetailScreen.poolRefreshBannerKey);

  /// The pool's spinner, not the Nominations section's above it (#517).
  Finder poolSpinner() => find.byWidgetPredicate(
    (widget) =>
        widget is BgeLoadingState && widget.label == 'Loading the games',
    description: "the pool's spinner",
  );

  /// The pool's empty states, not the Nominations section's (#517).
  Finder poolEmptyState() => find.byWidgetPredicate(
    (widget) =>
        widget is BgeEmptyState && widget.title != 'Nothing nominated yet',
    description: "the pool's empty states",
  );

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

  /// Brings [finder] on screen, then taps it: the Nominations section above
  /// the pool (#517) can leave what a test presses below the fold.
  Future<void> press(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
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
      // Everyone's games, with no ids, where the roster is read (#851).
      expect(poolReads().single.$2, isNull);
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
      expect(poolSpinner(), findsOneWidget);

      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);
      await animate(tester);

      expect(poolReads(), hasLength(1));
      expect(poolReads().single.$1, 'e-1');
      expect(poolReads().single.$2, isNull);
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
        expect(poolSpinner(), findsOneWidget);
        expect(find.text("Couldn't load the games"), findsNothing);

        cache.add(detailOf());
        await animate(tester);
        await animate(tester);

        expect(poolReads(), hasLength(1));
        expect(poolReads().single.$2, isNull);
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

        // The roster says when to read again, and the read is everyone's.
        expect(remote.poolRequests, hasLength(3));
        expect(poolReads().last.$2, isNull);
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

      // The read names nobody where the roster is read, so the order of its
      // rows changes nothing it reads (#851).
      testWidgets('the same roster in another order is not read for again', (
        tester,
      ) async {
        await showGames(tester);
        expect(remote.poolRequests, hasLength(1));

        cache.add(detailOf(roster: [bo, ada, me]));
        await animate(tester);

        expect(remote.poolRequests, hasLength(1));
      });

      // A roster of the viewer alone reads the whole event, and one
      // withheld reads the viewer's own games: the same ids, read for
      // differently, so the games read for the one aren't the other's.
      testWidgets("the viewer's roster withheld is read for again, for their "
          'own games', (tester) async {
        await showGames(tester, detail: detailOf(roster: [me]));
        expect(poolReads().single.$2, isNull);
        expect(row(azul.id), findsOneWidget);

        poolAnswer = (_) => [catanMine];
        cache.add(detailOf(roster: const []));
        await animate(tester);

        expect(poolReads(), hasLength(2));
        expect(poolReads().last.$2, ['att-me']);
        expect(row(azul.id), findsNothing);
        expect(row(catanMine.id), findsOneWidget);
      });

      testWidgets("a withheld roster given back as the viewer's alone is read "
          "for again, for everyone's", (tester) async {
        await showGames(tester, detail: detailOf(roster: const []));
        expect(poolReads().single.$2, ['att-me']);

        cache.add(detailOf(roster: [me]));
        await animate(tester);

        expect(poolReads(), hasLength(2));
        expect(poolReads().last.$2, isNull);
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
        expect(poolSpinner(), findsNothing);
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
        expect(poolReads().last.$2, isNull);
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
        expect(poolSpinner(), findsOneWidget);
        expect(remote.poolRequests, isEmpty);

        // The read writes the roster to the cache, then ends.
        cache.add(detailOf());
        await settle(tester);
        heldRead!.complete(detailOf().snapshot);
        heldRead = null;
        await animate(tester);
        await animate(tester);

        expect(poolReads(), hasLength(1));
        expect(poolReads().single.$2, isNull);
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
        await press(tester, find.byKey(EventDetailScreen.poolRetryKey));
        await settle(tester);

        // The event, not the pool, which has no one to read for.
        expect(remote.detailRequests, hasLength(reads + 1));
        expect(remote.poolRequests, isEmpty);
        expect(poolSpinner(), findsOneWidget);

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

      expect(poolSpinner(), findsOneWidget);
      expect(find.bySemanticsLabel('Loading the games'), findsOneWidget);
      expect(search(), findsNothing);
      expect(scrollView(tester).semanticChildCount, 0);

      read.complete(served);
      await animate(tester);
      expect(poolSpinner(), findsNothing);
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

      expect(poolSpinner(), findsNothing);
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

      expect(find.text('No games match', skipOffstage: false), findsOneWidget);
      expect(scrollView(tester).semanticChildCount, 0);

      await press(
        tester,
        find.byKey(EventDetailScreen.poolClearFiltersKey, skipOffstage: false),
      );
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
        // Below the Nominations section (#517).
        await tester.ensureVisible(
          find.byKey(
            EventDetailScreen.poolClearFiltersKey,
            skipOffstage: false,
          ),
        );
        await tester.pump();
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

        await press(tester, clearFilters);
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
      await press(tester, find.byKey(EventDetailScreen.poolRetryKey));
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
      expect(poolSpinner(), findsOneWidget);
      expect(poolEmptyState(), findsNothing);
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
      expect(poolSpinner(), findsNothing);
      expect(find.text("Couldn't load the games"), findsOneWidget);
      expect(find.byKey(EventDetailScreen.poolRetryKey), findsOneWidget);
      // The header is back above it.
      expect(search(), findsOneWidget);
      expect(scrollView(tester).semanticChildCount, 0);

      await press(tester, find.byKey(EventDetailScreen.poolRetryKey));
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

      expect(poolSpinner(), findsNothing);
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

  group('the Nominations section (#517)', () {
    /// A nomination by Ada of [game], open for votes.
    EventNomination nominationOf(String id, OfferedGame game) =>
        EventNomination(
          id: id,
          eventId: 'e-1',
          platformGameId: game.platformGameId,
          gameId: game.gameId,
          title: game.title,
          platformName: game.platformName,
          status: NominationStatus.open,
          nominatedById: 'att-ada',
          suppliedFromId: game.id,
          createdAt: kItemInstant,
        );

    Finder nomination(String id) => find.byKey(
      EventDetailScreen.nominationRowKey(id),
      skipOffstage: false,
    );

    /// The index a screen reader counts [finder]'s row by, on screen or
    /// built past its edge.
    int semanticIndexOf(WidgetTester tester, Finder finder) => tester
        .widget<IndexedSemantics>(
          find.ancestor(
            of: finder,
            matching: find.byType(IndexedSemantics, skipOffstage: false),
          ),
        )
        .index;

    testWidgets('the section sits above the pool header', (tester) async {
      nominationsAnswer = (_) => [nominationOf('n-1', azul)];
      // Tall enough that the pool's first row is built, under the section's
      // header.
      useViewSize(tester, const Size(800, 2400));

      await showGames(tester);

      final heading = find.text('Nominations', skipOffstage: false);
      final offer = find.byKey(
        EventDetailScreen.offerGamesKey,
        skipOffstage: false,
      );
      expect(
        tester.getRect(heading).bottom,
        lessThanOrEqualTo(tester.getRect(nomination('n-1')).top),
      );
      expect(
        tester.getRect(nomination('n-1')).bottom,
        lessThanOrEqualTo(tester.getRect(offer).top),
      );
      expect(
        tester.getRect(offer).bottom,
        lessThanOrEqualTo(tester.getRect(row(catanMine.id)).top),
      );
    });

    testWidgets("a nomination's lines start where the pool's do", (
      tester,
    ) async {
      nominationsAnswer = (_) => [nominationOf('n-1', azul)];
      useViewSize(tester, const Size(800, 2400));

      await showGames(tester);

      double titleStart(Finder rowFinder) => tester
          .getTopLeft(
            find.descendant(
              of: rowFinder,
              matching: find.text('Azul', skipOffstage: false),
            ),
          )
          .dx;
      expect(titleStart(nomination('n-1')), titleStart(row(azul.id)));
    });

    testWidgets('the pool has a heading of its own, under the section, with '
        'no count of its own, in every state of the pool', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [nominationOf('n-1', azul)];

      await showGames(tester);

      final heading = find.text('Games pool', skipOffstage: false);
      final offer = find.byKey(
        EventDetailScreen.offerGamesKey,
        skipOffstage: false,
      );
      await tester.ensureVisible(heading);
      await tester.pump();
      expect(
        tester.getSemantics(heading),
        matchesSemantics(label: 'Games pool', isHeader: true),
      );
      expect(
        tester.getRect(nomination('n-1')).bottom,
        lessThanOrEqualTo(tester.getRect(heading).top),
      );
      expect(
        tester.getRect(heading).bottom,
        lessThanOrEqualTo(tester.getRect(offer).top),
      );
      // A heading, not a row.
      expect(scrollView(tester).semanticChildCount, 5);

      // While the filter narrows, the header's count is the one count.
      await tester.ensureVisible(
        find.byKey(EventDetailScreen.poolNotMineKey, skipOffstage: false),
      );
      await tester.pump();
      await tester.tap(notMine());
      await tester.pump();

      expect(find.text('3 games of 4', skipOffstage: false), findsOneWidget);
      await tester.ensureVisible(heading);
      await tester.pump();
      expect(
        tester.getSemantics(heading),
        matchesSemantics(label: 'Games pool', isHeader: true),
      );

      // With nobody to read the pool for, the heading stays over the state.
      await tester.pumpWidget(const SizedBox());
      await showGames(
        tester,
        detail: EventDetail(
          snapshot: detailOf().snapshot.copyWith(attendees: const []),
        ),
      );

      expect(find.text("The games aren't shown to you"), findsOneWidget);
      expect(find.text('Games pool', skipOffstage: false), findsOneWidget);
      handle.dispose();
    });

    testWidgets('semanticChildCount counts nomination and pool rows', (
      tester,
    ) async {
      nominationsAnswer = (_) => [
        nominationOf('n-1', azul),
        nominationOf('n-2', root),
      ];
      // Tall enough that every row is built, the vote under each nomination
      // included.
      useViewSize(tester, const Size(800, 2400));

      await showGames(tester);

      expect(scrollView(tester).semanticChildCount, 6);
      // The pool's rows count on from the nominations'.
      expect(semanticIndexOf(tester, nomination('n-1')), 0);
      expect(semanticIndexOf(tester, nomination('n-2')), 1);
      expect(semanticIndexOf(tester, row(catanMine.id)), 2);
      expect(semanticIndexOf(tester, row(root.id)), 5);

      // The pool narrowed: the rows it keeps.
      await tester.ensureVisible(
        find.byKey(EventDetailScreen.poolNotMineKey, skipOffstage: false),
      );
      await tester.pump();
      await tester.tap(notMine());
      await tester.pump();

      expect(scrollView(tester).semanticChildCount, 5);

      // The pool in a state of its own: the nominations alone.
      await tester.ensureVisible(
        find.byKey(EventDetailScreen.poolSearchKey, skipOffstage: false),
      );
      await tester.pump();
      await tester.enterText(search(), 'gloomhaven');
      await tester.pump();

      expect(find.text('No games match'), findsOneWidget);
      expect(scrollView(tester).semanticChildCount, 2);
    });

    testWidgets('a section in a state of its own counts no rows', (
      tester,
    ) async {
      nominationsAnswer = (_) => throw _offline;

      await showGames(tester);

      expect(find.text("Couldn't load nominations"), findsOneWidget);
      expect(scrollView(tester).semanticChildCount, 4);
      expect(semanticIndexOf(tester, row(catanMine.id)), 0);
    });
  });

  group('rows', () {
    testWidgets("a row says the game, where it's played, and who brings it, "
        'as one node', (tester) async {
      final handle = tester.ensureSemantics();
      await showGames(tester);
      // Below the Nominations section (#517).
      await tester.ensureVisible(row(root.id));
      await tester.pump();

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
      expect(find.text('Catan', skipOffstage: false), findsNWidgets(2));
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
      // On screen, below the Nominations section (#517): a node scrolled
      // out of view is hidden.
      await tester.ensureVisible(takeBack(catanMine.id));
      await tester.pump();
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

    // The shared filter sheet, applied on the device (#851).
    group('Filters', () {
      Finder filters() => find.byKey(GameFilterKeys.button);
      Finder filterChip(String id) => find.byKey(GameFilterKeys.inUse(id));
      FocusNode filtersFocus(WidgetTester tester) =>
          tester.widget<ButtonStyleButton>(filters()).focusNode!;

      /// The pool with platform types: the viewer's Catan and Ada's Azul on
      /// a tabletop, Ada's Catan on a PC, and Bo's Root with none, as an old
      /// server sends it.
      void servePlatforms() => served = [
        _game('o-1', 'att-me', 'Catan', platformType: PlatformType.tabletop),
        _game('o-2', 'att-ada', 'Azul', platformType: PlatformType.tabletop),
        _game(
          'o-3',
          'att-ada',
          'Catan',
          platform: 'Board Game Arena',
          platformType: PlatformType.pc,
          medium: GameMedium.digital,
        ),
        _game('o-4', 'att-bo', 'Root', medium: null),
      ];

      Future<void> openFilters(WidgetTester tester) async {
        await press(tester, filters());
        await animate(tester);
      }

      Future<void> tapInSheet(WidgetTester tester, Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pump();
        await tester.tap(finder);
        await tester.pump();
      }

      Future<void> closeFilters(WidgetTester tester) async {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await animate(tester);
      }

      /// Opens the sheet, chooses [type], flipped where [flipped], and
      /// closes it.
      Future<void> filterBy(
        WidgetTester tester,
        PlatformType type, {
        bool flipped = false,
      }) async {
        await openFilters(tester);
        await tapInSheet(tester, find.byKey(GameFilterKeys.platformType(type)));
        if (flipped) {
          await tapInSheet(
            tester,
            find.byKey(GameFilterKeys.exclude(CollectionFacet.platformType)),
          );
        }
        await closeFilters(tester);
      }

      testWidgets('Filters opens the sheet and narrows the pool', (
        tester,
      ) async {
        servePlatforms();
        await showGames(tester);
        expect(
          find.descendant(of: filters(), matching: find.text('Filters')),
          findsOneWidget,
        );

        await openFilters(tester);
        // Offer games' sheet: the medium and the flips, and no missing-base
        // switch, since the rows are flat.
        expect(
          find.byKey(GameFilterKeys.medium(GameMedium.digital)),
          findsOneWidget,
        );
        expect(
          find.byKey(GameFilterKeys.exclude(CollectionFacet.platformType)),
          findsOneWidget,
        );
        expect(find.byKey(GameFilterKeys.missingBaseGame), findsNothing);
        await tapInSheet(
          tester,
          find.byKey(GameFilterKeys.platformType(PlatformType.tabletop)),
        );
        await closeFilters(tester);

        // Root, with no platform type, is in no set.
        expect(rowsShown(tester), ['o-1', 'o-2']);
        expect(scrollView(tester).semanticChildCount, 2);
        expect(find.text('Filters (1)'), findsOneWidget);
        expect(
          find.descendant(
            of: filterChip('platform_tabletop'),
            matching: find.text('Tabletop'),
          ),
          findsOneWidget,
        );
        // Closed, it puts focus back on Filters.
        expect(filtersFocus(tester).hasPrimaryFocus, isTrue);
      });

      testWidgets('the search and the facets narrow together, and the sheet '
          'leaves the search as typed', (tester) async {
        servePlatforms();
        await showGames(tester);
        await tester.enterText(search(), 'catan');
        await tester.pump();

        await filterBy(tester, PlatformType.tabletop);

        // Ada's Catan is on a PC.
        expect(rowsShown(tester), ['o-1']);
        expect(tester.widget<TextField>(search()).controller!.text, 'catan');
        expect(find.text('1 game of 4'), findsOneWidget);
      });

      testWidgets('flipped, it keeps the rest, a row with no platform type '
          'included', (tester) async {
        servePlatforms();
        await showGames(tester);

        await filterBy(tester, PlatformType.tabletop, flipped: true);

        expect(rowsShown(tester), ['o-3', 'o-4']);
        expect(
          find.descendant(
            of: filterChip('platform_tabletop'),
            matching: find.text('Not Tabletop'),
          ),
          findsOneWidget,
        );
      });

      testWidgets('a chip removed lets its filter go', (tester) async {
        servePlatforms();
        await showGames(tester);
        await filterBy(tester, PlatformType.tabletop);

        await press(tester, filterChip('platform_tabletop'));
        await animate(tester);

        expect(filterChip('platform_tabletop'), findsNothing);
        expect(rowsShown(tester), ['o-1', 'o-2', 'o-3', 'o-4']);
        expect(find.text('Filters (1)'), findsNothing);
      });

      testWidgets('removing the last chip hands focus to Filters', (
        tester,
      ) async {
        servePlatforms();
        await showGames(tester);
        await filterBy(tester, PlatformType.tabletop);
        await tester.ensureVisible(filterChip('platform_tabletop'));
        await tester.pump();
        tester
            .widget<InputChip>(filterChip('platform_tabletop'))
            .focusNode!
            .requestFocus();
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);

        expect(filterChip('platform_tabletop'), findsNothing);
        expect(filtersFocus(tester).hasPrimaryFocus, isTrue);
      });

      testWidgets("removing the last chip by a screen reader's activation "
          'hands focus to Filters', (tester) async {
        final handle = tester.ensureSemantics();
        servePlatforms();
        await showGames(tester);
        await filterBy(tester, PlatformType.tabletop);
        await focusNothing(tester);

        screenReaderTap(tester, 'Tabletop');
        await animate(tester);

        expect(filterChip('platform_tabletop'), findsNothing);
        expect(filtersFocus(tester).hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets('Clear filters clears the facets too', (tester) async {
        servePlatforms();
        await showGames(tester);
        await filterBy(tester, PlatformType.console);
        final clearFilters = find.byKey(
          EventDetailScreen.poolClearFiltersKey,
          skipOffstage: false,
        );
        expect(
          find.text('No games match', skipOffstage: false),
          findsOneWidget,
        );

        await tester.ensureVisible(clearFilters);
        await tester.pump();
        await activateByKeyboard(tester, clearFilters);
        await animate(tester);

        expect(rowsShown(tester), ['o-1', 'o-2', 'o-3', 'o-4']);
        expect(filterChip('platform_console'), findsNothing);
        expect(
          find.descendant(of: filters(), matching: find.text('Filters')),
          findsOneWidget,
        );
        // The hand-off stays on People.
        expect(peopleFocus(tester).hasPrimaryFocus, isTrue);
      });

      testWidgets('the count line counts facet narrowing', (tester) async {
        final handle = tester.ensureSemantics();
        servePlatforms();
        await showGames(tester);
        expect(find.byKey(EventDetailScreen.poolCountKey), findsNothing);

        await filterBy(tester, PlatformType.tabletop);

        expect(find.text('2 games of 4'), findsOneWidget);
        expect(
          tester.getSemantics(find.byKey(EventDetailScreen.poolCountKey)),
          matchesSemantics(label: '2 games of 4', isLiveRegion: true),
        );

        // With a person chosen too, both narrow.
        await choosePeople(tester, ['att-ada']);
        expect(rowsShown(tester), ['o-2']);
        expect(find.text('1 game of 4'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('the filters outlive a read of the pool and a switch to '
          'Details', (tester) async {
        servePlatforms();
        await showGames(tester);
        await filterBy(tester, PlatformType.tabletop);

        blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
        await settle(tester);
        await animate(tester);
        // The bar, scrolled out of view to reach the sheet's button.
        await tester.ensureVisible(
          find.byKey(
            EventDetailScreen.tabKey(EventDetailTab.details),
            skipOffstage: false,
          ),
        );
        await tester.pump();
        await tester.tap(tab(EventDetailTab.details));
        await animate(tester);
        await chooseGames(tester);

        expect(rowsShown(tester), ['o-1', 'o-2']);
        expect(find.text('Filters (1)'), findsOneWidget);
      });

      testWidgets('nothing chosen, the chips add no space under the people', (
        tester,
      ) async {
        servePlatforms();
        await showGames(tester);
        final wrap = find
            .ancestor(of: people(), matching: find.byType(Wrap))
            .first;
        final tokens = BgeTokens.of(tester.element(people()));

        // From the controls to the first row, whose padding is its own: the
        // header's closing gap alone.
        expect(
          tester.getRect(row('o-1')).top - tester.getRect(wrap).bottom,
          tokens.spaceMd,
        );

        await filterBy(tester, PlatformType.tabletop);
        // A chip, spaced from the controls above it, then the count.
        expect(
          tester.getRect(filterChip('platform_tabletop')).top -
              tester.getRect(wrap).bottom,
          greaterThanOrEqualTo(tokens.spaceSm),
        );
      });

      testWidgets('a range the sheet commits as the screen goes changes '
          'nothing', (tester) async {
        servePlatforms();
        await showGames(tester);
        await openFilters(tester);
        final from = find.byKey(
          GameFilterKeys.rangeField(CollectionFacet.publishYear, from: true),
        );
        await tester.ensureVisible(from);
        await tester.pump();
        await tester.enterText(from, '2000');
        await tester.pump();

        // The screen goes with the sheet open, as a redirect takes it, and
        // the field commits its bound once that frame has ended.
        await tester.pumpWidget(const SizedBox());
        await tester.pump();

        expect(tester.takeException(), isNull);
      });
    });
  });

  group('names with subtitles (#851)', () {
    final seafarers = _game('o-1', 'att-me', 'Catan', subtitle: 'Seafarers');

    testWidgets('a row names its subtitle', (tester) async {
      final handle = tester.ensureSemantics();
      served = [seafarers, azul];
      await showGames(tester);
      await tester.ensureVisible(row(seafarers.id));
      await tester.pump();

      final name = find.descendant(
        of: row(seafarers.id),
        matching: find.text('Catan: Seafarers'),
      );
      expect(name, findsOneWidget);
      expect(
        tester.getSemantics(name),
        matchesSemantics(
          label: "Catan: Seafarers\nTabletop, Physical\nYou're bringing this",
        ),
      );
      // A subtitle searched for finds it.
      await tester.enterText(search(), 'seafarers');
      await tester.pump();
      expect(rowsShown(tester), [seafarers.id]);
      handle.dispose();
    });

    testWidgets("a take-back's outcome names the subtitle", (tester) async {
      served = [seafarers, azul];
      await showGames(tester);
      served = [azul];

      await press(tester, takeBack(seafarers.id));
      await animate(tester);

      expect(
        find.descendant(
          of: outcome(),
          matching: find.text('Catan: Seafarers is off your games.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets("a dropped take-back's outcome names the subtitle", (
      tester,
    ) async {
      served = [seafarers, azul];
      await showGames(tester);
      await tester.ensureVisible(takeBack(seafarers.id));
      await tester.pump();
      final detail = blocOf<EventDetailBloc>(tester);
      heldRead = Completer<EventSnapshot>();

      // A read starts, and the press lands before a frame shows it.
      detail.add(const EventDetailRetryRequested());
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      await tester.tap(takeBack(seafarers.id));

      // Meanwhile a read of the pool finds the game gone.
      served = [azul];
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
            "Catan: Seafarers wasn't taken back: the event changed first.",
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Take back says the subtitle, and so does the dialog before '
        "someone else's is taken back", (tester) async {
      final handle = tester.ensureSemantics();
      final adas = _game('o-2', 'att-ada', 'Azul', subtitle: 'Summer Pavilion');
      served = [seafarers, adas];
      await showGames(
        tester,
        detail: detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.host),
        ),
      );
      await tester.ensureVisible(takeBack(seafarers.id));
      await tester.pump();

      expect(
        tester.getSemantics(takeBack(seafarers.id)),
        matchesSemantics(
          label: 'Take back Catan: Seafarers',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasFocusAction: true,
          hasTapAction: true,
        ),
      );

      await press(tester, takeBack(adas.id));
      await animate(tester);
      expect(
        find.text("Take Azul: Summer Pavilion off Ada's games?"),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('Take back', () {
    testWidgets('sends the viewer, the event and the game, and the footer says '
        "it's off", (tester) async {
      await showGames(tester);
      served = [azul, catanAdas, root];

      await press(tester, takeBack(catanMine.id));
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

      await press(tester, takeBack(catanMine.id));
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

    group('a 409 names what to do (#517)', () {
      /// A nomination of the viewer's Catan (`o-1`) by [by], as [status].
      EventNomination catanNominated({
        String by = 'att-me',
        NominationStatus status = NominationStatus.open,
      }) => EventNomination(
        id: 'n-1',
        eventId: 'e-1',
        platformGameId: 'pg-o-1',
        gameId: 'g-o-1',
        title: 'Catan',
        platformName: 'Tabletop',
        status: status,
        nominatedById: by,
        suppliedFromId: catanMine.id,
        createdAt: kItemInstant,
      );

      setUp(() {
        takeBackAnswer = (_) => throw const EventWriteConflictException(
          'supplies',
          statusCode: 409,
        );
      });

      Finder says(String copy) =>
          find.descendant(of: outcome(), matching: find.text(copy));

      testWidgets('a 409 on a game the viewer nominated says to withdraw the '
          'nomination first', (tester) async {
        nominationsAnswer = (_) => [catanNominated()];
        await showGames(tester);

        await press(tester, takeBack(catanMine.id));
        await animate(tester);

        expect(says(_stillSuppliesYoursCopy), findsOneWidget);
        expect(row(catanMine.id), findsOneWidget);
      });

      testWidgets('a 409 on a game someone else nominated says only they can '
          'withdraw it', (tester) async {
        nominationsAnswer = (_) => [
          catanNominated(by: 'att-ada', status: NominationStatus.paused),
        ];
        await showGames(tester);

        await press(tester, takeBack(catanMine.id));
        await animate(tester);

        expect(says(_stillSuppliesTheirsCopy), findsOneWidget);
      });

      testWidgets('a 409 on a game both the viewer and someone else '
          'nominated says the others must withdraw theirs too', (
        tester,
      ) async {
        nominationsAnswer = (_) => [
          catanNominated(),
          catanNominated(by: 'att-ada').copyWith(id: 'n-2'),
        ];
        await showGames(tester);

        await press(tester, takeBack(catanMine.id));
        await animate(tester);

        expect(
          says(
            "Catan is nominated, so it can't come off your games yet. "
            'Withdraw your nomination, and whoever else nominated it has to '
            'withdraw theirs.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('a 409 with no live nomination keeps the lineup copy', (
        tester,
      ) async {
        // Decided: in the lineup, if anything, which isn't the viewer's to
        // undo here.
        nominationsAnswer = (_) => [
          catanNominated(status: NominationStatus.passed),
        ];
        await showGames(tester);

        await press(tester, takeBack(catanMine.id));
        await animate(tester);

        expect(says(_stillSuppliesCopy), findsOneWidget);
      });

      testWidgets('a 409 on a game the pool no longer holds finds its '
          "nomination by the game's id", (tester) async {
        final held = Completer<void>();
        takeBackAnswer = (_) => held.future;
        nominationsAnswer = (_) => [catanNominated()];
        await showGames(tester);

        await press(tester, takeBack(catanMine.id));
        await animate(tester);
        // A read lands while the take-back is out, without the game.
        served = [azul, catanAdas, root];
        blocOf<EventGamesBloc>(tester).add(
          const EventGamesRequested('e-1', ['att-me', 'att-ada', 'att-bo']),
        );
        await settle(tester);
        expect(row(catanMine.id), findsNothing);

        held.completeError(
          const EventWriteConflictException('supplies', statusCode: 409),
        );
        await animate(tester);

        expect(says(_stillSuppliesYoursCopy), findsOneWidget);
      });

      testWidgets('the copy stays as it landed once the nomination is '
          'withdrawn', (tester) async {
        final handle = tester.ensureSemantics();
        nominationsAnswer = (_) => [catanNominated()];
        await showGames(tester);

        await press(tester, takeBack(catanMine.id));
        await animate(tester);
        expect(says(_stillSuppliesYoursCopy), findsOneWidget);
        final banner = tester.element(outcome());

        // The viewer does as it says.
        blocOf<EventNominationsBloc>(tester).add(
          NominationWithdrawn('e-1', catanNominated()),
        );
        await animate(tester);
        expect(remote.withdrawals, hasLength(1));

        // The same banner, with the same words: words that changed would be
        // read out again.
        expect(tester.element(outcome()), same(banner));
        expect(says(_stillSuppliesYoursCopy), findsOneWidget);
        handle.dispose();
      });
    });

    testWidgets('a refusal and a failure each say so', (tester) async {
      takeBackAnswer = (_) =>
          throw const EventWriteRefusedException('no', statusCode: 403);
      await showGames(tester);

      await press(tester, takeBack(catanMine.id));
      await animate(tester);
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text("You can't take Catan back."),
        ),
        findsOneWidget,
      );

      takeBackAnswer = (_) => throw _offline;
      await press(tester, takeBack(catanMine.id));
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
      await press(tester, takeBack(catanMine.id));
      await animate(tester);
      final first = tester.element(outcome());

      await press(tester, takeBack(catanMine.id));
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

      await press(tester, takeBack(catanMine.id));
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
      // On screen before the read starts, so the press needs no frame.
      await tester.ensureVisible(takeBack(catanMine.id));
      await tester.pump();
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
        return _offeredAll(request);
      };
      await showGames(tester);
      // On screen before the read starts, so the press needs no frame.
      await tester.ensureVisible(takeBack(catanMine.id));
      await tester.pump();
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

        await press(tester, takeBack(catanMine.id));
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
        await press(tester, takeBack(catanMine.id));
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
        await press(tester, takeBack(catanMine.id));
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
        await press(tester, takeBack(catanMine.id));
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

  group("Take back on someone else's row (#518)", () {
    final host = _row('att-me', name: 'Me', role: EventRole.host);
    const askAzul = "Take Azul off Ada's games?";
    const askBody = 'Only they can offer it again.';

    Finder confirmTakeBack() =>
        find.byKey(EventDetailScreen.poolTakeBackConfirmKey);
    Finder keepIt() => find.byKey(EventDetailScreen.poolTakeBackKeepKey);

    testWidgets("a host gets Take back on someone else's row", (tester) async {
      final handle = tester.ensureSemantics();
      await showGames(tester, detail: detailOf(viewer: host));

      for (final game in [catanMine, azul, catanAdas, root]) {
        expect(takeBack(game.id), findsOneWidget, reason: game.title);
      }
      // On screen, below the Nominations section (#517): a node scrolled
      // out of view is hidden.
      await tester.ensureVisible(takeBack(azul.id));
      await tester.pump();
      expect(
        tester.getSemantics(takeBack(azul.id)),
        matchesSemantics(
          label: 'Take back Azul',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasFocusAction: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    for (final (role, who) in [
      (EventRole.participant, 'a participant'),
      (EventRole.organizer, 'an organizer'),
    ]) {
      testWidgets(
        "$who gets no Take back on someone else's row",
        (tester) async {
          await showGames(
            tester,
            detail: detailOf(
              viewer: _row('att-me', name: 'Me', role: role),
            ),
          );

          expect(takeBack(catanMine.id), findsOneWidget);
          for (final game in [azul, catanAdas, root]) {
            expect(takeBack(game.id), findsNothing, reason: game.title);
          }
        },
      );
    }

    testWidgets("taking back someone else's game asks first and sends their "
        'attendee id', (tester) async {
      await showGames(tester, detail: detailOf(viewer: host));
      served = [catanMine, catanAdas, root];

      await press(tester, takeBack(azul.id));
      await animate(tester);

      // It asks first, naming the game and whose it is.
      expect(remote.takeBacks, isEmpty);
      expect(find.text(askAzul), findsOneWidget);
      expect(find.text(askBody), findsOneWidget);
      expect(
        find.descendant(of: keepIt(), matching: find.text('Keep it')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: confirmTakeBack(),
          matching: find.text('Take back'),
        ),
        findsOneWidget,
      );
      // Drawn as a destructive action.
      expect(
        tester
            .widget<TextButton>(confirmTakeBack())
            .style
            ?.foregroundColor
            ?.resolve(const {}),
        Theme.of(tester.element(confirmTakeBack())).colorScheme.error,
      );

      await tester.tap(confirmTakeBack());
      await animate(tester);

      expect(find.text(askAzul), findsNothing);
      expect(remote.takeBacks, [
        (eventId: 'e-1', attendeeId: 'att-ada', offeredGameId: 'o-2'),
      ]);
      expect(row(azul.id), findsNothing);
      expect(
        blocOf<EventGamesBloc>(tester).state.outcome,
        const EventTakeBackOutcome(
          result: EventTakeBackResult.done,
          title: 'Azul',
          offeredGameId: 'o-2',
          attendeeId: 'att-ada',
        ),
      );
    });

    testWidgets('Keep it sends nothing, says nothing, and puts focus back on '
        'Take back', (tester) async {
      await showGames(tester, detail: detailOf(viewer: host));
      await tester.ensureVisible(takeBack(azul.id));
      await tester.pump();
      takeBackFocus(tester, azul.id).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(find.text(askAzul), findsOneWidget);

      await tester.tap(keepIt());
      await animate(tester);

      expect(find.text(askAzul), findsNothing);
      expect(remote.takeBacks, isEmpty);
      expect(outcome(), findsNothing);
      expect(row(azul.id), findsOneWidget);
      expect(takeBackFocus(tester, azul.id).hasPrimaryFocus, isTrue);

      // Back closes it the same way.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(find.text(askAzul), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);

      expect(find.text(askAzul), findsNothing);
      expect(remote.takeBacks, isEmpty);
      expect(outcome(), findsNothing);
      expect(takeBackFocus(tester, azul.id).hasPrimaryFocus, isTrue);
    });

    testWidgets("the viewer's own Take back still sends without asking", (
      tester,
    ) async {
      await showGames(tester, detail: detailOf(viewer: host));
      served = [azul, catanAdas, root];

      await press(tester, takeBack(catanMine.id));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.takeBacks, [
        (eventId: 'e-1', attendeeId: 'att-me', offeredGameId: 'o-1'),
      ]);
      expect(row(catanMine.id), findsNothing);
    });

    testWidgets("someone the roster doesn't name is this person in the "
        'dialog', (tester) async {
      served = [_game('o-9', 'att-nn', 'Azul')];

      await showGames(
        tester,
        detail: detailOf(viewer: host, roster: [host, _row('att-nn')]),
      );
      await press(tester, takeBack('o-9'));
      await animate(tester);

      expect(find.text("Take Azul off this person's games?"), findsOneWidget);
    });

    testWidgets('a household admin with no row on the roster gets Take back '
        "on every row, and sends the row's attendee", (tester) async {
      served = [azul, root];

      await showGames(
        tester,
        detail: detailOf(
          attending: false,
          roster: [ada, bo],
          householdId: 'h-1',
        ),
        householdRole: (_) async => HouseholdRole.householdAdmin,
      );

      expect(takeBack(azul.id), findsOneWidget);
      expect(takeBack(root.id), findsOneWidget);
      // With no row of their own there is no list to offer to.
      expect(offerGames(), findsNothing);

      served = [root];
      await press(tester, takeBack(root.id));
      await animate(tester);
      expect(find.text("Take Root off Bo's games?"), findsOneWidget);
      await tester.tap(confirmTakeBack());
      await animate(tester);

      expect(remote.takeBacks, [
        (eventId: 'e-1', attendeeId: 'att-bo', offeredGameId: 'o-4'),
      ]);
      // With no row of their own, every row is someone else's.
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text("Root is off Bo's games."),
        ),
        findsOneWidget,
      );
    });

    testWidgets('sends nothing if the viewer may no longer take it back once '
        'the dialog closes, and the footer says so', (tester) async {
      await showGames(tester, detail: detailOf(viewer: host));
      await press(tester, takeBack(azul.id));
      await animate(tester);
      expect(find.text(askAzul), findsOneWidget);

      // Meanwhile a sync brings the viewer back as a participant: the row
      // under the dialog loses its Take back.
      cache.add(detailOf());
      await settle(tester);
      expect(takeBack(azul.id), findsNothing);

      await tester.tap(confirmTakeBack());
      await animate(tester);

      expect(remote.takeBacks, isEmpty);
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text(
            "Azul wasn't taken back: the event changed first.",
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a detail read that starts while it asks holds Take back, '
        'which gets focus back, and the take-back waits for the read', (
      tester,
    ) async {
      await showGames(tester, detail: detailOf(viewer: host));
      await tester.ensureVisible(takeBack(azul.id));
      await tester.pump();
      takeBackFocus(tester, azul.id).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(find.text(askAzul), findsOneWidget);

      // A read starts under the dialog, which would disable Take back.
      heldRead = Completer<EventSnapshot>();
      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await tester.tap(confirmTakeBack());
      await animate(tester);

      // Held: enabled and inert, so the dialog's focus came back to it.
      expect(remote.takeBacks, isEmpty);
      final button = tester.widget<ButtonStyleButton>(takeBack(azul.id));
      expect(button.onPressed, isNotNull);
      expect(button.focusNode!.hasPrimaryFocus, isTrue);

      served = [catanMine, catanAdas, root];
      heldRead!.complete(detailOf(viewer: host).snapshot);
      heldRead = null;
      await animate(tester);
      await animate(tester);

      expect(remote.takeBacks, [
        (eventId: 'e-1', attendeeId: 'att-ada', offeredGameId: 'o-2'),
      ]);
      expect(row(azul.id), findsNothing);
      expect(takeBackFocus(tester, catanAdas.id).hasPrimaryFocus, isTrue);
    });

    testWidgets("is disabled offline and says why, as the viewer's own is", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      await showGames(
        tester,
        detail: detailOf(viewer: host),
        offline: offline,
      );
      await tester.ensureVisible(takeBack(azul.id));
      await tester.pump();

      expect(
        tester.widget<ButtonStyleButton>(takeBack(azul.id)).onPressed,
        isNull,
      );
      expect(
        tester.getSemantics(takeBack(azul.id)),
        matchesSemantics(
          label: 'Take back Azul',
          hint: _onlineOnlyCopy,
          isButton: true,
          hasEnabledState: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('with no Offer games, offline, the reason is drawn once all '
        'the same', (tester) async {
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      served = [azul, root];

      await showGames(
        tester,
        detail: detailOf(
          attending: false,
          roster: [ada, bo],
          householdId: 'h-1',
        ),
        householdRole: (_) async => HouseholdRole.householdAdmin,
        offline: offline,
      );

      expect(offerGames(), findsNothing);
      for (final game in [azul, root]) {
        expect(
          tester.widget<ButtonStyleButton>(takeBack(game.id)).onPressed,
          isNull,
          reason: game.title,
        );
      }
      expect(find.text(_onlineOnlyCopy), findsOneWidget);

      offline.value = false;
      await tester.pump();
      expect(find.text(_onlineOnlyCopy), findsNothing);
    });

    group('the footer names whose games they were', () {
      Finder says(String copy) =>
          find.descendant(of: outcome(), matching: find.text(copy));

      /// A live nomination of Ada's Azul (`o-2`) by [by].
      EventNomination azulNominated(String by) => EventNomination(
        id: 'n-1',
        eventId: 'e-1',
        platformGameId: 'pg-o-2',
        gameId: 'g-o-2',
        title: 'Azul',
        platformName: 'Tabletop',
        status: NominationStatus.open,
        nominatedById: by,
        suppliedFromId: azul.id,
        createdAt: kItemInstant,
      );

      /// Shows the event as host and takes Ada's Azul back, confirmed, with
      /// [after] what the pool's reads serve from the press on.
      Future<void> takeBackAzul(
        WidgetTester tester, {
        List<OfferedGame>? after,
      }) async {
        await showGames(tester, detail: detailOf(viewer: host));
        if (after != null) served = after;
        await press(tester, takeBack(azul.id));
        await animate(tester);
        await tester.tap(confirmTakeBack());
        await animate(tester);
      }

      testWidgets("a host's take-back of someone else's game says it is off "
          'their games', (tester) async {
        await takeBackAzul(tester, after: [catanMine, catanAdas, root]);

        expect(says("Azul is off Ada's games."), findsOneWidget);
        expect(says('Azul is off your games.'), findsNothing);
      });

      testWidgets("someone the roster doesn't name is this person", (
        tester,
      ) async {
        served = [_game('o-9', 'att-nn', 'Azul')];
        await showGames(
          tester,
          detail: detailOf(viewer: host, roster: [host, _row('att-nn')]),
        );
        served = const [];

        await press(tester, takeBack('o-9'));
        await animate(tester);
        await tester.tap(confirmTakeBack());
        await animate(tester);

        expect(says("Azul is off this person's games."), findsOneWidget);
      });

      group('a 409', () {
        setUp(() {
          takeBackAnswer = (_) => throw const EventWriteConflictException(
            'supplies',
            statusCode: 409,
          );
        });

        testWidgets('with no live nomination keeps the lineup copy, naming '
            'whose games', (tester) async {
          await takeBackAzul(tester);

          expect(
            says(
              'Azul is nominated, or in the lineup for a date still to '
              "come, so it can't come off Ada's games yet.",
            ),
            findsOneWidget,
          );
          expect(row(azul.id), findsOneWidget);
        });

        testWidgets('on a game the host nominated says to withdraw the '
            'nomination first, naming whose games', (tester) async {
          nominationsAnswer = (_) => [azulNominated('att-me')];

          await takeBackAzul(tester);

          expect(
            says(
              "Azul is nominated, so it can't come off Ada's games yet. "
              'Withdraw your nomination first.',
            ),
            findsOneWidget,
          );
        });

        testWidgets('on a game the host and someone else nominated says '
            'the others must withdraw theirs too, naming whose games', (
          tester,
        ) async {
          // Tall enough that Azul's row is built under two nominations.
          useViewSize(tester, const Size(800, 2000));
          nominationsAnswer = (_) => [
            azulNominated('att-me'),
            azulNominated('att-bo').copyWith(id: 'n-2'),
          ];

          await takeBackAzul(tester);

          expect(
            says(
              "Azul is nominated, so it can't come off Ada's games yet. "
              'Withdraw your nomination, and whoever else nominated it has '
              'to withdraw theirs.',
            ),
            findsOneWidget,
          );
        });

        testWidgets('on a game someone else nominated says only they can '
            'withdraw it, naming whose games', (tester) async {
          nominationsAnswer = (_) => [azulNominated('att-bo')];

          await takeBackAzul(tester);

          expect(
            says(
              "Azul is nominated, so it can't come off Ada's games yet. "
              'Only whoever nominated it can withdraw it.',
            ),
            findsOneWidget,
          );
        });

        testWidgets('keeps the words it landed with as the roster renames '
            'them', (tester) async {
          await takeBackAzul(tester);
          const landed =
              'Azul is nominated, or in the lineup for a date still to '
              "come, so it can't come off Ada's games yet.";
          expect(says(landed), findsOneWidget);

          cache.add(
            detailOf(
              viewer: host,
              roster: [
                host,
                _row('att-ada', name: 'Adaline'),
                bo,
              ],
            ),
          );
          await settle(tester);
          await animate(tester);

          expect(find.text('Adaline is bringing this'), findsWidgets);
          expect(says(landed), findsOneWidget);
        });

        testWidgets("on the viewer's own row keeps today's copy", (
          tester,
        ) async {
          await showGames(tester, detail: detailOf(viewer: host));

          await press(tester, takeBack(catanMine.id));
          await animate(tester);

          expect(says(_stillSuppliesCopy), findsOneWidget);
        });
      });

      testWidgets("the viewer's own row keeps today's copy", (tester) async {
        await showGames(tester, detail: detailOf(viewer: host));
        served = [azul, catanAdas, root];

        await press(tester, takeBack(catanMine.id));
        await animate(tester);

        expect(says('Catan is off your games.'), findsOneWidget);
      });
    });

    group('after it, focus goes', () {
      /// Takes [id] back from the keyboard: Enter on its Take back, then
      /// the dialog's Take back.
      Future<void> takeBackByKeyboard(WidgetTester tester, String id) async {
        await tester.ensureVisible(takeBack(id));
        await tester.pump();
        takeBackFocus(tester, id).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);
        expect(confirmTakeBack(), findsOneWidget);
        await tester.tap(confirmTakeBack());
        await animate(tester);
        await animate(tester);
      }

      testWidgets("to the next row's Take back, whoever's it is", (
        tester,
      ) async {
        await showGames(tester, detail: detailOf(viewer: host));
        served = [catanMine, catanAdas, root];

        await takeBackByKeyboard(tester, azul.id);

        expect(row(azul.id), findsNothing);
        expect(takeBackFocus(tester, catanAdas.id).hasPrimaryFocus, isTrue);
      });

      testWidgets('nowhere while it is out: Take back keeps it, held', (
        tester,
      ) async {
        final answer = Completer<void>();
        takeBackAnswer = (_) => answer.future;
        await showGames(tester, detail: detailOf(viewer: host));
        served = [catanMine, catanAdas, root];

        await takeBackByKeyboard(tester, azul.id);

        // Back from the dialog, and out: inert, not disabled, so it holds
        // focus (#607).
        expect(remote.takeBacks, hasLength(1));
        final button = tester.widget<ButtonStyleButton>(takeBack(azul.id));
        expect(button.onPressed, isNotNull);
        expect(button.focusNode!.hasPrimaryFocus, isTrue);

        answer.complete();
        await animate(tester);
        await animate(tester);
        expect(row(azul.id), findsNothing);
        expect(takeBackFocus(tester, catanAdas.id).hasPrimaryFocus, isTrue);
      });

      testWidgets("to the previous row's, from the last", (tester) async {
        await showGames(tester, detail: detailOf(viewer: host));
        served = [catanMine, azul, catanAdas];

        await takeBackByKeyboard(tester, root.id);

        expect(row(root.id), findsNothing);
        expect(takeBackFocus(tester, catanAdas.id).hasPrimaryFocus, isTrue);
      });

      testWidgets("by a screen reader's activation, with focus on nothing, "
          "to the next row's Take back", (tester) async {
        final handle = tester.ensureSemantics();
        await showGames(tester, detail: detailOf(viewer: host));
        served = [catanMine, catanAdas, root];
        await tester.ensureVisible(takeBack(azul.id));
        await tester.pump();
        await focusNothing(tester);

        screenReaderTap(tester, 'Take back Azul');
        await animate(tester);
        await tester.tap(confirmTakeBack());
        await animate(tester);
        await animate(tester);

        expect(remote.takeBacks, hasLength(1));
        expect(row(azul.id), findsNothing);
        expect(takeBackFocus(tester, catanAdas.id).hasPrimaryFocus, isTrue);
        handle.dispose();
      });
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

      await press(tester, takeBack(catanMine.id));
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

      // One request for the run.
      final batch = remote.offerBatches.single;
      expect(batch.eventId, 'e-1');
      expect(batch.attendeeId, 'att-me');
      expect(batch.collectionIds, ['c-azul', 'c-root']);
      expectOutcome('2 games offered.');
      expectInFooter(tester, outcome());
      // The pool is read again once the run ends, for everyone's games.
      expect(remote.poolRequests, hasLength(reads + 1));
      expect(poolReads().last.$1, 'e-1');
      expect(poolReads().last.$2, isNull);
    });

    testWidgets('no picks, or Back, send nothing and say nothing', (
      tester,
    ) async {
      await showGames(tester);

      await offer(tester);
      pageAnswer = (_) async => const [];
      await offer(tester);

      expect(offerArgs, hasLength(2));
      expect(remote.offerBatches, isEmpty);
      expect(outcome(), findsNothing);
      expect(progress(), findsNothing);
    });

    testWidgets('progress shows in the footer while they go, saying how many', (
      tester,
    ) async {
      final held = Completer<void>();
      offerAnswer = (request) async {
        await held.future;
        return _offeredAll(request);
      };
      pageAnswer = (_) async => [
        ...picks,
        const OfferPick(collectionId: 'c-wingspan', title: 'Wingspan'),
      ];
      await showGames(tester);

      await offer(tester);

      expectInFooter(tester, progress());
      expect(
        find.descendant(
          of: progress(),
          matching: find.text('Offering 3 games…'),
        ),
        findsOneWidget,
      );
      expect(outcome(), findsNothing);

      // It says the same however long the run is out.
      await tester.pump(const Duration(seconds: 5));
      expect(
        find.descendant(
          of: progress(),
          matching: find.text('Offering 3 games…'),
        ),
        findsOneWidget,
      );

      held.complete();
      await animate(tester);
      // The outcome takes its place.
      expect(progress(), findsNothing);
      expectOutcome('3 games offered.');
    });

    testWidgets('the progress line and the outcome stay in the footer on '
        'Details; the stale-data banner does not', (tester) async {
      final held = Completer<void>();
      offerAnswer = (request) async {
        await held.future;
        return _offeredAll(request);
      };
      pageAnswer = (_) async => picks;
      await showGames(tester);
      await offer(tester);

      // A run can outlast the stay on Games.
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
      expect(
        find.descendant(
          of: progress(),
          matching: find.text('Offering 2 games…'),
        ),
        findsOneWidget,
      );

      // The read after the run fails, over the games shown.
      poolAnswer = (_) => throw _offline;
      held.complete();
      await animate(tester);

      expect(progress(), findsNothing);
      expectInFooter(tester, outcome());
      expectOutcome('2 games offered.');
      expect(stale(), findsNothing);

      await choose(EventDetailTab.games);
      expectInFooter(tester, outcome());
      expectInFooter(tester, stale());
    });

    testWidgets('the progress line is one live region, said as it appears and '
        'not again while the run is out', (tester) async {
      final handle = tester.ensureSemantics();
      final held = Completer<void>();
      offerAnswer = (request) async {
        await held.future;
        return _offeredAll(request);
      };
      pageAnswer = (_) async => [picks.first];
      await showGames(tester);
      await offer(tester);

      SemanticsNode line() => tester.getSemantics(progress());
      final id = line().id;
      expect(
        line(),
        isSemantics(label: 'Offering 1 game…', isLiveRegion: true),
      );

      // The same node, saying the same, for as long as the run is out.
      await tester.pump(const Duration(seconds: 3));
      expect(
        line(),
        isSemantics(label: 'Offering 1 game…', isLiveRegion: true),
      );
      expect(line().id, id);

      held.complete();
      await animate(tester);
      expect(progress(), findsNothing);
      expectOutcome('1 game offered.');
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

      expect(remote.offerBatches, isEmpty);
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
      expect(remote.offerBatches, isEmpty);

      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);
      await animate(tester);

      expect(remote.offerBatches.single.collectionIds, ['c-azul', 'c-root']);
      expectOutcome('2 games offered.');
    });

    group('each end of a run says how it went', () {
      const refused = EventWriteRefusedException('no', statusCode: 403);

      /// Picks of the entries `c-1` to `c-[count]`.
      List<OfferPick> many(int count) => [
        for (var n = 1; n <= count; n++)
          OfferPick(collectionId: 'c-$n', title: 'Game $n'),
      ];

      /// An answer that offers each batch of a run but the one that sends
      /// [id], which throws [error].
      List<GameOfferResult> Function(OfferGamesRequest) throwingFor(
        String id,
        EventRemoteException error,
      ) =>
          (request) => request.collectionIds.contains(id)
          ? throw error
          : _offeredAll(request);

      final rows = [
        (
          name: 'done',
          picked: picks,
          answer: _offeredAll,
          copy: '2 games offered.',
        ),
        (
          name: 'partly',
          picked: picks,
          answer: (OfferGamesRequest request) => [
            ..._offeredAll(request).take(1),
            ..._refusedAll(request).skip(1),
          ],
          copy: "1 game offered. 1 couldn't be offered.",
        ),
        (
          name: 'none',
          picked: picks,
          answer: _refusedAll,
          copy: 'None of those 2 games could be offered.',
        ),
        (
          name: 'refused, with some offered',
          picked: many(101),
          answer: throwingFor('c-101', refused),
          copy: "100 games offered. 1 couldn't be offered.",
        ),
        (
          name: 'refused, with none offered',
          picked: picks,
          answer: throwingFor('c-azul', refused),
          copy: "You can't offer games to this event any more.",
        ),
        (
          name: 'failed, with some offered',
          picked: many(101),
          answer: throwingFor('c-101', _offline),
          copy: "100 games offered. 1 couldn't be offered.",
        ),
        (
          name: 'failed, with none offered',
          picked: picks,
          answer: throwingFor('c-azul', _offline),
          copy: 'None of those 2 games could be offered.',
        ),
      ];

      for (final (:name, :picked, :answer, :copy) in rows) {
        testWidgets('$name: "$copy"', (tester) async {
          offerAnswer = answer;
          pageAnswer = (_) async => picked;
          await showGames(tester);

          await offer(tester);

          expectOutcome(copy);
          expectInFooter(tester, outcome());
        });
      }

      testWidgets("none, of one: \"That game couldn't be offered.\"", (
        tester,
      ) async {
        offerAnswer = _refusedAll;
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
        return _offeredAll(request);
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
      offerAnswer = (request) async {
        await last.future;
        return _offeredAll(request);
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
        return _offeredAll(request);
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
      expect(remote.offerBatches, hasLength(1));
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

      expect(remote.offerBatches, hasLength(1));
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

      await press(tester, takeBack(catanMine.id));
      await settle(tester);

      expect(tester.widget<ButtonStyleButton>(offerGames()).onPressed, isNull);
      expect(
        find.descendant(
          of: offerGames(),
          matching: find.text('Offer games', skipOffstage: false),
        ),
        findsOneWidget,
      );
      held.complete();
      await animate(tester);
    });
  });

  group('Nominate (#517)', () {
    /// `e-1`'s rules, adding games as [mode] says.
    EventPolicy policyOf(GameAdditionMode mode) => EventPolicy(
      id: 'p-1',
      eventId: 'e-1',
      allowMemberInvites: true,
      allowGuestInvites: false,
      restrictToGameCategories: false,
      requireHostApprovalToJoin: false,
      allowSpectators: false,
      strictCapacity: false,
      gameAdditionMode: mode,
      restrictToAttendeePool: false,
      voteThresholdType: VoteThresholdType.unknown,
      voteQuorumType: VoteQuorumType.unknown,
      voteEligibility: VoteEligibility.allAttendees,
      interestedWeight: InterestedWeight.asFor,
      createdAt: kItemInstant,
      updatedAt: kItemInstant,
    );

    /// Two dates ahead: Friday the 6th and Saturday the 7th, at seven.
    final twoDates = [
      confirmed('d-1', DateTime(2026, 11, 6, 19)).copyWith(eventId: 'e-1'),
      confirmed(
        'd-2',
        DateTime(2026, 11, 7, 19),
        sortOrder: 1,
      ).copyWith(eventId: 'e-1'),
    ];

    /// A nomination by Bo of [game], for the whole event or, with
    /// [occurrenceId], one date, open unless a test says otherwise.
    EventNomination nominationOf(
      String id,
      OfferedGame game, {
      String? occurrenceId,
      NominationStatus status = NominationStatus.open,
    }) => EventNomination(
      id: id,
      eventId: 'e-1',
      platformGameId: game.platformGameId,
      gameId: game.gameId,
      title: game.title,
      platformName: game.platformName,
      status: status,
      nominatedById: 'att-bo',
      suppliedFromId: game.id,
      occurrenceId: occurrenceId,
      createdAt: kItemInstant,
    );

    const notGoingHint = "Whoever brings it isn't going";
    const youNotGoingHint = "You aren't going";

    Finder nominate(String id) => find.byKey(
      EventDetailScreen.poolNominateKey(id),
      skipOffstage: false,
    );
    Finder nominated(String id) => find.byKey(
      EventDetailScreen.poolNominatedKey(id),
      skipOffstage: false,
    );
    Finder scope(String? occurrenceId) =>
        find.byKey(EventDetailScreen.nominateScopeKey(occurrenceId));
    Finder confirm() => find.byKey(EventDetailScreen.nominateConfirmKey);
    Finder nominationsOutcome() =>
        find.byKey(EventDetailScreen.nominationsOutcomeKey);
    VoidCallback? onPressed(WidgetTester tester, String id) =>
        tester.widget<ButtonStyleButton>(nominate(id)).onPressed;

    testWidgets('Nominate on a single-date event sends a whole-event '
        'nomination', (tester) async {
      await showGames(tester);

      await press(tester, nominate(azul.id));
      await animate(tester);

      // Nothing to choose: no dialog.
      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.nominates, [
        (
          eventId: 'e-1',
          platformGameId: 'pg-o-2',
          suppliedFromId: 'o-2',
          occurrenceId: null,
        ),
      ]);
      expect(
        find.descendant(
          of: nominationsOutcome(),
          matching: find.text('Azul is nominated. Voting is open.'),
        ),
        findsOneWidget,
      );
      expect(nominated(azul.id), findsOneWidget);
    });

    testWidgets('Nominate on a multi-date event asks for the scope', (
      tester,
    ) async {
      await showGames(tester, detail: detailOf(occurrences: twoDates));

      await press(tester, nominate(azul.id));
      await animate(tester);

      expect(find.text('Nominate Azul'), findsOneWidget);
      expect(
        find.descendant(
          of: scope(null),
          matching: find.text('For the whole event'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: scope('d-1'),
          matching: find.text('For Fri, Nov 6 · 7:00 PM'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: scope('d-2'),
          matching: find.text('For Sat, Nov 7 · 7:00 PM'),
        ),
        findsOneWidget,
      );

      // Cancel sends nothing.
      await tester.tap(find.text('Cancel'));
      await animate(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.nominates, isEmpty);

      await press(tester, nominate(azul.id));
      await animate(tester);
      await tester.tap(scope('d-2'));
      await tester.pump();
      await tester.tap(confirm());
      await animate(tester);

      expect(remote.nominates, [
        (
          eventId: 'e-1',
          platformGameId: 'pg-o-2',
          suppliedFromId: 'o-2',
          occurrenceId: 'd-2',
        ),
      ]);
    });

    group('a game with a subtitle (#851)', () {
      final seafarers = _game(
        'o-2',
        'att-ada',
        'Catan',
        subtitle: 'Seafarers',
      );

      testWidgets('Nominate is named "Nominate Catan: Seafarers" to a screen '
          'reader, as Take back on the same row is', (tester) async {
        final handle = tester.ensureSemantics();
        final mine = _game('o-1', 'att-me', 'Catan', subtitle: 'Seafarers');
        served = [mine, azul];
        await showGames(tester);
        await tester.ensureVisible(nominate(mine.id));
        await tester.pump();

        expect(
          tester.getSemantics(nominate(mine.id)),
          isSemantics(label: 'Nominate Catan: Seafarers', isButton: true),
        );
        expect(
          tester.getSemantics(takeBack(mine.id)),
          isSemantics(label: 'Take back Catan: Seafarers', isButton: true),
        );
        handle.dispose();
      });

      testWidgets('the scope dialog and the outcome name the subtitle', (
        tester,
      ) async {
        served = [catanMine, seafarers];
        await showGames(tester, detail: detailOf(occurrences: twoDates));

        await press(tester, nominate(seafarers.id));
        await animate(tester);

        expect(find.text('Nominate Catan: Seafarers'), findsOneWidget);

        await tester.tap(scope(null));
        await tester.pump();
        await tester.tap(confirm());
        await animate(tester);

        expect(
          find.descendant(
            of: nominationsOutcome(),
            matching: find.text(
              'Catan: Seafarers is nominated. Voting is open.',
            ),
          ),
          findsOneWidget,
        );
      });

      testWidgets("a dropped nominate's outcome names the subtitle", (
        tester,
      ) async {
        final soon = confirmed(
          'd-1',
          now.add(const Duration(minutes: 1)),
        ).copyWith(eventId: 'e-1');
        served = [catanMine, seafarers];
        await showGames(
          tester,
          detail: detailOf(occurrences: [soon, twoDates.last]),
        );

        await press(tester, nominate(seafarers.id));
        await animate(tester);
        // The date starts while the dialog is open.
        clock = now.add(const Duration(minutes: 2));
        await tester.tap(scope('d-1'));
        await tester.pump();
        await tester.tap(confirm());
        await animate(tester);

        expect(remote.nominates, isEmpty);
        expect(
          find.descendant(
            of: nominationsOutcome(),
            matching: find.text(
              "Catan: Seafarers wasn't nominated: something changed on this "
              'event first.',
            ),
          ),
          findsOneWidget,
        );
      });
    });

    testWidgets('a date already past, or cancelled, is not offered', (
      tester,
    ) async {
      await showGames(
        tester,
        detail: detailOf(
          occurrences: [
            confirmed(
              'd-0',
              DateTime(2026, 10, 2, 19),
            ).copyWith(eventId: 'e-1'),
            twoDates.first,
            twoDates.last.copyWith(status: OccurrenceStatus.cancelled),
          ],
        ),
      );

      await press(tester, nominate(azul.id));
      await animate(tester);

      expect(scope(null), findsOneWidget);
      expect(scope('d-1'), findsOneWidget);
      expect(scope('d-0'), findsNothing);
      expect(scope('d-2'), findsNothing);
    });

    testWidgets('a date that starts while the scope dialog is open is '
        'dropped', (tester) async {
      final soon = confirmed(
        'd-1',
        now.add(const Duration(minutes: 1)),
      ).copyWith(eventId: 'e-1');
      await showGames(
        tester,
        detail: detailOf(occurrences: [soon, twoDates.last]),
      );

      await press(tester, nominate(azul.id));
      await animate(tester);
      expect(scope('d-1'), findsOneWidget);

      // The date starts while the dialog is open, and the server would
      // still take a nomination for it.
      clock = now.add(const Duration(minutes: 2));
      await tester.tap(scope('d-1'));
      await tester.pump();
      await tester.tap(confirm());
      await animate(tester);

      expect(remote.nominates, isEmpty);
      expect(
        find.descendant(
          of: nominationsOutcome(),
          matching: find.text(
            "Azul wasn't nominated: something changed on this event first.",
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an event of many dates with none still ahead nominates for '
        'the whole event, asking nothing', (tester) async {
      await showGames(
        tester,
        detail: detailOf(
          occurrences: [
            for (final date in twoDates)
              date.copyWith(status: OccurrenceStatus.cancelled),
          ],
        ),
      );

      await press(tester, nominate(azul.id));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.nominates.single.occurrenceId, isNull);
    });

    testWidgets('a scope already nominated is disabled in the dialog', (
      tester,
    ) async {
      nominationsAnswer = (_) => [nominationOf('n-1', azul)];
      await showGames(tester, detail: detailOf(occurrences: twoDates));

      // The whole event is taken, and the dates are left.
      expect(onPressed(tester, azul.id), isNotNull);
      await press(tester, nominate(azul.id));
      await animate(tester);

      expect(
        tester.widget<RadioListTile<NominationScope>>(scope(null)).enabled,
        isFalse,
      );
      expect(
        find.descendant(
          of: scope(null),
          matching: find.text('Already nominated'),
        ),
        findsOneWidget,
      );
      // Pressing it chooses nothing; the first date, chosen as it opened,
      // goes.
      await tester.tap(scope(null));
      await tester.pump();
      await tester.tap(confirm());
      await animate(tester);

      expect(remote.nominates.single.occurrenceId, 'd-1');
    });

    testWidgets('with every scope taken, Nominate is disabled and says so', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        nominationOf('n-1', azul),
        nominationOf('n-2', root, occurrenceId: 'o-1'),
      ];
      // Tall enough that the pool is built below the two nominations.
      useViewSize(tester, const Size(800, 2400));
      await showGames(tester);

      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(onPressed(tester, azul.id), isNull);
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominate Azul',
          hint: 'Already nominated',
          isButton: true,
          hasEnabledState: true,
        ),
      );
      // The marker on the row already says it: not drawn again.
      expect(
        find.text('Already nominated', skipOffstage: false),
        findsNothing,
      );
      // A nomination for one date of a single-date event leaves the whole
      // event to nominate for.
      expect(onPressed(tester, root.id), isNotNull);
      handle.dispose();
    });

    testWidgets('a game in the lineup is not nominated again, whoever brings '
        'it, and Nominate says so', (tester) async {
      final handle = tester.ensureSemantics();
      // Bo's copy of Azul: the same game as Ada's.
      final azulBos = azul.copyWith(id: 'o-9', attendeeId: 'att-bo');
      served = [catanMine, azul, azulBos, root];
      nominationsAnswer = (_) => [
        nominationOf('n-1', azulBos, status: NominationStatus.approved),
      ];
      useViewSize(tester, const Size(800, 2400));
      await showGames(tester);

      for (final game in [azul, azulBos]) {
        await tester.ensureVisible(nominate(game.id));
        await tester.pump();
        expect(onPressed(tester, game.id), isNull, reason: game.id);
        expect(
          tester.getSemantics(nominate(game.id)),
          matchesSemantics(
            label: 'Nominate Azul',
            hint: 'Already in the lineup',
            isButton: true,
            hasEnabledState: true,
          ),
          reason: game.id,
        );
        // Not live: no "Nominated" marker.
        expect(nominated(game.id), findsNothing, reason: game.id);
      }
      for (final game in [catanMine, root]) {
        expect(onPressed(tester, game.id), isNotNull, reason: game.title);
      }
      handle.dispose();
    });

    testWidgets('a game in the lineup for one date leaves the others in the '
        'dialog', (tester) async {
      nominationsAnswer = (_) => [
        nominationOf(
          'n-1',
          azul,
          occurrenceId: 'd-1',
          status: NominationStatus.passed,
        ),
      ];
      await showGames(tester, detail: detailOf(occurrences: twoDates));

      await press(tester, nominate(azul.id));
      await animate(tester);

      expect(
        tester.widget<RadioListTile<NominationScope>>(scope('d-1')).enabled,
        isFalse,
      );
      expect(
        find.descendant(
          of: scope('d-1'),
          matching: find.text('Already in the lineup'),
        ),
        findsOneWidget,
      );
      for (final id in [null, 'd-2']) {
        expect(
          tester.widget<RadioListTile<NominationScope>>(scope(id)).enabled,
          isTrue,
          reason: '$id',
        );
      }
    });

    testWidgets('a nominate whose answer was lost holds Nominate until a read '
        "says whether it landed, and says why while that read can't", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var reads = 0;
      nominationsAnswer = (_) {
        reads++;
        // The first read, then the one after the lost nominate, fails.
        if (reads == 2) throw _offline;
        return const [];
      };
      nominateAnswer = (_) => throw _offline;
      useViewSize(tester, const Size(800, 2400));
      await showGames(tester);

      await press(tester, nominate(azul.id));
      await animate(tester);

      expect(remote.nominates, hasLength(1));
      expect(reads, 2);
      for (final game in [azul, root]) {
        await tester.ensureVisible(nominate(game.id));
        await tester.pump();
        expect(onPressed(tester, game.id), isNull, reason: game.title);
        expect(
          tester.getSemantics(nominate(game.id)),
          matchesSemantics(
            label: 'Nominate ${game.title}',
            hint:
                'Your last nomination may have gone through. Load the '
                'nominations again to check.',
            isButton: true,
            hasEnabledState: true,
          ),
          reason: game.title,
        );
      }

      // A retry that loads settles it.
      await tester.ensureVisible(
        find.byKey(EventDetailScreen.nominationsRetryKey),
      );
      await press(tester, find.byKey(EventDetailScreen.nominationsRetryKey));
      await animate(tester);

      expect(reads, 3);
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(onPressed(tester, azul.id), isNotNull);
      handle.dispose();
    });

    testWidgets("Nominate is disabled with its reason when the supplier isn't "
        'going', (tester) async {
      final handle = tester.ensureSemantics();
      final adaOut = _row(
        'att-ada',
        name: 'Ada',
        status: EventParticipationStatus.notAttending,
      );
      // Azul is nominated too, its nomination paused: not going comes
      // first.
      nominationsAnswer = (_) => [
        nominationOf('n-1', azul, status: NominationStatus.paused),
      ];
      // Tall enough that the pool is built below the nomination.
      useViewSize(tester, const Size(800, 2400));
      await showGames(tester, detail: detailOf(roster: [me, adaOut, bo]));

      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(onPressed(tester, azul.id), isNull);
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominate Azul',
          hint: notGoingHint,
          isButton: true,
          hasEnabledState: true,
        ),
      );
      // Drawn under each of Ada's two rows, Azul and her Catan, and only
      // there.
      expect(find.text(notGoingHint, skipOffstage: false), findsNWidgets(2));
      for (final game in [azul, catanAdas]) {
        expect(
          find.descendant(
            of: row(game.id),
            matching: find.text(notGoingHint, skipOffstage: false),
            skipOffstage: false,
          ),
          findsOneWidget,
          reason: game.title,
        );
      }
      for (final game in [catanMine, root]) {
        expect(onPressed(tester, game.id), isNotNull, reason: game.title);
      }
      handle.dispose();
    });

    testWidgets("where the roster is withheld, the viewer's own answer decides "
        'for their rows, said in the second person', (tester) async {
      final handle = tester.ensureSemantics();
      served = [catanMine, wingspanMine];
      await showGames(
        tester,
        detail: detailOf(
          viewer: _row(
            'att-me',
            name: 'Me',
            status: EventParticipationStatus.notAttending,
          ),
          roster: const [],
        ),
      );

      for (final game in [catanMine, wingspanMine]) {
        expect(onPressed(tester, game.id), isNull, reason: game.title);
      }
      expect(find.text(youNotGoingHint, skipOffstage: false), findsNWidgets(2));
      expect(find.text(notGoingHint, skipOffstage: false), findsNothing);
      await tester.ensureVisible(nominate(catanMine.id));
      await tester.pump();
      expect(
        tester.getSemantics(nominate(catanMine.id)),
        matchesSemantics(
          label: 'Nominate Catan',
          hint: youNotGoingHint,
          isButton: true,
          hasEnabledState: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('where the roster is withheld, Nominate sends a nomination '
        "for the viewer's own row", (tester) async {
      served = [catanMine, wingspanMine];
      await showGames(tester, detail: detailOf(roster: const []));

      await press(tester, nominate(wingspanMine.id));
      await animate(tester);

      expect(remote.nominates, [
        (
          eventId: 'e-1',
          platformGameId: 'pg-o-5',
          suppliedFromId: 'o-5',
          occurrenceId: null,
        ),
      ]);
      expect(nominated(wingspanMine.id), findsOneWidget);
    });

    testWidgets("Nominate says why after the nominations' first read failed, "
        'before whoever brings it not going', (tester) async {
      final handle = tester.ensureSemantics();
      final adaOut = _row(
        'att-ada',
        name: 'Ada',
        status: EventParticipationStatus.notAttending,
      );
      nominationsAnswer = (_) => throw _offline;
      useViewSize(tester, const Size(800, 2400));
      await showGames(tester, detail: detailOf(roster: [me, adaOut, bo]));

      for (final game in [azul, root]) {
        await tester.ensureVisible(nominate(game.id));
        await tester.pump();
        expect(onPressed(tester, game.id), isNull, reason: game.title);
        expect(
          tester.getSemantics(nominate(game.id)),
          matchesSemantics(
            label: 'Nominate ${game.title}',
            hint: "Couldn't load nominations",
            isButton: true,
            hasEnabledState: true,
          ),
          reason: game.title,
        );
      }
      handle.dispose();
    });

    testWidgets("Nominate says why while the nominations aren't shown to the "
        'viewer', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) =>
          throw const EventRemoteForbiddenException('no', statusCode: 403);
      await showGames(tester);

      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(onPressed(tester, azul.id), isNull);
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominate Azul',
          hint: "Nominations aren't shown to you",
          isButton: true,
          hasEnabledState: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('offline, a failed nominations read gives way to the offline '
        'reason', (tester) async {
      final handle = tester.ensureSemantics();
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      nominationsAnswer = (_) => throw _offline;
      await showGames(tester, offline: offline);

      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominate Azul',
          hint: _onlineOnlyCopy,
          isButton: true,
          hasEnabledState: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('offline, Nominate is disabled with the offline reason alone', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      final adaOut = _row(
        'att-ada',
        name: 'Ada',
        status: EventParticipationStatus.notAttending,
      );
      await showGames(
        tester,
        detail: detailOf(roster: [me, adaOut, bo]),
        offline: offline,
      );

      // Not going too, and the hint says only one thing.
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(onPressed(tester, azul.id), isNull);
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominate Azul',
          hint: _onlineOnlyCopy,
          isButton: true,
          hasEnabledState: true,
        ),
      );
      await tester.ensureVisible(nominate(root.id));
      await tester.pump();
      expect(onPressed(tester, root.id), isNull);
      // Drawn once for the tab.
      expect(find.text(_onlineOnlyCopy, skipOffstage: false), findsOneWidget);

      offline.value = false;
      await tester.pump();
      expect(onPressed(tester, root.id), isNotNull);
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      // Back online, not going comes first.
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominate Azul',
          hint: notGoingHint,
          isButton: true,
          hasEnabledState: true,
        ),
      );
      handle.dispose();
    });

    testWidgets("Nominate isn't built under HostOnly", (tester) async {
      await showGames(
        tester,
        detail: detailOf(policy: policyOf(GameAdditionMode.hostOnly)),
      );

      expect(row(azul.id), findsOneWidget);
      for (final game in [catanMine, azul, catanAdas, root]) {
        expect(nominate(game.id), findsNothing, reason: game.title);
      }

      // Under a vote it is.
      await tester.pumpWidget(const SizedBox());
      await showGames(
        tester,
        detail: detailOf(policy: policyOf(GameAdditionMode.requiresVote)),
      );
      expect(nominate(azul.id), findsOneWidget);

      // Nor for a guest, whose role can't nominate.
      await tester.pumpWidget(const SizedBox());
      await showGames(
        tester,
        detail: detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.guest),
        ),
      );
      expect(row(azul.id), findsOneWidget);
      expect(nominate(azul.id), findsNothing);
    });

    testWidgets('a row that supplies a live nomination shows Nominated', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        nominationOf('n-1', azul),
        nominationOf('n-2', catanAdas, status: NominationStatus.paused),
        nominationOf('n-3', root, status: NominationStatus.withdrawn),
        nominationOf('n-4', catanMine, status: NominationStatus.passed),
      ];
      // Tall enough that every row is built, below the four nominations.
      useViewSize(tester, const Size(800, 3200));

      await showGames(tester);

      expect(nominated(azul.id), findsOneWidget);
      expect(nominated(catanAdas.id), findsOneWidget);
      expect(nominated(root.id), findsNothing);
      expect(nominated(catanMine.id), findsNothing);
      // A chip's label can't wrap: it scales down instead.
      expect(
        find.descendant(
          of: nominated(azul.id),
          matching: find.byType(FittedBox),
        ),
        findsOneWidget,
      );
      // Read with the row, as its last line.
      expect(
        tester.getSemantics(
          find.descendant(of: row(azul.id), matching: find.text('Azul')),
        ),
        matchesSemantics(
          label: 'Azul\nTabletop, Physical\nAda is bringing this\nNominated',
        ),
      );
      handle.dispose();
    });

    testWidgets('waits for the nominations to be read', (tester) async {
      final handle = tester.ensureSemantics();
      final read = Completer<List<EventNomination>>();
      nominationsAnswer = (_) => read.future;
      await showGames(tester);

      // Until they are, a row's nominations aren't known: a wait, with no
      // reason to give.
      expect(onPressed(tester, azul.id), isNull);
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(tester.getSemantics(nominate(azul.id)).hint, isEmpty);
      handle.dispose();

      read.complete(const []);
      await animate(tester);
      expect(onPressed(tester, azul.id), isNotNull);
    });

    testWidgets('is disabled while a detail read runs, and while another '
        'nominations write is out', (tester) async {
      final held = Completer<EventNomination>();
      nominateAnswer = (_) => held.future;
      await showGames(tester);
      heldRead = Completer<EventSnapshot>();

      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      expect(onPressed(tester, azul.id), isNull);

      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);
      expect(onPressed(tester, azul.id), isNotNull);

      await press(tester, nominate(azul.id));
      await settle(tester);
      expect(remote.nominates, hasLength(1));
      expect(onPressed(tester, root.id), isNull);

      held.complete(nominationOf('n-1', azul));
      await animate(tester);
      expect(onPressed(tester, root.id), isNotNull);
    });

    testWidgets('keeps focus through its nominate, and after it while it '
        'holds focus, nominated', (tester) async {
      final handle = tester.ensureSemantics();
      final held = Completer<EventNomination>();
      nominateAnswer = (_) => held.future;
      await showGames(tester);
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      final focus =
          tester.widget<ButtonStyleButton>(nominate(azul.id)).focusNode!
            ..requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(remote.nominates, hasLength(1));
      expect(focus.hasPrimaryFocus, isTrue);

      held.complete(nominationOf('n-1', azul));
      await animate(tester);

      // Nominated for the one scope there is: unavailable, still focused,
      // and saying why. The new nomination above can have pushed it down.
      expect(focus.hasPrimaryFocus, isTrue);
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominate Azul',
          hint: 'Already nominated',
          isButton: true,
          hasEnabledState: true,
          isFocusable: true,
          isFocused: true,
          hasFocusAction: true,
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // A press does nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(remote.nominates, hasLength(1));

      // Once focus moves on, it is disabled.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      expect(onPressed(tester, azul.id), isNull);
      handle.dispose();
    });

    testWidgets('keeps focus through the dialog and the nominate it sends', (
      tester,
    ) async {
      final held = Completer<EventNomination>();
      nominateAnswer = (_) => held.future;
      await showGames(tester, detail: detailOf(occurrences: twoDates));
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      final focus =
          tester.widget<ButtonStyleButton>(nominate(azul.id)).focusNode!
            ..requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(confirm());
      await animate(tester);

      // The dialog hands focus back, and the nomination going out keeps it.
      expect(remote.nominates.single.occurrenceId, isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(focus.hasPrimaryFocus, isTrue);
      expect(
        find.descendant(
          of: nominate(azul.id),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      held.complete(nominationOf('n-1', azul));
      await animate(tester);

      // The dates are left: available again, and still focused.
      expect(focus.hasPrimaryFocus, isTrue);
      expect(onPressed(tester, azul.id), isNotNull);
    });

    testWidgets('a nominate re-check that fails says so in the footer', (
      tester,
    ) async {
      await showGames(tester);
      // On screen before the read starts, so the press needs no frame.
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      final detail = blocOf<EventDetailBloc>(tester);
      heldRead = Completer<EventSnapshot>();

      // A read starts, and the press lands before a frame shows it.
      detail.add(const EventDetailRetryRequested());
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      expect((detail.state as EventDetailReady).reading, isTrue);
      await tester.tap(nominate(azul.id));

      // Meanwhile a read of the pool finds the game gone.
      served = [catanMine, catanAdas, root];
      blocOf<EventGamesBloc>(tester).add(
        const EventGamesRequested('e-1', ['att-me', 'att-ada', 'att-bo']),
      );
      await settle(tester);
      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);

      expect(remote.nominates, isEmpty);
      expect(
        find.descendant(
          of: nominationsOutcome(),
          matching: find.text(
            "Azul wasn't nominated: something changed on this event first.",
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a nominate whose scope was nominated meanwhile is dropped', (
      tester,
    ) async {
      await showGames(tester);
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      heldRead = Completer<EventSnapshot>();

      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      await tester.tap(nominate(azul.id));

      // Meanwhile someone else nominates it for the whole event.
      nominationsAnswer = (_) => [nominationOf('n-1', azul)];
      blocOf<EventNominationsBloc>(
        tester,
      ).add(const EventNominationsRequested('e-1'));
      await settle(tester);
      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);

      expect(remote.nominates, isEmpty);
      expect(
        find.descendant(
          of: nominationsOutcome(),
          matching: find.text(
            "Azul wasn't nominated: something changed on this event first.",
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a nominate whose nominations were hidden meanwhile is '
        'dropped', (tester) async {
      await showGames(tester);
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      heldRead = Completer<EventSnapshot>();

      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      await tester.tap(nominate(azul.id));

      // Meanwhile a read is refused, which clears the nominations: none held
      // then says nothing of what a row supplies.
      nominationsAnswer = (_) =>
          throw const EventRemoteForbiddenException('hidden', statusCode: 403);
      blocOf<EventNominationsBloc>(
        tester,
      ).add(const EventNominationsRequested('e-1'));
      await settle(tester);
      expect(
        blocOf<EventNominationsBloc>(tester).state.load,
        EventNominationsLoad.hidden,
      );
      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);

      expect(remote.nominates, isEmpty);
      expect(
        find.descendant(
          of: nominationsOutcome(),
          matching: find.text(
            "Azul wasn't nominated: something changed on this event first.",
          ),
        ),
        findsOneWidget,
      );
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
      // Below the Nominations section (#517).
      await tester.ensureVisible(row('o-1'));
      await tester.pump();

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

    testWidgets("a nominated row whose supplier isn't going, at 320×640 and "
        '200% text: no overflow, and the guidelines pass (#517)', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final handle = tester.ensureSemantics();
      final mine = _game('o-1', 'att-me', _longTitle);
      served = [mine, azul];
      nominationsAnswer = (_) => [
        EventNomination(
          id: 'n-1',
          eventId: 'e-1',
          platformGameId: mine.platformGameId,
          gameId: mine.gameId,
          title: mine.title,
          platformName: mine.platformName,
          status: NominationStatus.paused,
          nominatedById: 'att-bo',
          suppliedFromId: mine.id,
          createdAt: kItemInstant,
        ),
      ];

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
      final nominate = find.byKey(
        EventDetailScreen.poolNominateKey('o-1'),
        skipOffstage: false,
      );
      await tester.ensureVisible(nominate);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(EventDetailScreen.poolNominatedKey('o-1')),
        findsOneWidget,
      );
      expect(
        tester.widget<ButtonStyleButton>(nominate).onPressed,
        isNull,
      );
      expect(takeBack('o-1'), findsOneWidget);
      await expectMeetsAccessibilityGuidelines(tester);
      handle.dispose();
    });

    testWidgets("taking back someone else's game at 320×640 and 200% text, "
        'with a long title: the dialog fits, the guidelines pass, and both '
        'its buttons are reached (#518)', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final handle = tester.ensureSemantics();
      final long = _game('o-9', 'att-ada', _longTitle);
      served = [catanMine, long];

      await showGames(
        tester,
        detail: detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.host),
        ),
      );
      // Far below the Nominations section (#517) at this size: built once
      // scrolled to, then brought out of the cache extent into view.
      await tester.scrollUntilVisible(
        takeBack(long.id),
        100,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await press(tester, takeBack(long.id));
      await animate(tester);

      expect(tester.takeException(), isNull);
      expect(find.text("Take $_longTitle off Ada's games?"), findsOneWidget);
      await expectMeetsAccessibilityGuidelines(tester);

      final keep = find.byKey(EventDetailScreen.poolTakeBackKeepKey);
      final confirm = find.byKey(EventDetailScreen.poolTakeBackConfirmKey);
      await tester.ensureVisible(keep);
      await tester.pump();
      expect(tester.getRect(keep).bottom, lessThanOrEqualTo(640));
      await tester.ensureVisible(confirm);
      await tester.pump();
      expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(640));
      served = [catanMine];
      await tester.tap(confirm);
      await animate(tester);

      expect(remote.takeBacks, [
        (eventId: 'e-1', attendeeId: 'att-ada', offeredGameId: 'o-9'),
      ]);
      handle.dispose();
    });

    /// Opens Filters, chooses tabletops, and closes the sheet (#851).
    Future<void> filterTabletops(WidgetTester tester) async {
      await press(tester, find.byKey(GameFilterKeys.button));
      await animate(tester);
      final tabletop = find.byKey(
        GameFilterKeys.platformType(PlatformType.tabletop),
      );
      await tester.ensureVisible(tabletop);
      await tester.pump();
      await tester.tap(tabletop);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);
    }

    for (final (name, scale) in [
      ('100%', 1.0),
      ('200%', BgeTextScale.maxScaleFactor),
    ]) {
      testWidgets('the header at 320×640 and $name text: People, Not mine and '
          'Filters fit the window in that order, with the people chosen, then '
          'the facets in use, under them (#851)', (tester) async {
        useViewSize(tester, const Size(320, 640));
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        served = [
          _game('o-1', 'att-me', 'Catan', platformType: PlatformType.tabletop),
          _game('o-2', 'att-ada', 'Azul', platformType: PlatformType.tabletop),
        ];
        await showGames(tester);
        // Below the Nominations section (#517): built once scrolled to.
        await tester.scrollUntilVisible(
          notMine(),
          100,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await press(tester, notMine());
        await tester.pump();
        await filterTabletops(tester);
        await tester.ensureVisible(people());
        await tester.pump();

        expect(tester.takeException(), isNull);
        // The content's edges, inside the page's gutters: the search field
        // spans the header's width.
        final content = tester.getRect(search());
        expect(content.left, greaterThan(0));
        expect(content.right, lessThan(320));
        final controls = [
          people(),
          notMine(),
          find.byKey(GameFilterKeys.button),
        ];
        final rects = [for (final control in controls) tester.getRect(control)];
        for (final (i, rect) in rects.indexed) {
          expect(rect.left, greaterThanOrEqualTo(content.left), reason: '$i');
          expect(rect.right, lessThanOrEqualTo(content.right), reason: '$i');
          if (i == 0) continue;
          final before = rects[i - 1];
          // On a run of its own below, or after the one before on its run.
          expect(
            rect.top >= before.bottom ||
                (rect.top == before.top && rect.left >= before.right),
            isTrue,
            reason: 'control $i follows control ${i - 1}',
          );
        }
        final person = tester.getRect(inUse('att-me'));
        final facet = tester.getRect(
          find.byKey(GameFilterKeys.inUse('platform_tabletop')),
        );
        expect(
          person.top,
          greaterThanOrEqualTo(
            rects.map((rect) => rect.bottom).reduce((a, b) => a > b ? a : b),
          ),
        );
        expect(facet.top, greaterThanOrEqualTo(person.bottom));
        expect(person.right, lessThanOrEqualTo(content.right));
        expect(facet.right, lessThanOrEqualTo(content.right));
      });
    }

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
        // Below the Nominations section (#517), and audited there.
        await tester.scrollUntilVisible(
          row(catanMine.id),
          100,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(row(catanMine.id));
        await tester.pumpAndSettle();
        expect(row(catanMine.id), findsOneWidget);
      },
    );

    auditScreen(
      "EventDetailScreen, the Games tab asking before someone else's game "
      'is taken back (#518)',
      build: (theme) => harness(
        detail: detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.host),
        ),
        theme: theme,
      ),
      arrange: (tester) async {
        cache.add(
          detailOf(
            viewer: _row('att-me', name: 'Me', role: EventRole.host),
          ),
        );
        await settle(tester);
        await settle(tester);
        await chooseGames(tester);
        // Below the Nominations section (#517).
        await tester.scrollUntilVisible(
          takeBack(azul.id),
          100,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(takeBack(azul.id));
        await tester.pumpAndSettle();
        await tester.tap(takeBack(azul.id));
        await tester.pumpAndSettle();
        expect(find.text("Take Azul off Ada's games?"), findsOneWidget);
      },
    );

    auditScreen(
      'EventDetailScreen, the Games tab with filters in use (#851)',
      build: (theme) => harness(detail: detailOf(), theme: theme),
      arrange: (tester) async {
        served = [
          _game('o-1', 'att-me', 'Catan', platformType: PlatformType.tabletop),
          _game('o-2', 'att-ada', 'Azul', platformType: PlatformType.tabletop),
        ];
        await arrangeGames(tester);
        // Below the Nominations section (#517): built once scrolled to.
        await tester.scrollUntilVisible(
          notMine(),
          100,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await press(tester, notMine());
        await tester.pump();
        await filterTabletops(tester);
        final chip = find.byKey(GameFilterKeys.inUse('platform_tabletop'));
        await tester.ensureVisible(chip);
        await tester.pumpAndSettle();
        expect(chip, findsOneWidget);
      },
    );

    auditScreen(
      'EventDetailScreen, the Games tab with Whose games open',
      build: (theme) => harness(detail: detailOf(), theme: theme),
      arrange: (tester) async {
        await arrangeGames(tester);
        await press(tester, people());
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
        // Below the Nominations section (#517), and audited there.
        await tester.ensureVisible(
          find.text('No games match', skipOffstage: false),
        );
        await tester.pumpAndSettle();
        expect(find.text('No games match'), findsOneWidget);
      },
    );

    auditScreen(
      'EventDetailScreen, the Games tab when the pool failed',
      build: (theme) => harness(detail: detailOf(), theme: theme),
      arrange: (tester) async {
        poolAnswer = (_) => throw _offline;
        await arrangeGames(tester);
        // Below the Nominations section (#517), and audited there.
        await tester.ensureVisible(
          find.text("Couldn't load the games", skipOffstage: false),
        );
        await tester.pumpAndSettle();
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
        expect(poolSpinner(), findsOneWidget);
      },
    );
  });
}
