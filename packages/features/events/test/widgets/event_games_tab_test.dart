import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
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

/// The Games tab of an event's screen (#516), on its Pool sub-tab unless a
/// test chooses Nominations (#945): when the pool is read, what it shows in
/// each state, its rows, the filter and the people sheet, Take back and its
/// outcomes in the page's footer, Take back on someone else's row and the
/// dialog it asks with (#518), the Offer games button, each row's Nominate
/// and "Nominated" marker (#517), and what follows the sub-tab chosen.
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
  /// otherwise, so the Nominations sub-tab says nothing is nominated.
  late FutureOr<List<EventNomination>> Function(String eventId)
  nominationsAnswer;

  /// What each lineup read answers (#519): the read fails, as the fake's
  /// default does, unless a test says otherwise, so the nominations stand
  /// in for the lineup.
  FutureOr<List<LineupGame>> Function(String eventId)? lineupAnswer;

  /// What each nominate answers (#517): the nomination as the server holds
  /// it, open for votes, unless a test says otherwise.
  late FutureOr<EventNomination> Function(NominateRequest request)
  nominateAnswer;

  /// What each withdrawal answers (#517): the nomination, withdrawn, as the
  /// last nominations read served it.
  late FutureOr<EventNomination> Function(WithdrawRequest request)
  withdrawAnswer;

  /// What a quick look's View game asked to open (#957): the route it was
  /// asked from, and the game's id.
  final openedGames = <(Route<Object?>?, String)>[];

  /// What View game does once it has been recorded: nothing, unless a test
  /// opens a page.
  late void Function(BuildContext context, String gameId) openGameAnswer;

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

  /// The rules [detailOf] gives `e-1` where a test gives none: none, unless
  /// a group's setUp says otherwise.
  EventPolicy? defaultPolicy;

  /// Event `e-1`, Scheduled with a date ahead, as the viewer [viewer] sees
  /// it, with [roster] on it. [occurrences] replace its one date, and
  /// [policy] is its rules, [defaultPolicy] by default. With [attending]
  /// false the viewer has no row of their own, as a household owner or admin
  /// who doesn't attend their household's event ([householdId]) has none.
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
        policy: policy ?? defaultPolicy,
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
    defaultPolicy = null;
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
    lineupAnswer = null;
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
    openedGames.clear();
    openGameAnswer = (_, _) {};
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
      lineup: (eventId) async {
        final answer = lineupAnswer;
        if (answer == null) throw UnimplementedError('no lineup answer');
        return answer(eventId);
      },
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
        onOpenGame: (context, gameId) {
          openedGames.add((ModalRoute.of(context), gameId));
          openGameAnswer(context, gameId);
        },
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

  /// One of the Games tab's sub-tabs (#945).
  Finder sectionTab(EventGamesSection which) => find.byKey(
    EventDetailScreen.sectionTabKey(which),
    skipOffstage: false,
  );

  /// Chooses the Games tab's sub-tab [which] (#945), its bar brought on
  /// screen first.
  Future<void> chooseSection(
    WidgetTester tester,
    EventGamesSection which,
  ) async {
    await tester.ensureVisible(sectionTab(which));
    await tester.pump();
    await tester.tap(sectionTab(which));
    await animate(tester);
  }

  /// Opens the Games tab on its Pool sub-tab (#945), which this suite tests:
  /// the Nominations sub-tab has a suite of its own.
  Future<void> chooseGames(WidgetTester tester) async {
    await tester.tap(tab(EventDetailTab.games));
    await animate(tester);
    await chooseSection(tester, EventGamesSection.pool);
  }

  /// Shows [detail] and opens the Games tab on Pool, with the pool's read
  /// ended.
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

  /// A row's Nominate (#517), its main action where the viewer is offered it
  /// (#946).
  Finder nominateOn(String id) =>
      find.byKey(EventDetailScreen.poolNominateKey(id), skipOffstage: false);

  /// A row's head, its cover and its lines as one button, which opens its
  /// quick look (#957).
  Finder head(String id) =>
      find.byKey(EventDetailScreen.poolRowHeadKey(id), skipOffstage: false);

  FocusNode headFocus(WidgetTester tester, String id) => tester
      .widget<InkWell>(
        find.descendant(
          of: head(id),
          matching: find.byType(InkWell, skipOffstage: false),
          skipOffstage: false,
        ),
      )
      .focusNode!;

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

  /// The pool's spinner, not the Nominations section's (#517).
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

  /// Brings [finder] on screen, then taps it: the tab bars and the pool's
  /// header above the rows can leave what a test presses below the fold.
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

  FocusNode nominateFocus(WidgetTester tester, String id) =>
      tester.widget<ButtonStyleButton>(nominateOn(id)).focusNode!;

  /// Reads the pool again, as a write from another device is found.
  Future<void> readPool(WidgetTester tester) async {
    blocOf<EventGamesBloc>(tester).add(
      const EventGamesRequested('e-1', ['att-me', 'att-ada', 'att-bo']),
    );
    await animate(tester);
    await animate(tester);
  }

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
        // Under the tab bars and the pool's header.
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

  /// A nomination by Ada of [game], open for votes.
  EventNomination nominationOf(String id, OfferedGame game) => EventNomination(
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

  Finder nomination(String id) =>
      find.byKey(EventDetailScreen.nominationRowKey(id), skipOffstage: false);

  /// The index a screen reader counts [finder]'s row by, on screen or built
  /// past its edge.
  int semanticIndexOf(WidgetTester tester, Finder finder) => tester
      .widget<IndexedSemantics>(
        find.ancestor(
          of: finder,
          matching: find.byType(IndexedSemantics, skipOffstage: false),
        ),
      )
      .index;

  /// The heading [title] on the Games tab, not a sub-tab's label of the
  /// same words (#945).
  Finder heading(String title) => find.ancestor(
    of: find.text(title, skipOffstage: false),
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && (widget.properties.header ?? false),
      description: 'a heading',
      skipOffstage: false,
    ),
  );

  group('the Nominations section (#517)', () {
    testWidgets('each sub-tab sits under the sub-tab bar: the nominations '
        'under their header, the pool under its own (#945)', (tester) async {
      nominationsAnswer = (_) => [nominationOf('n-1', azul)];
      // Tall enough that the pool's first row is built, under its header.
      useViewSize(tester, const Size(800, 2400));
      final bar = find.byKey(EventDetailScreen.sectionBarKey);
      final offer = find.byKey(
        EventDetailScreen.offerGamesKey,
        skipOffstage: false,
      );
      final filters = find.byKey(EventDetailScreen.nominationsFiltersKey);

      await showGames(tester);
      await chooseSection(tester, EventGamesSection.nominations);

      expect(
        tester.getRect(bar).bottom,
        lessThanOrEqualTo(tester.getRect(filters).top),
      );
      expect(
        tester.getRect(filters).bottom,
        lessThanOrEqualTo(tester.getRect(nomination('n-1')).top),
      );
      expect(offer, findsNothing);

      await chooseSection(tester, EventGamesSection.pool);

      expect(
        tester.getRect(bar).bottom,
        lessThanOrEqualTo(tester.getRect(offer).top),
      );
      expect(
        tester.getRect(offer).bottom,
        lessThanOrEqualTo(tester.getRect(row(catanMine.id)).top),
      );
      expect(nomination('n-1'), findsNothing);
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
      // Each on its own sub-tab (#945).
      final poolStart = titleStart(row(azul.id));
      await chooseSection(tester, EventGamesSection.nominations);
      expect(titleStart(nomination('n-1')), poolStart);
    });

    testWidgets("semanticChildCount counts the sub-tab's rows its filter "
        'keeps, each numbered from the first (#945)', (tester) async {
      nominationsAnswer = (_) => [
        nominationOf('n-1', azul),
        nominationOf('n-2', root),
      ];
      // Tall enough that every row is built, the vote under each nomination
      // included.
      useViewSize(tester, const Size(800, 2400));

      await showGames(tester);

      expect(scrollView(tester).semanticChildCount, 4);
      expect(semanticIndexOf(tester, row(catanMine.id)), 0);
      expect(semanticIndexOf(tester, row(root.id)), 3);

      // The pool narrowed: the rows it keeps.
      await tester.ensureVisible(
        find.byKey(EventDetailScreen.poolNotMineKey, skipOffstage: false),
      );
      await tester.pump();
      await tester.tap(notMine());
      await tester.pump();

      expect(scrollView(tester).semanticChildCount, 3);

      // The pool in a state of its own: no rows.
      await tester.ensureVisible(
        find.byKey(EventDetailScreen.poolSearchKey, skipOffstage: false),
      );
      await tester.pump();
      await tester.enterText(search(), 'gloomhaven');
      await tester.pump();

      expect(find.text('No games match'), findsOneWidget);
      expect(scrollView(tester).semanticChildCount, 0);

      // The nominations, numbered from their own first.
      await chooseSection(tester, EventGamesSection.nominations);

      expect(scrollView(tester).semanticChildCount, 2);
      expect(semanticIndexOf(tester, nomination('n-1')), 0);
      expect(semanticIndexOf(tester, nomination('n-2')), 1);
    });

    testWidgets('a section in a state of its own counts no rows', (
      tester,
    ) async {
      nominationsAnswer = (_) => throw _offline;

      await showGames(tester);

      // The pool's rows, numbered from its first (#945).
      expect(scrollView(tester).semanticChildCount, 4);
      expect(semanticIndexOf(tester, row(catanMine.id)), 0);

      await chooseSection(tester, EventGamesSection.nominations);

      expect(find.text("Couldn't load nominations"), findsOneWidget);
      expect(scrollView(tester).semanticChildCount, 0);
    });

    testWidgets('the two Filters buttons are named for what they filter, and '
        'differently (#919)', (tester) async {
      final handle = tester.ensureSemantics();
      useViewSize(tester, const Size(320, 640));
      nominationsAnswer = (_) => [nominationOf('n-1', azul)];
      served = [
        _game('o-1', 'att-me', 'Catan', platformType: PlatformType.tabletop),
      ];
      await showGames(tester);
      final nominations = find.byKey(EventDetailScreen.nominationsFiltersKey);
      final pool = find.byKey(GameFilterKeys.button, skipOffstage: false);
      // Each on its own sub-tab (#945): the nominations', then the pool's.
      await chooseSection(tester, EventGamesSection.nominations);
      expect(nominations, findsOneWidget);
      final nominationsLabel = tester.getSemantics(nominations).label;
      expect(nominationsLabel, 'Filters for nominations');

      await chooseSection(tester, EventGamesSection.pool);
      expect(nominations, findsNothing);
      await tester.ensureVisible(pool);
      await tester.pump();
      final unfiltered = tester.getSemantics(pool).label;
      expect(unfiltered, 'Filters for games');
      expect(unfiltered, isNot(nominationsLabel));

      await press(tester, pool);
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
      await tester.ensureVisible(pool);
      await tester.pump();

      expect(find.text('Filters (1)'), findsOneWidget);
      final filtered = tester.getSemantics(pool).label;
      expect(filtered, 'Filters (1) for games');
      expect(filtered, isNot(nominationsLabel));
      handle.dispose();
    });
  });

  group('the sub-tabs (#945)', () {
    Finder nominationsStale() =>
        find.byKey(EventDetailScreen.nominationsRefreshBannerKey);

    testWidgets("the page counts only the chosen sub-tab's rows", (
      tester,
    ) async {
      served = [catanMine, azul, root];
      nominationsAnswer = (_) => [
        nominationOf('n-1', azul),
        nominationOf('n-2', root),
      ];
      // Tall enough that every row is built.
      useViewSize(tester, const Size(800, 2400));

      await showGames(tester);

      expect(scrollView(tester).semanticChildCount, 3);
      expect(semanticIndexOf(tester, row(catanMine.id)), 0);
      expect(nomination('n-1'), findsNothing);

      await chooseSection(tester, EventGamesSection.nominations);

      expect(scrollView(tester).semanticChildCount, 2);
      expect(row(catanMine.id), findsNothing);
    });

    testWidgets('neither sub-tab draws a heading under its tab', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [nominationOf('n-1', azul)];
      final bar = find.byKey(EventDetailScreen.sectionBarKey);

      await showGames(tester);

      // Each sub-tab's label is said by its tab, chosen or not (#946): no
      // heading under the bar says it again.
      for (final section in [
        EventGamesSection.pool,
        EventGamesSection.nominations,
      ]) {
        await chooseSection(tester, section);
        expect(
          find.text('Games pool', skipOffstage: false),
          findsNothing,
          reason: section.name,
        );
        for (final label in ['Pool', 'Nominations']) {
          expect(
            find.text(label, skipOffstage: false),
            findsOneWidget,
            reason: '${section.name}: $label',
          );
          expect(
            find.descendant(
              of: bar,
              matching: find.text(label, skipOffstage: false),
            ),
            findsOneWidget,
            reason: '${section.name}: $label',
          );
          expect(
            heading(label),
            findsNothing,
            reason: '${section.name}: $label',
          );
        }
      }
      handle.dispose();
    });

    testWidgets('the stale banners follow the sub-tab', (tester) async {
      nominationsAnswer = (_) => [nominationOf('n-1', azul)];
      // With no Nominate on a host-only event, Take back is the row's own
      // main action (#946).
      await showGames(
        tester,
        detail: detailOf(policy: policyOf(GameAdditionMode.hostOnly)),
      );
      expect(nomination('n-1'), findsNothing);
      poolAnswer = (_) => throw _offline;
      nominationsAnswer = (_) => throw _offline;

      // A take-back that lands, with the read after it failing over the
      // games shown; then the nominations' read failing over theirs.
      await press(tester, takeBack(catanMine.id));
      await animate(tester);
      blocOf<EventNominationsBloc>(
        tester,
      ).add(const EventNominationsRequested('e-1'));
      await animate(tester);

      // On Pool, the pool's.
      expectInFooter(tester, outcome());
      expectInFooter(tester, stale());
      expect(nominationsStale(), findsNothing);

      // On Nominations, the nominations'.
      await chooseSection(tester, EventGamesSection.nominations);
      expectInFooter(tester, outcome());
      expect(stale(), findsNothing);
      expectInFooter(tester, nominationsStale());

      // On Details, neither: the outcome answers every tab.
      await tester.ensureVisible(
        find.byKey(
          EventDetailScreen.tabKey(EventDetailTab.details),
          skipOffstage: false,
        ),
      );
      await tester.pump();
      await tester.tap(tab(EventDetailTab.details));
      await animate(tester);
      expectInFooter(tester, outcome());
      expect(stale(), findsNothing);
      expect(nominationsStale(), findsNothing);

      // Back on Games, the sub-tab chosen, and its banner.
      await tester.tap(tab(EventDetailTab.games));
      await animate(tester);
      expect(nomination('n-1'), findsOneWidget);
      expect(stale(), findsNothing);
      expectInFooter(tester, nominationsStale());
    });
  });

  group('rows', () {
    /// What [finder] finds under offered game [id]'s row.
    Finder under(String id, Finder finder) =>
        find.descendant(of: row(id), matching: finder, skipOffstage: false);

    testWidgets('a pool row is its cover, its name, one status line and '
        'Nominate', (tester) async {
      final handle = tester.ensureSemantics();
      await showGames(tester);
      // Under the tab bars and the pool's header.
      await tester.ensureVisible(row(catanAdas.id));
      await tester.pump();

      for (final (game, who) in [
        (catanMine, "You're bringing this"),
        (catanAdas, 'Ada is bringing this'),
        (root, 'Bo is bringing this'),
      ]) {
        final reason = game.id;
        // The name once, and one line under it: who brings it (#946).
        expect(
          under(game.id, find.text(game.title, skipOffstage: false)),
          findsOneWidget,
          reason: reason,
        );
        expect(
          under(game.id, find.text(who, skipOffstage: false)),
          findsOneWidget,
          reason: reason,
        );
        // Where it's played is the quick look's (#957).
        expect(
          under(game.id, find.textContaining(game.platformName)),
          findsNothing,
          reason: reason,
        );
        // Nominate is its one main action: Take back, where the viewer may
        // take it back, is the quick look's too.
        expect(nominateOn(game.id), findsOneWidget, reason: reason);
        expect(takeBack(game.id), findsNothing, reason: reason);
        // The name, the line, and Nominate's label: nothing else to read.
        expect(
          under(game.id, find.byType(Text, skipOffstage: false)),
          findsNWidgets(3),
          reason: reason,
        );
      }
      expect(
        tester.getSemantics(
          find.descendant(of: row(catanAdas.id), matching: find.text('Catan')),
        ),
        matchesSemantics(
          label: 'Catan\nAda is bringing this',
          isButton: true,
          isFocusable: true,
          hasFocusAction: true,
          hasTapAction: true,
        ),
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

    testWidgets('a pool row where Nominate is not offered ends with Take '
        'back, where the viewer may take it back', (tester) async {
      final handle = tester.ensureSemantics();
      final anyButton = find.byWidgetPredicate(
        (widget) => widget is ButtonStyleButton,
        description: 'a button',
        skipOffstage: false,
      );

      // Nobody nominates on a host-only event, and a guest's role can't.
      for (final detail in [
        detailOf(policy: policyOf(GameAdditionMode.hostOnly)),
        detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.guest),
        ),
      ]) {
        await tester.pumpWidget(const SizedBox());
        await showGames(tester, detail: detail);

        // The viewer's own row: Take back is its main action.
        expect(nominateOn(catanMine.id), findsNothing);
        expect(takeBack(catanMine.id), findsOneWidget);
        expect(
          under(catanMine.id, find.text("You're bringing this")),
          findsOneWidget,
        );
        // Anyone else's has nothing to press but its head.
        for (final game in [azul, catanAdas, root]) {
          expect(
            under(game.id, anyButton),
            findsNothing,
            reason: game.title,
          );
        }
        // On screen, under the tab bars and the pool's header: a node
        // scrolled out of view is hidden.
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
      }
      handle.dispose();
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

    testWidgets('a focused leave-out switch is ringed (#758)', (tester) async {
      await showGames(tester);
      await tester.tap(people());
      await animate(tester);
      await tester.tap(find.byKey(EventDetailScreen.poolPersonKey('att-ada')));
      await tester.pump();

      expect(
        await keyboardFocusShowsRing(
          tester,
          find.descendant(
            of: find.byKey(EventDetailScreen.poolLeaveOutKey),
            matching: find.byType(Text),
          ),
        ),
        isTrue,
      );
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

      testWidgets("the pool's search, people and filters survive Nominations "
          'and Details (#945)', (tester) async {
        servePlatforms();
        await showGames(tester);
        await tester.enterText(search(), 'cat');
        await tester.pump();
        await choosePeople(tester, ['att-me']);
        await filterBy(tester, PlatformType.tabletop);
        expect(rowsShown(tester), ['o-1']);
        final count = find.descendant(
          of: find.byKey(EventDetailScreen.poolCountKey),
          matching: find.byType(Text),
        );
        final counted = tester.widget<Text>(count).data;
        expect(counted, '1 game of 4');

        await chooseSection(tester, EventGamesSection.nominations);
        expect(search(), findsNothing);
        await tester.ensureVisible(
          find.byKey(
            EventDetailScreen.tabKey(EventDetailTab.details),
            skipOffstage: false,
          ),
        );
        await tester.pump();
        await tester.tap(tab(EventDetailTab.details));
        await animate(tester);
        await tester.tap(tab(EventDetailTab.games));
        await animate(tester);
        // Games comes back on the sub-tab last chosen.
        expect(search(), findsNothing);
        await chooseSection(tester, EventGamesSection.pool);

        expect(tester.widget<TextField>(search()).controller!.text, 'cat');
        expect(inUse('att-me'), findsOneWidget);
        expect(filterChip('platform_tabletop'), findsOneWidget);
        expect(tester.widget<Text>(count).data, counted);
        expect(rowsShown(tester), ['o-1']);
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
    // Take back is a row's main action only where Nominate isn't (#946): on a
    // host-only event nobody is offered Nominate.
    setUp(() => defaultPolicy = policyOf(GameAdditionMode.hostOnly));

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
          label: "Catan: Seafarers\nYou're bringing this",
          isButton: true,
          isFocusable: true,
          hasFocusAction: true,
          hasTapAction: true,
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
    // Take back is a row's main action only where Nominate isn't (#946): on a
    // host-only event nobody is offered Nominate.
    setUp(() => defaultPolicy = policyOf(GameAdditionMode.hostOnly));

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

      testWidgets("to the next row's main action, its Take back", (
        tester,
      ) async {
        served = [catanMine, wingspanMine, azul];
        await showGames(tester);
        served = [wingspanMine, azul];

        await takeBackByKeyboard(tester, catanMine.id);

        expect(row(catanMine.id), findsNothing);
        expect(takeBackFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
      });

      testWidgets("to the next row's head, where it has no main action "
          '(#946)', (tester) async {
        served = [catanMine, azul, wingspanMine];
        await showGames(tester);
        served = [azul, wingspanMine];

        await takeBackByKeyboard(tester, catanMine.id);

        expect(row(catanMine.id), findsNothing);
        expect(headFocus(tester, azul.id).hasPrimaryFocus, isTrue);
      });

      testWidgets("to the previous row's, from the last", (tester) async {
        served = [azul, catanMine, wingspanMine];
        await showGames(tester);
        served = [azul, catanMine];

        await takeBackByKeyboard(tester, wingspanMine.id);

        expect(takeBackFocus(tester, catanMine.id).hasPrimaryFocus, isTrue);
      });

      testWidgets('to Offer games, from the only one', (tester) async {
        served = [catanMine];
        await showGames(tester);
        served = [];

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
        served = [catanMine, wingspanMine, azul];
        await showGames(tester);
        served = [wingspanMine, azul];
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
        served = [catanMine, wingspanMine, azul];
        await showGames(tester);
        served = [wingspanMine, azul];
        await focusNothing(tester);

        await press(tester, takeBack(catanMine.id));
        await animate(tester);
        await animate(tester);

        expect(takeBackFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
      });

      testWidgets('to the search field, from the only one, with no Offer '
          'games built', (tester) async {
        served = [catanMine];
        await showGames(tester, offers: false);
        served = [];

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
        served = [catanMine, wingspanMine, azul];
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
        served = [catanMine, wingspanMine, azul];
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
        served = [catanMine, wingspanMine, azul];
        await showGames(tester);
        poolAnswer = (_) => throw _offline;
        blocOf<EventGamesBloc>(tester).add(
          const EventGamesRequested('e-1', ['att-me', 'att-ada', 'att-bo']),
        );
        await animate(tester);
        expect(stale(), findsOneWidget);
        served = [wingspanMine, azul];
        poolAnswer = (_) => served;
        await focusNothing(tester);

        screenReaderTap(tester, 'Take back Catan');
        await animate(tester);
        await animate(tester);

        expect(row(catanMine.id), findsNothing);
        expect(takeBackFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets("from the only row, by a screen reader's activation with "
          'focus on nothing, to Offer games', (tester) async {
        final handle = tester.ensureSemantics();
        served = [catanMine];
        await showGames(tester);
        served = [];
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

      testWidgets("from the only row, by a screen reader's activation with "
          'focus on nothing, to the search field with no Offer games', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        served = [catanMine];
        await showGames(tester, offers: false);
        served = [];
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
        served = [catanMine, wingspanMine, azul];
        await showGames(tester);
        takeBackFocus(tester, catanMine.id).requestFocus();
        await tester.pump();

        // Taken back from another device: the next read of the pool, which
        // holds no control back, comes without it.
        served = [wingspanMine, azul];
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
        served = [azul, catanMine, wingspanMine];
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
        served = [azul, catanMine];
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

  group('a row that leaves while focus is in it (#946)', () {
    testWidgets("from its head, to the next row's head", (tester) async {
      served = [catanMine, azul, wingspanMine];
      await showGames(tester);
      headFocus(tester, azul.id).requestFocus();
      await tester.pump();

      served = [catanMine, wingspanMine];
      await readPool(tester);

      expect(row(azul.id), findsNothing);
      expect(headFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
    });

    testWidgets("from its Nominate, to the next row's Nominate", (
      tester,
    ) async {
      served = [catanMine, azul, wingspanMine];
      await showGames(tester);
      await tester.ensureVisible(nominateOn(azul.id));
      await tester.pump();
      nominateFocus(tester, azul.id).requestFocus();
      await tester.pump();

      served = [catanMine, wingspanMine];
      await readPool(tester);

      expect(row(azul.id), findsNothing);
      expect(nominateFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
    });

    testWidgets("from its Take back, to the next row's head where that row "
        'has no Take back', (tester) async {
      served = [catanMine, azul, wingspanMine];
      await showGames(
        tester,
        detail: detailOf(policy: policyOf(GameAdditionMode.hostOnly)),
      );
      takeBackFocus(tester, catanMine.id).requestFocus();
      await tester.pump();

      served = [azul, wingspanMine];
      await readPool(tester);

      expect(row(catanMine.id), findsNothing);
      expect(headFocus(tester, azul.id).hasPrimaryFocus, isTrue);
    });

    testWidgets('from the last row, to the head of the row before', (
      tester,
    ) async {
      served = [catanMine, azul, wingspanMine];
      await showGames(tester);
      headFocus(tester, wingspanMine.id).requestFocus();
      await tester.pump();

      served = [catanMine, azul];
      await readPool(tester);

      expect(row(wingspanMine.id), findsNothing);
      expect(headFocus(tester, azul.id).hasPrimaryFocus, isTrue);
    });

    testWidgets('from the only row, to Offer games, else the search field', (
      tester,
    ) async {
      for (final offers in [true, false]) {
        served = [azul];
        await tester.pumpWidget(const SizedBox());
        await showGames(tester, offers: offers);
        headFocus(tester, azul.id).requestFocus();
        await tester.pump();

        served = [];
        await readPool(tester);

        expect(row(azul.id), findsNothing, reason: '$offers');
        if (offers) {
          expect(
            tester
                .widget<ButtonStyleButton>(offerGames())
                .focusNode!
                .hasPrimaryFocus,
            isTrue,
          );
        } else {
          expect(offerGames(), findsNothing);
          expect(searchFocus(tester).hasPrimaryFocus, isTrue);
        }
      }
    });

    testWidgets('nowhere, while focus is outside it', (tester) async {
      served = [catanMine, azul, wingspanMine];
      await showGames(tester);
      headFocus(tester, catanMine.id).requestFocus();
      await tester.pump();

      served = [catanMine, wingspanMine];
      await readPool(tester);

      expect(row(azul.id), findsNothing);
      expect(headFocus(tester, catanMine.id).hasPrimaryFocus, isTrue);
    });
  });

  group('two rows to a line in a wide window (#949)', () {
    /// The rows of [ids], as a screen reader comes to their heads.
    List<String> readingOrder(WidgetTester tester, List<String> ids) {
      final heads = {
        for (final id in ids) tester.getSemantics(head(id)).id: id,
      };
      return [
        for (final node in tester.semantics.simulatedAccessibilityTraversal())
          ?heads[node.id],
      ];
    }

    testWidgets('at expanded, pool rows go two to a line, in reading order '
        'along each line', (tester) async {
      final handle = tester.ensureSemantics();
      useViewSize(tester, const Size(1280, 900));
      served = [catanMine, azul, catanAdas, root, wingspanMine];
      await showGames(tester);

      final first = tester.getRect(row(catanMine.id));
      final second = tester.getRect(row(azul.id));
      final third = tester.getRect(row(catanAdas.id));
      final fifth = tester.getRect(row(wingspanMine.id));
      expect(second.top, first.top);
      expect(second.left, greaterThan(first.left));
      // Side by side, the same width each, a gap between them.
      expect(second.width, first.width);
      expect(second.left - first.right, BgeTokens.standard.spaceMd);
      // The next line under the taller of the two, from the same edge.
      expect(third.top, greaterThanOrEqualTo(first.bottom));
      expect(third.top, greaterThanOrEqualTo(second.bottom));
      expect(third.left, first.left);
      // The last, alone on its line, keeps a row's width.
      expect(fifth.left, first.left);
      expect(fifth.width, first.width);
      expect(
        readingOrder(tester, [
          for (final game in [catanMine, azul, catanAdas, root, wingspanMine])
            game.id,
        ]),
        [catanMine.id, azul.id, catanAdas.id, root.id, wingspanMine.id],
      );
      handle.dispose();
    });

    testWidgets('at medium, one row to a line', (tester) async {
      useViewSize(tester, const Size(800, 900));
      served = [catanMine, azul, catanAdas];
      await showGames(tester);

      final first = tester.getRect(row(catanMine.id));
      final second = tester.getRect(row(azul.id));
      expect(second.top, greaterThanOrEqualTo(first.bottom));
      expect(second.left, first.left);
      expect(second.width, first.width);
    });

    testWidgets('the reader counts rows, not lines', (tester) async {
      final handle = tester.ensureSemantics();
      useViewSize(tester, const Size(1280, 900));
      served = [catanMine, azul, catanAdas, root, wingspanMine];
      await showGames(tester);

      expect(scrollView(tester).semanticChildCount, 5);
      // The third row, second line: its place among the rows.
      expect(tester.getSemantics(row(catanAdas.id)).indexInParent, 2);
      expect(tester.getSemantics(row(azul.id)).indexInParent, 1);
      expect(tester.getSemantics(row(wingspanMine.id)).indexInParent, 4);
      handle.dispose();
    });

    testWidgets('a row that moves to the line above as one before it leaves '
        'keeps focus', (tester) async {
      final handle = tester.ensureSemantics();
      useViewSize(tester, const Size(1280, 900));
      // Take back is the main action on a host-only event (#946).
      defaultPolicy = policyOf(GameAdditionMode.hostOnly);
      served = [catanMine, azul, catanAdas, root, wingspanMine];
      await showGames(tester);
      final line = tester.getRect(row(catanAdas.id)).top;
      final focus = headFocus(tester, catanAdas.id)..requestFocus();
      await tester.pump();

      served = [azul, catanAdas, root, wingspanMine];
      await press(tester, takeBack(catanMine.id));
      await animate(tester);

      expect(remote.takeBacks, hasLength(1));
      expect(row(catanMine.id), findsNothing);
      // Second on the first line now.
      expect(tester.getRect(row(catanAdas.id)).top, lessThan(line));
      expect(focus.hasPrimaryFocus, isTrue);
      expect(
        tester.getSemantics(head(catanAdas.id)),
        isSemantics(isFocused: true),
      );
      handle.dispose();
    });

    testWidgets("a row's main action keeps focus as its row moves to the "
        'line above', (tester) async {
      useViewSize(tester, const Size(1280, 900));
      defaultPolicy = policyOf(GameAdditionMode.hostOnly);
      // The viewer's Wingspan, under their Catan, with Take back.
      served = [catanMine, azul, wingspanMine, root];
      await showGames(tester);
      final focus = takeBackFocus(tester, wingspanMine.id)..requestFocus();
      await tester.pump();

      // The take-back of the row that leaves hands focus nowhere: it isn't
      // free.
      served = [azul, wingspanMine, root];
      await press(tester, takeBack(catanMine.id));
      await animate(tester);

      expect(row(catanMine.id), findsNothing);
      expect(
        tester.getRect(row(wingspanMine.id)).top,
        tester.getRect(row(azul.id)).top,
      );
      expect(focus.hasPrimaryFocus, isTrue);
      expect(takeBackFocus(tester, wingspanMine.id), same(focus));
    });

    testWidgets('a row that leaves while its head has focus hands it to the '
        'head of the row that moves up into its place', (tester) async {
      useViewSize(tester, const Size(1280, 900));
      served = [catanMine, azul, wingspanMine, root];
      await showGames(tester);
      headFocus(tester, azul.id).requestFocus();
      await tester.pump();

      served = [catanMine, wingspanMine, root];
      await readPool(tester);

      expect(row(azul.id), findsNothing);
      // Wingspan, from the line below, beside Catan now.
      expect(
        tester.getRect(row(wingspanMine.id)).top,
        tester.getRect(row(catanMine.id)).top,
      );
      expect(headFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
    });

    testWidgets('a take-back from the keyboard hands focus to the Take back of '
        'the row that moves up into its place', (tester) async {
      useViewSize(tester, const Size(1280, 900));
      defaultPolicy = policyOf(GameAdditionMode.hostOnly);
      served = [azul, catanMine, wingspanMine, root];
      await showGames(tester);
      takeBackFocus(tester, catanMine.id).requestFocus();
      await tester.pump();

      served = [azul, wingspanMine, root];
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      await animate(tester);

      expect(remote.takeBacks, hasLength(1));
      expect(row(catanMine.id), findsNothing);
      expect(
        tester.getRect(row(wingspanMine.id)).top,
        tester.getRect(row(azul.id)).top,
      );
      expect(takeBackFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
    });

    testWidgets('a held Nominate keeps its spinner and its focus as its row '
        'moves to the line above, and its outcome lands', (tester) async {
      useViewSize(tester, const Size(1280, 900));
      final held = Completer<EventNomination>();
      nominateAnswer = (request) => held.future;
      served = [catanMine, azul, catanAdas, root];
      await showGames(tester);
      final focus = nominateFocus(tester, catanAdas.id)..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(remote.nominates, hasLength(1));
      Finder spinner() => find.descendant(
        of: nominateOn(catanAdas.id),
        matching: find.byType(CircularProgressIndicator),
      );
      expect(spinner(), findsOneWidget);

      // Another device's take-back, found by a read.
      served = [azul, catanAdas, root];
      await readPool(tester);

      expect(row(catanMine.id), findsNothing);
      expect(
        tester.getRect(row(catanAdas.id)).top,
        tester.getRect(row(azul.id)).top,
      );
      expect(spinner(), findsOneWidget);
      expect(focus.hasPrimaryFocus, isTrue);

      held.complete(
        EventNomination(
          id: 'n-1',
          eventId: 'e-1',
          platformGameId: catanAdas.platformGameId,
          gameId: catanAdas.gameId,
          title: catanAdas.title,
          platformName: catanAdas.platformName,
          status: NominationStatus.open,
          nominatedById: 'att-me',
          suppliedFromId: catanAdas.id,
          createdAt: kItemInstant,
        ),
      );
      await animate(tester);

      expect(spinner(), findsNothing);
      expect(
        find.byKey(EventDetailScreen.nominationsOutcomeKey),
        findsOneWidget,
      );
      expect(focus.hasPrimaryFocus, isTrue);
    });

    testWidgets('Tab goes along each line, then down', (tester) async {
      useViewSize(tester, const Size(1280, 900));
      served = [catanMine, azul, catanAdas, root];
      await showGames(tester);
      headFocus(tester, catanMine.id).requestFocus();
      await tester.pump();

      final walked = <FocusNode?>[];
      for (var i = 0; i < 7; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        walked.add(FocusManager.instance.primaryFocus);
      }

      // A row's head, then its Nominate; then the row beside it; then down.
      expect(walked, [
        nominateFocus(tester, catanMine.id),
        headFocus(tester, azul.id),
        nominateFocus(tester, azul.id),
        headFocus(tester, catanAdas.id),
        nominateFocus(tester, catanAdas.id),
        headFocus(tester, root.id),
        nominateFocus(tester, root.id),
      ]);
    });

    testWidgets('Details keeps the pane measure while Games goes wide', (
      tester,
    ) async {
      useViewSize(tester, const Size(1600, 900));
      served = [catanMine, azul, catanAdas];
      await show(tester);

      final bar = tester.getRect(find.byKey(EventDetailScreen.tabBarKey));
      final dates = tester.getRect(
        find.byKey(EventDetailScreen.datesKey, skipOffstage: false),
      );
      expect(dates.width, lessThanOrEqualTo(BgeTokens.standard.paneMaxWidth));
      // Centred under the bar.
      expect(dates.center.dx, closeTo(bar.center.dx, 0.5));

      await chooseGames(tester);

      // The bar stays where it was as the tabs swap.
      expect(tester.getRect(find.byKey(EventDetailScreen.tabBarKey)), bar);
      final line = tester
          .getRect(row(catanMine.id))
          .expandToInclude(tester.getRect(row(azul.id)));
      expect(line.width, greaterThan(BgeTokens.standard.paneMaxWidth));
      expect(line.width, lessThanOrEqualTo(BgeTokens.standard.wideMaxWidth));
    });
  });

  group("Take back on someone else's row (#518)", () {
    // Take back is a row's main action only where Nominate isn't (#946): on a
    // host-only event nobody is offered Nominate, the host included.
    setUp(() => defaultPolicy = policyOf(GameAdditionMode.hostOnly));

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
      // On screen, under the tab bars and the pool's header: a node scrolled
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

      testWidgets('a take-back that ends while Nominations is shown takes no '
          'focus, then or on returning to Pool (#945)', (tester) async {
        /// Chooses the sub-tab [which] from the keyboard, focused and
        /// activated with Enter, and answers its node.
        Future<FocusNode> chooseByKeyboard(EventGamesSection which) async {
          await tester.ensureVisible(sectionTab(which));
          await tester.pump();
          final node = Focus.of(tester.element(sectionTab(which)))
            ..requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await animate(tester);
          return node;
        }

        final answer = Completer<void>();
        takeBackAnswer = (_) => answer.future;
        // One nominated before the rules went host-only keeps the
        // Nominations sub-tab (#519).
        nominationsAnswer = (_) => [nominationOf('n-1', root)];
        await showGames(tester, detail: detailOf(viewer: host));
        served = [catanMine, catanAdas, root];

        await takeBackByKeyboard(tester, azul.id);
        expect(remote.takeBacks, hasLength(1));
        final nominations = await chooseByKeyboard(
          EventGamesSection.nominations,
        );
        expect(row(catanAdas.id), findsNothing);
        expect(FocusManager.instance.primaryFocus, same(nominations));

        answer.complete();
        await animate(tester);
        await animate(tester);

        expect(blocOf<EventGamesBloc>(tester).state.takingBack, isNull);
        expect(FocusManager.instance.primaryFocus, same(nominations));

        final pool = await chooseByKeyboard(EventGamesSection.pool);

        expect(row(azul.id), findsNothing);
        expect(row(catanAdas.id), findsOneWidget);
        expect(FocusManager.instance.primaryFocus, same(pool));
      });
    });
  });

  group('Offer games', () {
    // Take back, which some of these press, is a row's main action only
    // where Nominate isn't (#946): on a host-only event nobody is offered
    // Nominate.
    setUp(() => defaultPolicy = policyOf(GameAdditionMode.hostOnly));

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
    // Take back, which some of these press, is a row's main action only
    // where Nominate isn't (#946): on a host-only event nobody is offered
    // Nominate.
    setUp(() => defaultPolicy = policyOf(GameAdditionMode.hostOnly));

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
    Finder nominationsOutcome() =>
        find.byKey(EventDetailScreen.nominationsOutcomeKey);
    VoidCallback? onPressed(WidgetTester tester, String id) =>
        tester.widget<ButtonStyleButton>(nominate(id)).onPressed;

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
      // Nominated for the one choice there is: the button says so.
      expect(nominated(azul.id), findsNothing);
      expect(
        find.descendant(
          of: nominate(azul.id),
          matching: find.text('Nominated'),
        ),
        findsOneWidget,
      );
    });

    // A multi-date event has a row of dates (#1042): Nominate's scope is the
    // view's, and nothing is asked. The dialog's own suite has the choices.
    testWidgets('Nominate on a multi-date event asks nothing: it nominates '
        'for the view shown', (tester) async {
      await showGames(tester, detail: detailOf(occurrences: twoDates));

      // Friday, the next date still to come.
      await press(tester, nominate(azul.id));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.nominates, [
        (
          eventId: 'e-1',
          platformGameId: 'pg-o-2',
          suppliedFromId: 'o-2',
          occurrenceId: 'd-1',
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
          'reader', (tester) async {
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
        handle.dispose();
      });

      testWidgets('the outcome names the subtitle', (tester) async {
        served = [catanMine, seafarers];
        await showGames(tester, detail: detailOf(occurrences: twoDates));

        await press(tester, nominate(seafarers.id));
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

        // The date shown, the next to come, starts before the press, which
        // the page hasn't built again for.
        clock = now.add(const Duration(minutes: 2));
        await press(tester, nominate(seafarers.id));
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

    testWidgets('a date that starts before the press is dropped', (
      tester,
    ) async {
      final soon = confirmed(
        'd-1',
        now.add(const Duration(minutes: 1)),
      ).copyWith(eventId: 'e-1');
      await showGames(
        tester,
        detail: detailOf(occurrences: [soon, twoDates.last]),
      );
      expect(onPressed(tester, azul.id), isNotNull);

      // The date shown starts before the page is built again, and the
      // server would still take a nomination for it.
      clock = now.add(const Duration(minutes: 2));
      await press(tester, nominate(azul.id));
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

    testWidgets('a scope already nominated is taken in its view, and not in '
        "another's", (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [nominationOf('n-1', azul)];
      await showGames(tester, detail: detailOf(occurrences: twoDates));

      // Friday's view: the whole event's nomination leaves Friday to
      // nominate for.
      expect(onPressed(tester, azul.id), isNotNull);

      await chooseDate(tester, null);
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(onPressed(tester, azul.id), isNull);
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominated: Azul',
          hint: 'Already nominated',
          isButton: true,
          hasEnabledState: true,
        ),
      );

      await chooseDate(tester, 'd-1');
      await press(tester, nominate(azul.id));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.nominates.single.occurrenceId, 'd-1');
      handle.dispose();
    });

    testWidgets('with every scope taken, Nominate is disabled and says so', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        nominationOf('n-1', azul),
        nominationOf('n-2', root, occurrenceId: 'o-1'),
      ];
      // Tall enough that every pool row is built.
      useViewSize(tester, const Size(800, 2400));
      await showGames(tester);

      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(onPressed(tester, azul.id), isNull);
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominated: Azul',
          hint: 'Already nominated',
          isButton: true,
          hasEnabledState: true,
        ),
      );
      // The button already says it: the reason is not drawn again.
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
            label: 'Nominated: Azul',
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

    testWidgets('a game added directly is in the lineup, and Nominate says '
        'so', (tester) async {
      final handle = tester.ensureSemantics();
      // No nomination holds Azul: the lineup does.
      lineupAnswer = (_) => [
        LineupGame(
          id: 'l-1',
          platformGameId: azul.platformGameId,
          gameId: azul.gameId,
          title: 'Azul',
          platformName: 'Tabletop',
          role: ScheduledGameRole.primary,
          sortOrder: 0,
          suppliedById: azul.id,
          supplierAttendeeId: azul.attendeeId,
        ),
      ];
      useViewSize(tester, const Size(800, 2400));
      await showGames(tester);

      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(onPressed(tester, azul.id), isNull);
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominated: Azul',
          hint: 'Already in the lineup',
          isButton: true,
          hasEnabledState: true,
        ),
      );
      expect(onPressed(tester, root.id), isNotNull);
      handle.dispose();
    });

    testWidgets('a game in the lineup for one date is taken in its view, and '
        "not in another's", (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        nominationOf(
          'n-1',
          azul,
          occurrenceId: 'd-1',
          status: NominationStatus.passed,
        ),
      ];
      await showGames(tester, detail: detailOf(occurrences: twoDates));

      // Friday's view.
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(onPressed(tester, azul.id), isNull);
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominated: Azul',
          hint: 'Already in the lineup',
          isButton: true,
          hasEnabledState: true,
        ),
      );

      for (final id in [null, 'd-2']) {
        await chooseDate(tester, id);
        expect(onPressed(tester, azul.id), isNotNull, reason: '$id');
      }
      handle.dispose();
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
                'nominations again on the Nominations tab to check.',
            isButton: true,
            hasEnabledState: true,
          ),
          reason: game.title,
        );
      }

      // A retry that loads settles it: the Nominations sub-tab's, which
      // shows the failed read (#945).
      await chooseSection(tester, EventGamesSection.nominations);
      await press(tester, find.byKey(EventDetailScreen.nominationsRetryKey));
      await animate(tester);

      expect(reads, 3);
      await chooseSection(tester, EventGamesSection.pool);
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
      // first, as the hint; the button reads Nominated all the same.
      nominationsAnswer = (_) => [
        nominationOf('n-1', azul, status: NominationStatus.paused),
      ];
      // Tall enough that every pool row is built.
      useViewSize(tester, const Size(800, 2400));
      await showGames(tester, detail: detailOf(roster: [me, adaOut, bo]));

      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(onPressed(tester, azul.id), isNull);
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominated: Azul',
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
      expect(nominated(wingspanMine.id), findsNothing);
      expect(
        find.descendant(
          of: nominate(wingspanMine.id),
          matching: find.text('Nominated'),
        ),
        findsOneWidget,
      );
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
      // Tall enough that every row is built.
      useViewSize(tester, const Size(800, 3200));

      await showGames(tester);

      // Nominate says it, for every choice there is, so no line does.
      expect(nominated(azul.id), findsNothing);
      expect(nominated(catanAdas.id), findsNothing);
      for (final id in [azul.id, catanAdas.id]) {
        expect(onPressed(tester, id), isNull, reason: id);
      }
      // Withdrawn leaves it to nominate; passed is in the lineup, which
      // Nominate says too.
      expect(onPressed(tester, root.id), isNotNull);
      expect(onPressed(tester, catanMine.id), isNull);
      handle.dispose();
    });

    testWidgets('a row nominated for every choice reads Nominated with a '
        'check, disabled, its reason as hint, and draws no chip', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [nominationOf('n-1', azul)];
      useViewSize(tester, const Size(800, 2400));
      await showGames(tester);

      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(
        find.descendant(
          of: nominate(azul.id),
          matching: find.text('Nominated'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: nominate(azul.id),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(onPressed(tester, azul.id), isNull);
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominated: Azul',
          hint: 'Already nominated',
          isButton: true,
          hasEnabledState: true,
        ),
      );
      expect(
        find.descendant(of: row(azul.id), matching: find.byType(Chip)),
        findsNothing,
      );
      handle.dispose();
    });

    testWidgets('a game in the lineup for every choice reads Nominated, its '
        'hint saying it is in the lineup', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        nominationOf('n-1', azul, status: NominationStatus.approved),
      ];
      useViewSize(tester, const Size(800, 2400));
      await showGames(tester);

      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(
        find.descendant(
          of: nominate(azul.id),
          matching: find.text('Nominated'),
        ),
        findsOneWidget,
      );
      expect(onPressed(tester, azul.id), isNull);
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominated: Azul',
          hint: 'Already in the lineup',
          isButton: true,
          hasEnabledState: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a nominated row with a choice left says "{who} · Nominated" '
        'as its status line', (tester) async {
      final handle = tester.ensureSemantics();
      // Each for the whole event, with both dates left to nominate them for.
      nominationsAnswer = (_) => [
        nominationOf('n-1', azul),
        nominationOf('n-2', catanMine),
      ];
      useViewSize(tester, const Size(800, 2400));
      await showGames(tester, detail: detailOf(occurrences: twoDates));

      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(
        find.descendant(of: nominate(azul.id), matching: find.text('Nominate')),
        findsOneWidget,
      );
      expect(onPressed(tester, azul.id), isNotNull);
      // Who brings it and that it is nominated, as one line (#946): no line
      // of its own says Nominated.
      expect(
        tester.widget<Text>(nominated(azul.id)).data,
        'Ada is bringing this · Nominated',
      );
      expect(
        tester.widget<Text>(nominated(catanMine.id)).data,
        "You're bringing this · Nominated",
      );
      expect(
        find.descendant(of: row(azul.id), matching: find.text('Nominated')),
        findsNothing,
      );
      // Spoken with a comma, after the name.
      expect(
        tester.getSemantics(
          find.descendant(of: row(azul.id), matching: find.text('Azul')),
        ),
        matchesSemantics(
          label: 'Azul\nAda is bringing this, nominated',
          isButton: true,
          isFocusable: true,
          hasFocusAction: true,
          hasTapAction: true,
        ),
      );
      // A row that supplies none says who brings it alone.
      expect(nominated(catanAdas.id), findsNothing);
      expect(
        find.descendant(
          of: row(catanAdas.id),
          matching: find.text('Ada is bringing this', skipOffstage: false),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('where the viewer is not offered Nominate, a nominated row '
        'says Nominated in its status line', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [nominationOf('n-1', azul)];
      useViewSize(tester, const Size(800, 2400));
      await showGames(
        tester,
        detail: detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.guest),
        ),
      );

      expect(nominate(azul.id), findsNothing);
      expect(
        tester.widget<Text>(nominated(azul.id)).data,
        'Ada is bringing this · Nominated',
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
      // and saying why.
      expect(focus.hasPrimaryFocus, isTrue);
      await tester.ensureVisible(nominate(azul.id));
      await tester.pump();
      expect(
        find.descendant(
          of: nominate(azul.id),
          matching: find.text('Nominated'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: nominate(azul.id),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(nominate(azul.id)),
        matchesSemantics(
          label: 'Nominated: Azul',
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

    testWidgets('keeps focus through the nominate it sends under a date, '
        'and after it', (tester) async {
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

      // Nothing asked: the nomination going out, for Friday, keeps focus.
      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.nominates.single.occurrenceId, 'd-1');
      expect(focus.hasPrimaryFocus, isTrue);
      expect(
        find.descendant(
          of: nominate(azul.id),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      held.complete(nominationOf('n-1', azul, occurrenceId: 'd-1'));
      await animate(tester);

      // Nominated for the view's one choice, it says so and keeps focus.
      expect(focus.hasPrimaryFocus, isTrue);
      expect(
        find.descendant(
          of: nominate(azul.id),
          matching: find.text('Nominated'),
        ),
        findsOneWidget,
      );
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

  // The Pool under the row of dates (#1042): the same games in every view,
  // with each row's Nominate under the view's rules and for its scope.
  group('the date view (#1042)', () {
    /// Friday the 6th and Saturday the 7th, at seven.
    final friday = confirmed(
      'd-1',
      DateTime(2026, 11, 6, 19),
    ).copyWith(eventId: 'e-1');
    final saturday = confirmed(
      'd-2',
      DateTime(2026, 11, 7, 19),
      sortOrder: 1,
    ).copyWith(eventId: 'e-1');

    /// [occurrenceId]'s own rules (#1009): only the hosts add games.
    EventOccurrencePolicy hostOnlyOn(String occurrenceId) =>
        EventOccurrencePolicy(
          id: 'op-$occurrenceId',
          occurrenceId: occurrenceId,
          allowedCategoryIds: const [],
          allowedPlatformIds: const [],
          allowedPlatformTypes: const [],
          platformTypesUnrestricted: false,
          platformsUnrestricted: false,
          capacityUnrestricted: false,
          gameAdditionMode: GameAdditionMode.hostOnly,
          createdAt: kItemInstant,
          updatedAt: kItemInstant,
        );

    /// `e-1` on Friday and Saturday, its games needing a vote, with the
    /// dates' own rules [overrides].
    EventDetail twoDated({List<EventOccurrencePolicy> overrides = const []}) {
      final detail = detailOf(
        occurrences: [friday, saturday],
        policy: policyOf(GameAdditionMode.requiresVote),
      );
      return detail.copyWith(
        snapshot: detail.snapshot.copyWith(occurrencePolicies: overrides),
      );
    }

    /// Chooses the date [id] from the row, Every date where it is null.
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

    testWidgets('Nominate under a date nominates for that date without '
        'asking', (tester) async {
      await showGames(tester, detail: twoDated());

      // Friday, the next date still to come, opens.
      await press(tester, nominateOn(azul.id));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.nominates, [
        (
          eventId: 'e-1',
          platformGameId: 'pg-o-2',
          suppliedFromId: 'o-2',
          occurrenceId: 'd-1',
        ),
      ]);

      // Under Every date, for the whole event.
      await chooseDate(tester, null);
      await press(tester, nominateOn(root.id));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.nominates.last.occurrenceId, isNull);
      expect(remote.nominates.last.suppliedFromId, root.id);
    });

    testWidgets('a pool row under a HostOnly date offers no Nominate', (
      tester,
    ) async {
      await showGames(
        tester,
        detail: twoDated(overrides: [hostOnlyOn('d-2')]),
      );
      // Friday needs a vote.
      expect(nominateOn(azul.id), findsOneWidget);

      await chooseDate(tester, 'd-2');

      for (final game in [catanMine, azul, catanAdas, root]) {
        expect(nominateOn(game.id), findsNothing, reason: game.id);
      }
      // The viewer's own rows keep Take back as their one main action.
      expect(takeBack(catanMine.id), findsOneWidget);

      await chooseDate(tester, 'd-1');
      expect(nominateOn(azul.id), findsOneWidget);
    });

    testWidgets("an open quick look's Nominate follows a date the location "
        'names meanwhile', (tester) async {
      final quickLook = find.byKey(EventDetailScreen.quickLookKey);
      final nominateIn = find.descendant(
        of: quickLook,
        matching: find.byKey(EventDetailScreen.quickLookNominateKey),
      );
      await showGames(
        tester,
        detail: twoDated(overrides: [hostOnlyOn('d-2')]),
      );
      // Friday, which needs a vote.
      await press(tester, head(azul.id));
      await animate(tester);
      expect(nominateIn, findsOneWidget);

      // Back or Forward names Saturday, where only the hosts add games, with
      // no bloc changing.
      final controller = EventGamesTabScope.of(tester.element(quickLook));
      controller.takeDate('d-2', now: controller.clock());
      await animate(tester);

      expect(quickLook, findsOneWidget);
      expect(nominateIn, findsNothing);
    });

    testWidgets('a date started, or cancelled, has Nominate disabled, saying '
        'why', (tester) async {
      final handle = tester.ensureSemantics();
      final started = confirmed(
        'd-0',
        DateTime(2026, 10, 2, 19),
      ).copyWith(eventId: 'e-1');
      await showGames(
        tester,
        detail: detailOf(
          occurrences: [
            started,
            friday,
            saturday.copyWith(status: OccurrenceStatus.cancelled),
          ],
          policy: policyOf(GameAdditionMode.requiresVote),
        ),
      );
      VoidCallback? onPressed() =>
          tester.widget<ButtonStyleButton>(nominateOn(azul.id)).onPressed;
      expect(onPressed(), isNotNull);

      for (final id in ['d-0', 'd-2']) {
        await chooseDate(tester, id);
        await tester.ensureVisible(nominateOn(azul.id));
        await tester.pump();

        expect(onPressed(), isNull, reason: id);
        expect(
          tester.getSemantics(nominateOn(azul.id)),
          matchesSemantics(
            label: 'Nominate Azul',
            hint: 'Nominations for this date have closed',
            isButton: true,
            hasEnabledState: true,
          ),
          reason: id,
        );
      }

      // Every date still takes one, for the whole event.
      await chooseDate(tester, null);
      expect(onPressed(), isNotNull);
      handle.dispose();
    });

    testWidgets('the pool lists the same games in every view', (tester) async {
      useViewSize(tester, const Size(800, 2400));
      await showGames(
        tester,
        detail: twoDated(overrides: [hostOnlyOn('d-2')]),
      );
      final all = rowsShown(tester);
      expect(all, [catanMine.id, azul.id, catanAdas.id, root.id]);

      for (final id in [null, 'd-2', 'd-1']) {
        await chooseDate(tester, id);
        expect(rowsShown(tester), all, reason: '$id');
      }
    });

    testWidgets('a one-date event has no row, and the lists are as before', (
      tester,
    ) async {
      useViewSize(tester, const Size(800, 2400));
      lineupAnswer = (_) => [
        LineupGame(
          id: 'l-2',
          occurrenceId: 'o-1',
          platformGameId: root.platformGameId,
          gameId: root.gameId,
          title: 'Root',
          platformName: 'Tabletop',
          role: ScheduledGameRole.primary,
          sortOrder: 0,
          suppliedById: root.id,
          supplierAttendeeId: root.attendeeId,
        ),
        LineupGame(
          id: 'l-1',
          platformGameId: catanAdas.platformGameId,
          gameId: catanAdas.gameId,
          title: 'Catan',
          platformName: 'Board Game Arena',
          role: ScheduledGameRole.primary,
          sortOrder: 0,
          suppliedById: catanAdas.id,
          supplierAttendeeId: catanAdas.attendeeId,
        ),
      ];
      nominationsAnswer = (_) => [
        nominationOf('n-1', azul),
        nominationOf('n-2', wingspanMine).copyWith(occurrenceId: 'o-1'),
      ];
      await show(
        tester,
        detail: detailOf(policy: policyOf(GameAdditionMode.requiresVote)),
      );
      await tester.tap(tab(EventDetailTab.games));
      await animate(tester);

      // No row of dates over the three sub-tabs.
      expect(find.byKey(EventDetailScreen.dateChipKey(null)), findsNothing);
      expect(sectionTab(EventGamesSection.nominations), findsOneWidget);

      // Lineup: one list, the event's own first, marked, with no headings.
      Finder lineupRow(String id) =>
          find.byKey(EventDetailScreen.lineupRowKey(id), skipOffstage: false);
      expect(
        tester.getTopLeft(lineupRow('l-1')).dy,
        lessThan(tester.getTopLeft(lineupRow('l-2')).dy),
      );
      expect(
        find.descendant(
          of: lineupRow('l-1'),
          matching: find.text(
            'Primary · Ada is bringing this · Every date',
            skipOffstage: false,
          ),
          skipOffstage: false,
        ),
        findsOneWidget,
      );

      // Nominations: every one, whatever it is for, none marked.
      await chooseSection(tester, EventGamesSection.nominations);
      expect(nomination('n-1'), findsOneWidget);
      expect(nomination('n-2'), findsOneWidget);
      expect(
        find.textContaining('Every date', skipOffstage: false),
        findsNothing,
      );

      // Pool: every game, and Nominate for the whole event, asking nothing.
      await chooseSection(tester, EventGamesSection.pool);
      expect(rowsShown(tester), [catanMine.id, azul.id, catanAdas.id, root.id]);
      await press(tester, nominateOn(root.id));
      await animate(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.nominates.single.occurrenceId, isNull);
    });
  });

  group('quick look (#957)', () {
    final quickLook = find.byKey(EventDetailScreen.quickLookKey);
    Finder inQuickLook(Finder finder) =>
        find.descendant(of: quickLook, matching: finder);
    final gone = find.byKey(EventDetailScreen.quickLookGoneKey);
    final nominate = find.byKey(EventDetailScreen.quickLookNominateKey);
    final takeBackIn = find.byKey(EventDetailScreen.quickLookTakeBackKey);
    final openGame = find.byKey(EventDetailScreen.quickLookOpenGameKey);
    final anyButton = find.byWidgetPredicate(
      (widget) => widget is ButtonStyleButton,
      description: 'a button',
    );

    /// Opens [id]'s quick look with a tap on its row's head, brought on
    /// screen first.
    Future<void> openQuickLook(WidgetTester tester, String id) async {
      await press(tester, head(id));
      await animate(tester);
      expect(quickLook, findsOneWidget);
    }

    /// Closes the quick look with Escape.
    Future<void> closeQuickLook(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);
      expect(quickLook, findsNothing);
    }

    /// Starts a detail read that is held, and lets the bloc say it is
    /// reading before any frame shows it.
    Future<void> holdDetailRead(WidgetTester tester) async {
      final detail = blocOf<EventDetailBloc>(tester);
      heldRead = Completer<EventSnapshot>();
      detail.add(const EventDetailRetryRequested());
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      expect((detail.state as EventDetailReady).reading, isTrue);
    }

    Future<void> endDetailRead(WidgetTester tester) async {
      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);
      await animate(tester);
    }

    testWidgets("pressing a pool row's cover or title opens its quick look, "
        'a sheet at compact and a dialog at medium', (tester) async {
      useViewSize(tester, const Size(400, 800));
      await showGames(tester);

      // The cover.
      await tester.ensureVisible(head(catanMine.id));
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: head(catanMine.id),
          matching: find.byType(BgeThumbnail),
        ),
      );
      await animate(tester);
      expect(quickLook, findsOneWidget);
      expect(
        find.ancestor(of: quickLook, matching: find.byType(BottomSheet)),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: quickLook, matching: find.byType(Dialog)),
        findsNothing,
      );
      await closeQuickLook(tester);

      // The title.
      useViewSize(tester, const Size(700, 900));
      await tester.pump();
      await tester.ensureVisible(head(catanMine.id));
      await tester.pump();
      await tester.tap(
        find.descendant(of: head(catanMine.id), matching: find.text('Catan')),
      );
      await animate(tester);
      expect(quickLook, findsOneWidget);
      expect(
        find.ancestor(of: quickLook, matching: find.byType(Dialog)),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: quickLook, matching: find.byType(BottomSheet)),
        findsNothing,
      );
    });

    testWidgets('the quick look of an offered copy holds its name, platform '
        'and medium, who brings it, what it supplies, Nominate, Take back and '
        'View game', (tester) async {
      final handle = tester.ensureSemantics();
      final seafarers = _game('o-1', 'att-me', 'Catan', subtitle: 'Seafarers');
      served = [seafarers, azul];
      nominationsAnswer = (_) => [nominationOf('n-1', seafarers)];
      await showGames(tester);

      // The row's head is one button, named by what it shows.
      await tester.ensureVisible(head(seafarers.id));
      await tester.pump();
      expect(
        tester.getSemantics(head(seafarers.id)),
        isSemantics(
          label: "Catan: Seafarers\nYou're bringing this",
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
        ),
      );

      await openQuickLook(tester, seafarers.id);

      // Named for its game as it opens.
      expect(
        find.semantics.byPredicate(
          (node) =>
              node.label == 'Catan: Seafarers' &&
              node.getSemanticsData().flagsCollection.namesRoute,
          describeMatch: (_) => 'a route named "Catan: Seafarers"',
        ),
        findsOneWidget,
      );
      // The subtitle is in the name.
      expect(inQuickLook(find.text('Catan: Seafarers')), findsOneWidget);
      final where = inQuickLook(find.text('Tabletop · Physical'));
      expect(where, findsOneWidget);
      expect(
        tester.getSemantics(where).getSemanticsData().label,
        contains('Tabletop, Physical'),
      );
      expect(inQuickLook(find.text("You're bringing this")), findsOneWidget);
      expect(
        inQuickLook(find.text('Supplies a nomination: For the whole event')),
        findsOneWidget,
      );
      expect(inQuickLook(nominate), findsOneWidget);
      expect(inQuickLook(takeBackIn), findsOneWidget);
      expect(inQuickLook(openGame), findsOneWidget);
      expect(
        tester.getSemantics(openGame),
        isSemantics(label: 'View game: Catan: Seafarers', isButton: true),
      );
      handle.dispose();
    });

    testWidgets("where it's played, in the quick look and not on the row "
        '(#946): a digital copy, and one with no medium, its platform alone', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await showGames(tester);

      for (final (game, where, spoken) in [
        (catanAdas, 'Board Game Arena · Digital', 'Board Game Arena, Digital'),
        (root, 'Tabletop', 'Tabletop'),
      ]) {
        expect(
          find.descendant(
            of: row(game.id),
            matching: find.textContaining(game.platformName),
            skipOffstage: false,
          ),
          findsNothing,
          reason: game.id,
        );
        await openQuickLook(tester, game.id);
        final line = inQuickLook(find.text(where));
        expect(line, findsOneWidget, reason: game.id);
        expect(
          tester.getSemantics(line).getSemanticsData().label,
          contains(spoken),
          reason: game.id,
        );
        await closeQuickLook(tester);
      }
      handle.dispose();
    });

    testWidgets('it stays current: a read that changes who it supplies '
        'redraws it while it is open', (tester) async {
      await showGames(tester);
      await openQuickLook(tester, catanMine.id);
      expect(inQuickLook(find.text('Not nominated yet')), findsOneWidget);

      // Nominated by someone else meanwhile, and read again.
      nominationsAnswer = (_) => [nominationOf('n-1', catanMine)];
      blocOf<EventNominationsBloc>(
        tester,
      ).add(const EventNominationsRequested('e-1'));
      await animate(tester);

      expect(quickLook, findsOneWidget);
      expect(inQuickLook(find.text('Not nominated yet')), findsNothing);
      expect(
        inQuickLook(find.text('Supplies a nomination: For the whole event')),
        findsOneWidget,
      );
    });

    testWidgets('a take-back from it leaves it saying the copy has left, with '
        "nothing to press; closing it puts focus on the next row's head", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      served = [catanMine, azul, wingspanMine];
      await showGames(tester);
      await openQuickLook(tester, catanMine.id);
      served = [azul, wingspanMine];

      // By keyboard: the focused Take back goes with the copy, and leaves
      // focus on nothing in that frame.
      tester.widget<ButtonStyleButton>(takeBackIn).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      await animate(tester);

      expect(remote.takeBacks, hasLength(1));
      expect(row(catanMine.id), findsNothing);
      expect(inQuickLook(gone), findsOneWidget);
      expect(find.text('This copy is no longer in the pool.'), findsOneWidget);
      expect(tester.getSemantics(gone), isSemantics(isLiveRegion: true));
      // The take-back's outcome still shows under it, and its Dismiss is
      // all there is to press.
      expect(inQuickLook(outcome()), findsOneWidget);
      expect(inQuickLook(anyButton), findsOneWidget);
      expect(
        find.descendant(of: inQuickLook(outcome()), matching: anyButton),
        findsOneWidget,
      );
      // The quick look keeps the focus while it is open: the page's own
      // hand-off takes nothing from under its barrier.
      expect(headFocus(tester, azul.id).hasFocus, isFalse);
      expect(
        tester
            .widget<ButtonStyleButton>(nominateOn(azul.id))
            .focusNode!
            .hasFocus,
        isFalse,
      );

      await closeQuickLook(tester);

      expect(headFocus(tester, azul.id).hasPrimaryFocus, isTrue);
      handle.dispose();
    });

    testWidgets('a take-back from it whose answer lands after it closes, '
        "before the next frame, puts focus on the next row's head", (
      tester,
    ) async {
      final answer = Completer<void>();
      takeBackAnswer = (_) => answer.future;
      served = [catanMine, azul, wingspanMine];
      await showGames(tester);
      await openQuickLook(tester, catanMine.id);
      tester.widget<ButtonStyleButton>(takeBackIn).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(remote.takeBacks, hasLength(1));
      expect(row(catanMine.id), findsOneWidget);

      // Closed, and the close's own work done, with no frame since.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      // Then the answer lands, still before the next frame.
      served = [azul, wingspanMine];
      answer.complete();
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      await animate(tester);
      await animate(tester);

      expect(quickLook, findsNothing);
      expect(row(catanMine.id), findsNothing);
      expect(headFocus(tester, azul.id).hasPrimaryFocus, isTrue);
    });

    testWidgets("another user's take-back, read while it is open, does the "
        'same', (tester) async {
      served = [catanMine, azul, wingspanMine];
      await showGames(tester);
      await openQuickLook(tester, azul.id);

      // Taken back from another device: the next read comes without it.
      served = [catanMine, wingspanMine];
      blocOf<EventGamesBloc>(tester).add(
        const EventGamesRequested('e-1', ['att-me', 'att-ada', 'att-bo']),
      );
      await animate(tester);

      expect(remote.takeBacks, isEmpty);
      expect(row(azul.id), findsNothing);
      expect(inQuickLook(gone), findsOneWidget);
      expect(inQuickLook(anyButton), findsNothing);

      await closeQuickLook(tester);

      expect(headFocus(tester, wingspanMine.id).hasPrimaryFocus, isTrue);
    });

    testWidgets('closing one whose copy left from the last row puts focus on '
        "the row before's head, and from the only row on Offer games, the "
        "sub-tab's first header control", (tester) async {
      served = [catanMine, azul];
      await showGames(tester);
      await openQuickLook(tester, azul.id);
      served = [catanMine];
      blocOf<EventGamesBloc>(tester).add(
        const EventGamesRequested('e-1', ['att-me', 'att-ada', 'att-bo']),
      );
      await animate(tester);
      await closeQuickLook(tester);

      expect(headFocus(tester, catanMine.id).hasPrimaryFocus, isTrue);

      await openQuickLook(tester, catanMine.id);
      served = [];
      blocOf<EventGamesBloc>(tester).add(
        const EventGamesRequested('e-1', ['att-me', 'att-ada', 'att-bo']),
      );
      await animate(tester);
      await closeQuickLook(tester);

      expect(row(catanMine.id), findsNothing);
      expect(
        tester
            .widget<ButtonStyleButton>(offerGames())
            .focusNode!
            .hasPrimaryFocus,
        isTrue,
      );
    });

    testWidgets('closing one whose copy left from the only row, with no Offer '
        'games built, puts focus on the search field', (tester) async {
      served = [catanMine];
      await showGames(tester, offers: false);
      await openQuickLook(tester, catanMine.id);
      served = [];
      blocOf<EventGamesBloc>(tester).add(
        const EventGamesRequested('e-1', ['att-me', 'att-ada', 'att-bo']),
      );
      await animate(tester);
      await closeQuickLook(tester);

      expect(offerGames(), findsNothing);
      expect(searchFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets("it moves on with the page's clock: the date shown starting "
        'while it is open closes Nominate, saying so, with no reopen', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      // The event's first date, the one its row of dates opens on (#1042),
      // starts in a minute: one of the page's time boundaries.
      final soon = confirmed(
        'd-1',
        now.add(const Duration(minutes: 1)),
      ).copyWith(eventId: 'e-1');
      final saturday = confirmed(
        'd-2',
        DateTime(2026, 11, 7, 19),
        sortOrder: 1,
      ).copyWith(eventId: 'e-1');
      await showGames(tester, detail: detailOf(occurrences: [soon, saturday]));
      await openQuickLook(tester, azul.id);
      expect(
        find.descendant(of: nominate, matching: find.text('Nominate')),
        findsOneWidget,
      );
      expect(tester.widget<ButtonStyleButton>(nominate).onPressed, isNotNull);

      // The date starts, and the page's clock passes it: no read, no write.
      clock = now.add(const Duration(minutes: 2));
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();

      expect(quickLook, findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(nominate).onPressed, isNull);
      expect(
        tester.getSemantics(nominate),
        matchesSemantics(
          label: 'Nominate Azul',
          hint: 'Nominations for this date have closed',
          isButton: true,
          hasEnabledState: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a write from it says its outcome inside the pop-up, once; an '
        'outcome showing when it opened is not repeated', (tester) async {
      takeBackAnswer = (_) => throw const EventWriteConflictException(
        'supplies',
        statusCode: 409,
      );
      served = [catanMine, wingspanMine];
      // With no Nominate on a host-only event, Take back is the row's own
      // main action (#946).
      await showGames(
        tester,
        detail: detailOf(policy: policyOf(GameAdditionMode.hostOnly)),
      );
      // An outcome in the footer as the quick look opens.
      await press(tester, takeBack(wingspanMine.id));
      await animate(tester);
      expect(outcome(), findsOneWidget);

      await openQuickLook(tester, catanMine.id);
      expect(inQuickLook(outcome()), findsNothing);

      await tester.tap(takeBackIn);
      await animate(tester);

      expect(remote.takeBacks, hasLength(2));
      expect(inQuickLook(outcome()), findsOneWidget);
      expect(
        find.descendant(
          of: inQuickLook(outcome()),
          matching: find.text(_stillSuppliesCopy),
        ),
        findsOneWidget,
      );
    });

    testWidgets("the footer's banner of an outcome said in it is no live "
        'region, while it is open or after it closes', (tester) async {
      final handle = tester.ensureSemantics();
      takeBackAnswer = (_) => throw const EventWriteConflictException(
        'supplies',
        statusCode: 409,
      );
      served = [catanMine, wingspanMine];
      await showGames(
        tester,
        detail: detailOf(policy: policyOf(GameAdditionMode.hostOnly)),
      );
      final inFooter = find.descendant(
        of: find.byType(EventGamesFooter),
        matching: outcome(),
      );
      BgeInlineBanner banner(Finder finder) =>
          tester.widget<BgeInlineBanner>(finder);
      // The banner's message, icon and text, whose node the live region is.
      final message = find.descendant(
        of: inFooter,
        matching: find.byType(Icon),
      );
      // One that lands with no quick look open is a live region.
      await press(tester, takeBack(wingspanMine.id));
      await animate(tester);
      expect(banner(inFooter).announce, isTrue);
      expect(tester.getSemantics(message), isSemantics(isLiveRegion: true));

      await openQuickLook(tester, catanMine.id);
      await tester.tap(takeBackIn);
      await animate(tester);

      // Said in the quick look, and only there.
      expect(banner(inQuickLook(outcome())).announce, isTrue);
      expect(banner(inFooter).announce, isFalse);

      await closeQuickLook(tester);

      // Back in the tree as the barrier lifts, it isn't read out again.
      expect(banner(inFooter).announce, isFalse);
      expect(
        tester.getSemantics(message),
        isNot(isSemantics(isLiveRegion: true)),
      );
      handle.dispose();
    });

    testWidgets('what it supplies names a date the event no longer has as '
        'gone, once however many there are', (tester) async {
      served = [catanMine, azul];
      nominationsAnswer = (_) => [
        nominationOf('n-1', catanMine),
        nominationOf('n-2', catanMine).copyWith(occurrenceId: 'd-gone'),
        nominationOf('n-3', catanMine).copyWith(occurrenceId: 'd-gone-too'),
        nominationOf('n-4', azul).copyWith(occurrenceId: 'd-gone'),
      ];
      await showGames(tester);

      await openQuickLook(tester, catanMine.id);
      expect(
        inQuickLook(
          find.text(
            'Supplies a nomination: For the whole event, '
            'For a date no longer on the event',
          ),
        ),
        findsOneWidget,
      );
      await closeQuickLook(tester);

      // Only for a date gone, it still says it is nominated.
      await openQuickLook(tester, azul.id);
      expect(
        inQuickLook(
          find.text('Supplies a nomination: For a date no longer on the event'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('View game opens the page once, however often it is pressed '
        'while the page arrives', (tester) async {
      await showGames(tester);
      await openQuickLook(tester, catanMine.id);

      await tester.tap(openGame);
      await tester.pump();
      await tester.tap(openGame);
      await tester.pump();

      expect(openedGames, hasLength(1));
    });

    testWidgets('a nominate from it says its outcome inside the pop-up: the '
        "nominations' banner", (tester) async {
      await showGames(tester);
      await openQuickLook(tester, azul.id);

      await tester.tap(nominate);
      await animate(tester);

      expect(remote.nominates, hasLength(1));
      final banner = inQuickLook(
        find.byKey(EventDetailScreen.nominationsOutcomeKey),
      );
      expect(banner, findsOneWidget);
      // The footer's of it is no live region: the quick look said it.
      expect(
        tester
            .widget<BgeInlineBanner>(
              find.descendant(
                of: find.byType(EventGamesFooter),
                matching: find.byKey(EventDetailScreen.nominationsOutcomeKey),
              ),
            )
            .announce,
        isFalse,
      );
      expect(
        find.descendant(
          of: banner,
          matching: find.text('Azul is nominated. Voting is open.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets("closed after a screen reader's tap, focus is back on the row "
        'head', (tester) async {
      final handle = tester.ensureSemantics();
      await showGames(tester);
      // Keyboard focus left on another control: the reader's tap moves none.
      peopleFocus(tester).requestFocus();
      await tester.pump();
      await tester.ensureVisible(head(catanMine.id));
      await tester.pump();

      const label = "Catan\nYou're bringing this";
      tester.semantics.tap(
        find.semantics.byPredicate(
          (node) =>
              node.getSemanticsData().label == label &&
              node.getSemanticsData().hasAction(SemanticsAction.tap),
          describeMatch: (_) => 'the row head "$label"',
        ),
      );
      await animate(tester);
      expect(quickLook, findsOneWidget);

      await closeQuickLook(tester);

      expect(headFocus(tester, catanMine.id).hasPrimaryFocus, isTrue);
      expect(
        tester.getSemantics(head(catanMine.id)),
        isSemantics(label: label, isFocused: true),
      );
      handle.dispose();
    });

    testWidgets('offline while open, its writes disable in place and one '
        'online-only note shows', (tester) async {
      final handle = tester.ensureSemantics();
      final offline = ValueNotifier<bool>(false);
      addTearDown(offline.dispose);
      await showGames(tester, offline: offline);
      await openQuickLook(tester, catanMine.id);
      final nominating = tester.element(nominate);
      final takingBack = tester.element(takeBackIn);
      expect(
        tester.widget<ButtonStyleButton>(nominate).onPressed,
        isNotNull,
      );
      expect(
        tester.widget<ButtonStyleButton>(takeBackIn).onPressed,
        isNotNull,
      );
      expect(inQuickLook(find.byType(BgeOnlineOnlyNote)), findsNothing);

      offline.value = true;
      await tester.pump();

      expect(tester.widget<ButtonStyleButton>(nominate).onPressed, isNull);
      expect(tester.widget<ButtonStyleButton>(takeBackIn).onPressed, isNull);
      // The same controls, disabled where they are.
      expect(tester.element(nominate), same(nominating));
      expect(tester.element(takeBackIn), same(takingBack));
      expect(inQuickLook(find.byType(BgeOnlineOnlyNote)), findsOneWidget);
      expect(
        tester.getSemantics(takeBackIn),
        isSemantics(label: 'Take back Catan', hint: _onlineOnlyCopy),
      );
      handle.dispose();
    });

    testWidgets("Nominate and Take back in it keep the row's rules: held "
        'through their press, sent once a detail read has ended', (
      tester,
    ) async {
      await showGames(tester);
      await openQuickLook(tester, catanMine.id);

      // A read starts, and the press lands before a frame shows it.
      await holdDetailRead(tester);
      await tester.tap(nominate);
      await tester.pump();

      expect(remote.nominates, isEmpty);
      expect(tester.widget<ButtonStyleButton>(nominate).onPressed, isNotNull);
      expect(
        find.descendant(
          of: nominate,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      await endDetailRead(tester);
      expect(remote.nominates, hasLength(1));

      await holdDetailRead(tester);
      await tester.tap(takeBackIn);
      await tester.pump();

      expect(remote.takeBacks, isEmpty);
      expect(
        tester.widget<ButtonStyleButton>(takeBackIn).onPressed,
        isNotNull,
      );
      expect(
        find.descendant(
          of: takeBackIn,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      await endDetailRead(tester);
      expect(remote.takeBacks, hasLength(1));
    });

    testWidgets("View game opens the game's page, and the quick look goes "
        'once the page has arrived', (tester) async {
      const page = Key('game page');
      openGameAnswer = (context, _) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(key: page, body: Text('The game')),
        ),
      );
      await showGames(tester);
      await openQuickLook(tester, catanMine.id);
      final popup = ModalRoute.of(tester.element(quickLook));

      await tester.tap(openGame);
      await tester.pump();

      // Asked from the quick look's own context, for the copy's game.
      expect(openedGames, [(popup, catanMine.gameId)]);
      // Still there while the page arrives over it.
      expect(
        find.byKey(EventDetailScreen.quickLookKey, skipOffstage: false),
        findsOneWidget,
      );

      await animate(tester);
      await animate(tester);

      expect(find.byKey(page), findsOneWidget);
      expect(
        find.byKey(EventDetailScreen.quickLookKey, skipOffstage: false),
        findsNothing,
      );
      // The page has the focus: the tab hands none on under it.
      expect(headFocus(tester, catanMine.id).hasFocus, isFalse);
    });

    testWidgets('at 320×640 and 200% text, the quick look and a row head lay '
        'out with no overflow', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final long = _game('o-1', 'att-me', _longTitle, subtitle: 'Seafarers');
      served = [long, azul];
      nominationsAnswer = (_) => [nominationOf('n-1', long)];

      await showGames(tester);
      await tester.ensureVisible(head(long.id));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(head(long.id)).height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );

      await openQuickLook(tester, long.id);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(openGame);
      await tester.pump();
      expect(tester.takeException(), isNull);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: inQuickLook(find.text('$_longTitle: Seafarers')),
          matching: find.byType(RichText),
        ),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
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
      // With no Nominate on a host-only event, Take back is the row's own
      // main action (#946).
      await showGames(
        tester,
        detail: detailOf(policy: policyOf(GameAdditionMode.hostOnly)),
      );
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
      // Under the tab bars and the pool's header.
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

    testWidgets('compact rows at 320×640 and 200% text, their status line '
        'saying Nominated, with Nominate or Take back as their main action: '
        'no overflow (#946)', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final mine = _game('o-1', 'att-me', _longTitle, subtitle: 'Seafarers');
      final adas = _game('o-2', 'att-ada', _longTitle);
      served = [mine, adas];
      // Each nominated for the whole event, with a date left: the status
      // line says it.
      nominationsAnswer = (_) => [
        for (final (id, game) in [('n-1', mine), ('n-2', adas)])
          EventNomination(
            id: id,
            eventId: 'e-1',
            platformGameId: game.platformGameId,
            gameId: game.gameId,
            title: game.title,
            platformName: game.platformName,
            status: NominationStatus.open,
            nominatedById: 'att-bo',
            suppliedFromId: game.id,
            createdAt: kItemInstant,
          ),
      ];
      final twoDates = [
        confirmed('d-1', DateTime(2026, 11, 6, 19)).copyWith(eventId: 'e-1'),
        confirmed(
          'd-2',
          DateTime(2026, 11, 7, 19),
          sortOrder: 1,
        ).copyWith(eventId: 'e-1'),
      ];

      for (final (policy, action) in [
        (null, nominateOn),
        (policyOf(GameAdditionMode.hostOnly), takeBack),
      ]) {
        await tester.pumpWidget(const SizedBox());
        await showGames(
          tester,
          detail: detailOf(occurrences: twoDates, policy: policy),
        );
        expect(tester.takeException(), isNull);

        for (final game in [mine, adas]) {
          await tester.scrollUntilVisible(
            row(game.id),
            100,
            scrollable: find
                .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.ensureVisible(row(game.id));
          await tester.pump();
          expect(tester.takeException(), isNull, reason: game.id);
          final line = find.byKey(EventDetailScreen.poolNominatedKey(game.id));
          expect(line, findsOneWidget, reason: game.id);
          for (final text in [line, head(game.id)]) {
            final rect = tester.getRect(text);
            expect(rect.left, greaterThanOrEqualTo(0), reason: game.id);
            expect(rect.right, lessThanOrEqualTo(320), reason: game.id);
          }
          expect(
            tester
                .renderObject<RenderParagraph>(
                  find.descendant(of: line, matching: find.byType(RichText)),
                )
                .didExceedMaxLines,
            isFalse,
            reason: game.id,
          );
        }
        // The viewer's own row's main action, on screen.
        await tester.ensureVisible(action(mine.id));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(action(mine.id)).right, lessThanOrEqualTo(320));
      }
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
      // Nominated for the one choice there is: Nominate says it.
      expect(
        find.byKey(EventDetailScreen.poolNominatedKey('o-1')),
        findsNothing,
      );
      expect(
        find.descendant(of: nominate, matching: find.text('Nominated')),
        findsOneWidget,
      );
      expect(
        tester.widget<ButtonStyleButton>(nominate).onPressed,
        isNull,
      );
      // Nominate is the row's one main action: Take back is the quick
      // look's (#946).
      expect(takeBack('o-1'), findsNothing);
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

      // A host-only event, where nobody is offered Nominate, so Take back is
      // each row's main action (#946).
      await showGames(
        tester,
        detail: detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.host),
          policy: policyOf(GameAdditionMode.hostOnly),
        ),
      );
      // Under the tab bars and the pool's header, at this size perhaps past
      // the cache extent: scrolled to, then brought into view.
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
        // Under the tab bars, at this size perhaps below the fold.
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
        // Under the tab bars and the pool's header, and audited there.
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
      // A host-only event, where nobody is offered Nominate, so Take back is
      // each row's main action (#946).
      build: (theme) => harness(
        detail: detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.host),
          policy: policyOf(GameAdditionMode.hostOnly),
        ),
        theme: theme,
      ),
      arrange: (tester) async {
        cache.add(
          detailOf(
            viewer: _row('att-me', name: 'Me', role: EventRole.host),
            policy: policyOf(GameAdditionMode.hostOnly),
          ),
        );
        await settle(tester);
        await settle(tester);
        await chooseGames(tester);
        // Under the tab bars and the pool's header.
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
        // Under the tab bars, at this size perhaps below the fold.
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
        // Under the tab bars and the pool's header, and audited there.
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
        // Under the tab bars and the pool's header, and audited there.
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
