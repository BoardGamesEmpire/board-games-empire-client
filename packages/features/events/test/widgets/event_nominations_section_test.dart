import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
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
import '../support/kept_nominations.dart';

class _MockEventRepository extends Mock implements EventRepository {}

const _offline = EventRemoteTransientException('offline');
const _onlineOnlyCopy = "Available when you're online";
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

/// A game [attendeeId] offers.
OfferedGame _game(String id, String attendeeId, String title) => OfferedGame(
  id: id,
  attendeeId: attendeeId,
  collectionId: 'col-$id',
  platformGameId: 'pg-$id',
  gameId: 'g-$id',
  title: title,
  platformName: 'Tabletop',
  medium: GameMedium.physical,
);

EventNominationVote _vote(
  String attendeeId,
  VoteType type, {
  bool eligible = true,
}) => EventNominationVote(
  id: 'v-$attendeeId',
  attendeeId: attendeeId,
  voteType: type,
  eligible: eligible,
);

/// A nomination of `e-1`, by Bo from Ada's Catan (`o-1`), for the whole
/// event and open for votes, unless a test says otherwise.
EventNomination _nomination(
  String id, {
  String title = 'Catan',
  String? subtitle,
  NominationStatus status = NominationStatus.open,
  String by = 'att-bo',
  String? username,
  String from = 'o-1',
  String? occurrenceId,
  NominationStatus? pausedFrom,
  DateTime? deadline,
  List<EventNominationVote> votes = const [],
  LineupLink? elevatedTo,
}) => EventNomination(
  id: id,
  eventId: 'e-1',
  platformGameId: 'pg-$id',
  gameId: 'g-$id',
  title: title,
  subtitle: subtitle,
  platformName: 'Tabletop',
  status: status,
  nominatedById: by,
  nominatedByUsername: username,
  suppliedFromId: from,
  occurrenceId: occurrenceId,
  pausedFrom: pausedFrom,
  votingDeadline: deadline,
  votes: votes,
  elevatedTo: elevatedTo,
  createdAt: kItemInstant,
);

/// The lineup game [id] of `e-1`, Ada's Catan (`o-1`) for the whole event,
/// put there by the nomination [nominationId] where it is given (#519).
LineupGame _lineupGame(String id, {String? nominationId}) => LineupGame(
  id: id,
  platformGameId: 'pg-$id',
  gameId: 'g-$id',
  title: 'Catan',
  platformName: 'Tabletop',
  role: ScheduledGameRole.primary,
  sortOrder: 0,
  suppliedById: 'o-1',
  supplierAttendeeId: 'att-ada',
  nominationId: nominationId,
);

/// `e-1`'s policy, weighing Interested as [weight].
EventPolicy _policy(InterestedWeight weight) => EventPolicy(
  id: 'p-1',
  eventId: 'e-1',
  allowMemberInvites: true,
  allowGuestInvites: false,
  restrictToGameCategories: false,
  requireHostApprovalToJoin: false,
  allowSpectators: false,
  strictCapacity: false,
  gameAdditionMode: GameAdditionMode.requiresVote,
  restrictToAttendeePool: false,
  voteThresholdType: VoteThresholdType.unknown,
  voteQuorumType: VoteQuorumType.unknown,
  voteEligibility: VoteEligibility.allAttendees,
  interestedWeight: weight,
  createdAt: kItemInstant,
  updatedAt: kItemInstant,
);

/// The Nominations section on an event's Games tab (#517): its states, and
/// what each row says about its game, who nominated it and whose it is, what
/// it's for, where it stands, its tally, its deadline and why it is paused.
void main() {
  // Local, as the device's clock reads it.
  final now = DateTime(2026, 10, 23, 18);

  late _MockEventRepository repository;
  late StreamController<EventDetail?> cache;
  late FakeEventRemote remote;

  /// What the fake server answered writes and single reads with, which its
  /// list reads serve.
  final kept = KeptNominations();

  /// What each pool read answers.
  late List<OfferedGame> pool;

  /// What each nominations read answers.
  late FutureOr<List<EventNomination>> Function(String eventId)
  nominationsAnswer;

  /// What each lineup read answers (#519): nothing faked, so a failed read,
  /// unless a test says otherwise.
  late FutureOr<List<LineupGame>> Function(String eventId) lineupAnswer;

  /// What each withdrawal answers: the nomination, withdrawn, unless a test
  /// says otherwise.
  late FutureOr<EventNomination> Function(WithdrawRequest request)
  withdrawAnswer;

  /// What each single nomination read answers, as a vote's follow-up read
  /// does: nothing, unless a test says otherwise.
  late FutureOr<EventNomination> Function(NominationRequest request)
  nominationAnswer;

  /// What each approval answers (#518): the nomination, approved, unless a
  /// test says otherwise.
  late FutureOr<EventNomination> Function(NominationDecisionRequest request)
  approveAnswer;

  /// What each rejection answers (#518): the nomination, rejected, unless a
  /// test says otherwise.
  late FutureOr<EventNomination> Function(NominationDecisionRequest request)
  rejectAnswer;

  /// What each resolve answers (#518): the nomination, passed, unless a test
  /// says otherwise.
  late FutureOr<ResolveAnswer> Function(NominationDecisionRequest request)
  resolveAnswer;

  /// A detail read held until a test completes it, while set.
  Completer<EventSnapshot>? heldRead;

  /// Each game page a quick look's View game asked for (#957): the route it
  /// was asked from, and the game's id.
  final openedGames = <(Route<Object?>?, String)>[];

  // The viewer, Ada, Bo and someone with no name, in the roster's order.
  final me = _row('att-me', name: 'Me');
  final ada = _row('att-ada', name: 'Ada');
  final bo = _row('att-bo', name: 'Bo');
  final unnamed = _row('att-nn');

  final catanAdas = _game('o-1', 'att-ada', 'Catan');
  final azulMine = _game('o-2', 'att-me', 'Azul');

  /// `e-1`'s one date, Friday the 6th at seven.
  final friday = confirmed(
    'd-1',
    DateTime(2026, 11, 6, 19),
  ).copyWith(eventId: 'e-1');

  /// `e-1`'s second date, where a test gives it one: Saturday the 7th.
  final saturday = confirmed(
    'd-2',
    DateTime(2026, 11, 7, 19),
    sortOrder: 1,
  ).copyWith(eventId: 'e-1');

  /// Event `e-1` as the viewer sees it, with [roster] (the viewer, Ada, Bo
  /// and someone unnamed by default) and [policy] on it, and on the
  /// household [householdId]'s events where it is given. Scheduled unless
  /// [status] says otherwise, on [dates], Friday alone unless a test gives
  /// others.
  EventDetail detailOf({
    List<EventAttendee>? roster,
    EventPolicy? policy,
    EventAttendee? viewer,
    bool viewerGiven = true,
    String? householdId,
    EventStatus status = EventStatus.scheduled,
    List<EventOccurrence>? dates,
  }) => EventDetail(
    snapshot: EventSnapshot(
      event: item('e-1', title: 'Catan night').event.copyWith(
        status: status,
        householdId: householdId,
      ),
      occurrences: dates ?? [friday],
      attendees: roster ?? [me, ada, bo, unnamed],
      policy: policy,
    ),
    attendance: viewerGiven ? viewer ?? me : null,
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
    pool = [catanAdas, azulMine];
    nominationsAnswer = (_) => const [];
    lineupAnswer = (_) => throw UnimplementedError('no lineup read is faked');
    nominationAnswer = (_) =>
        throw UnimplementedError('no single nomination read is faked');
    withdrawAnswer = (request) => _nomination(
      request.nominationId,
      title: 'Azul',
      by: 'att-me',
      from: 'o-2',
      status: NominationStatus.withdrawn,
    );
    approveAnswer = (request) =>
        _nomination(request.nominationId, status: NominationStatus.approved);
    rejectAnswer = (request) =>
        _nomination(request.nominationId, status: NominationStatus.rejected);
    resolveAnswer = (request) => (
      nomination: _nomination(
        request.nominationId,
        status: NominationStatus.passed,
      ),
      resolution: const NominationResolution(
        status: NominationStatus.passed,
        forCount: 2,
        againstCount: 1,
        interestedCount: 0,
        totalVotes: 3,
        quorumMet: true,
        thresholdMet: true,
        eligibleVoterCount: 4,
      ),
    );
    heldRead = null;
    openedGames.clear();
  });

  tearDown(() {
    unawaited(cache.close());
  });

  Widget harness(
    EventDetail detail, {
    ValueListenable<bool>? offline,
    Future<HouseholdRole?> Function(String householdId)? householdRole,
  }) {
    remote = FakeEventRemote.detail(
      (_) => heldRead?.future ?? detail.snapshot,
      pool: (_) => pool,
      nominations: (eventId) async =>
          kept.over(await nominationsAnswer(eventId)),
      lineup: (eventId) => lineupAnswer(eventId),
      nomination: (request) async => kept.keep(await nominationAnswer(request)),
      voteCast: (_) {},
      withdrawn: (request) async => kept.keep(await withdrawAnswer(request)),
      approved: (request) async => kept.keep(await approveAnswer(request)),
      rejected: (request) async => kept.keep(await rejectAnswer(request)),
      resolved: (request) async {
        final answer = await resolveAnswer(request);
        kept.keep(answer.nomination);
        return answer;
      },
    );
    addTearDown(kept.clear);
    return MaterialApp(
      theme: BgeTheme.light(),
      locale: const Locale('en', 'US'),
      localizationsDelegates: const [
        ...EventsLocalizations.localizationsDelegates,
        // The Games tab's Filters, its sheet and its chips (#851).
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
        householdRole: householdRole,
        onBack: (_) {},
        onOpenGame: (context, gameId) =>
            openedGames.add((ModalRoute.of(context), gameId)),
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

  /// Shows [detail] (the viewer's, by default) and opens the Games tab, on
  /// its Nominations sub-tab (#945), with the reads that
  /// starts ended. [householdRole] answers the viewer's role in the event's
  /// household; [offline] is the connection, online where it isn't given.
  Future<void> showGames(
    WidgetTester tester, {
    EventDetail? detail,
    Future<HouseholdRole?> Function(String householdId)? householdRole,
    ValueListenable<bool>? offline,
  }) async {
    final shown = detail ?? detailOf();
    await tester.pumpWidget(
      harness(shown, householdRole: householdRole, offline: offline),
    );
    cache.add(shown);
    await settle(tester);
    await settle(tester);
    await tester.tap(
      find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
    );
    await animate(tester);
    // Games opens on Lineup (#519).
    await tester.tap(
      find.byKey(
        EventDetailScreen.sectionTabKey(EventGamesSection.nominations),
      ),
    );
    await animate(tester);
  }

  /// Chooses the Games tab's sub-tab [which] (#945), its bar brought on
  /// screen first.
  Future<void> chooseSection(
    WidgetTester tester,
    EventGamesSection which,
  ) async {
    final tab = find.byKey(
      EventDetailScreen.sectionTabKey(which),
      skipOffstage: false,
    );
    await tester.ensureVisible(tab);
    await tester.pump();
    await tester.tap(tab);
    await animate(tester);
  }

  /// The heading [title] on the Games tab, not the sub-tab of the same words
  /// above it (#945).
  Finder heading(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && (widget.properties.header ?? false),
      description: 'a heading',
    ),
  );

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
      find.byKey(EventDetailScreen.nominationRowKey(id), skipOffstage: false);
  Finder inRow(String id, String text) => find.descendant(
    of: row(id),
    matching: find.text(text, skipOffstage: false),
    skipOffstage: false,
  );
  Finder retry() => find.byKey(EventDetailScreen.nominationsRetryKey);
  Finder confirmWithdraw() => find.byKey(EventDetailScreen.withdrawConfirmKey);
  Finder keepIt() => find.byKey(EventDetailScreen.withdrawKeepKey);
  Finder outcome() => find.byKey(EventDetailScreen.nominationsOutcomeKey);

  /// Brings [finder] on screen, then taps it.
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

  /// A row's head, its cover and its line as one button, which opens its
  /// quick look (#957).
  Finder head(String id) => find.byKey(
    EventDetailScreen.nominationRowHeadKey(id),
    skipOffstage: false,
  );
  final quickLook = find.byKey(EventDetailScreen.quickLookKey);
  Finder inQuickLook(Finder finder) =>
      find.descendant(of: quickLook, matching: finder);
  Finder textIn(String text) => inQuickLook(find.text(text));

  /// The quick look's lines, every line the nomination says (#957).
  final quickLookLines = find.byKey(EventDetailScreen.quickLookLinesKey);

  // The writes a row's quick look holds, and no longer the row (#946).
  final withdrawIn = find.byKey(EventDetailScreen.quickLookWithdrawKey);
  final approveIn = find.byKey(EventDetailScreen.quickLookApproveKey);
  final rejectIn = find.byKey(EventDetailScreen.quickLookRejectKey);
  final closeVoteIn = find.byKey(EventDetailScreen.quickLookCloseVoteKey);
  final votersIn = find.byKey(EventDetailScreen.quickLookVotersKey);

  FocusNode headFocus(WidgetTester tester, String id) => tester
      .widget<InkWell>(
        find.descendant(
          of: head(id),
          matching: find.byType(InkWell, skipOffstage: false),
          skipOffstage: false,
        ),
      )
      .focusNode!;

  /// The quick look's lines, as one node.
  SemanticsNode linesNode(WidgetTester tester) =>
      tester.getSemantics(quickLookLines);

  /// Opens [id]'s quick look with a tap on its row's cover, scrolled to
  /// and brought on screen first: at 200% text the row's head can outgrow
  /// the window, and the rows above it the cache extent.
  Future<void> openQuickLook(WidgetTester tester, String id) async {
    await tester.scrollUntilVisible(
      head(id),
      100,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await press(
      tester,
      find.descendant(
        of: head(id),
        matching: find.byType(BgeThumbnail, skipOffstage: false),
        skipOffstage: false,
      ),
    );
    await animate(tester);
    expect(quickLook, findsOneWidget);
  }

  /// Closes the quick look with Escape.
  Future<void> closeQuickLook(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await animate(tester);
    expect(quickLook, findsNothing);
  }

  /// [lines] are each said in [id]'s quick look, and [absent] none: what a
  /// nomination says beyond its row's status line is its quick look's
  /// (#946, #957).
  Future<void> expectQuickLookSays(
    WidgetTester tester,
    String id,
    List<String> lines, {
    List<String> absent = const [],
  }) async {
    await openQuickLook(tester, id);
    for (final line in lines) {
      expect(textIn(line), findsOneWidget, reason: '$id: $line');
    }
    for (final line in absent) {
      expect(
        inQuickLook(find.textContaining(line)),
        findsNothing,
        reason: '$id: $line',
      );
    }
    await closeQuickLook(tester);
  }

  group('rows', () {
    testWidgets('two editions of a game read apart in the nominations list '
        '(#920)', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        _nomination('n-1', by: 'att-me'),
        _nomination('n-2', subtitle: 'Seafarers'),
      ];

      await showGames(tester);

      expect(inRow('n-1', 'Catan'), findsOneWidget);
      expect(inRow('n-2', 'Catan: Seafarers'), findsOneWidget);
      expect(
        tester.getSemantics(inRow('n-2', 'Catan: Seafarers')).label,
        startsWith('Catan: Seafarers\n'),
      );
      // The vote control names its game to a screen reader, with it.
      expect(
        find.bySemanticsLabel(RegExp(r'^For Catan: Seafarers$')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'^For Catan$')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a nomination row is its cover, its title, "Voting · 3 for · '
        '1 against · 0 interested", spoken with commas, and the vote '
        'control', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        // The viewer's own, for Friday, with a deadline: each of which the
        // quick look says (#957).
        _nomination(
          'n-1',
          by: 'att-me',
          occurrenceId: 'd-1',
          deadline: DateTime(2026, 10, 25, 20),
          votes: [
            _vote('att-ada', VoteType.forGame),
            _vote('att-bo', VoteType.forGame),
            _vote('att-nn', VoteType.forGame),
            _vote('att-me', VoteType.against),
            // Not counted: the server says this one doesn't count, and this
            // client can't read the other.
            _vote('att-zz', VoteType.forGame, eligible: false),
            _vote('att-yy', VoteType.unknown),
          ],
        ),
      ];

      await showGames(
        tester,
        detail: detailOf(policy: _policy(InterestedWeight.asFor)),
      );

      expect(inRow('n-1', 'Catan'), findsOneWidget);
      // Where it stands and its tally of the votes that count, as one line
      // (#946).
      expect(
        inRow('n-1', 'Voting · 3 for · 1 against · 0 interested'),
        findsOneWidget,
      );
      // One node, its line read without the symbols between its parts: the
      // button that opens its quick look (#957).
      expect(
        tester.getSemantics(inRow('n-1', 'Catan')),
        matchesSemantics(
          label: 'Catan\nVoting, 3 for, 1 against, 0 interested',
          isButton: true,
          isFocusable: true,
          hasFocusAction: true,
          hasTapAction: true,
        ),
      );
      // The viewer's vote under it, chosen.
      final vote = find.descendant(
        of: row('n-1'),
        matching: find.byType(SegmentedButton<VoteType>, skipOffstage: false),
        skipOffstage: false,
      );
      expect(vote, findsOneWidget);
      expect(tester.widget<SegmentedButton<VoteType>>(vote).selected, {
        VoteType.against,
      });
      // The rest is the quick look's.
      for (final line in [
        'Tabletop',
        'Nominated by you',
        "From Ada's games",
        'For Fri, Nov 6 · 7:00 PM',
        'Interested counts as For',
        'Voting closes Sun, Oct 25 · 8:00 PM',
        'Withdraw',
      ]) {
        expect(inRow('n-1', line), findsNothing, reason: line);
      }
      expect(
        find.descendant(
          of: row('n-1'),
          matching: find.textContaining('Who voted', skipOffstage: false),
          skipOffstage: false,
        ),
        findsNothing,
      );
      handle.dispose();
    });

    testWidgets("a nomination row the viewer can't vote on has no control", (
      tester,
    ) async {
      final guest = me.copyWith(role: EventRole.guest);
      final buttons = find.byWidgetPredicate(
        (widget) => widget is ButtonStyleButton || widget is SegmentedButton,
        description: 'a control',
        skipOffstage: false,
      );
      final votes = [_vote('att-ada', VoteType.forGame)];

      // Open, for a guest, whose role can't vote.
      nominationsAnswer = (_) => [_nomination('n-1', votes: votes)];
      await showGames(
        tester,
        detail: detailOf(viewer: guest, roster: [guest, ada, bo, unnamed]),
      );
      expect(
        inRow('n-1', 'Voting · 1 for · 0 against · 0 interested'),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row('n-1'), matching: buttons, skipOffstage: false),
        findsNothing,
      );

      // Decided, for a participant: votes are taken only while it is open.
      nominationsAnswer = (_) => [
        _nomination('n-1', status: NominationStatus.passed, votes: votes),
      ];
      await tester.pumpWidget(const SizedBox());
      await showGames(tester);
      expect(
        inRow('n-1', 'Passed · 1 for · 0 against · 0 interested'),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row('n-1'), matching: buttons, skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets('the header counts every row', (tester) async {
      nominationsAnswer = (_) => [
        _nomination('n-1'),
        _nomination('n-2', title: 'Azul', from: 'o-2'),
      ];

      await showGames(tester);

      expect(find.text('2 nominations'), findsOneWidget);
      // In the server's order, newest first.
      expect(
        tester.getTopLeft(row('n-1')).dy,
        lessThan(tester.getTopLeft(row('n-2')).dy),
      );
    });

    testWidgets('a nominator is named from the roster, else by their '
        'username, else as this person, in the quick look', (tester) async {
      pool = [catanAdas, azulMine, _game('o-9', 'att-nn', 'Root')];
      nominationsAnswer = (_) => [
        // The roster's name wins over the username.
        _nomination('n-1', username: 'bobby'),
        // Not on the roster.
        _nomination('n-2', by: 'att-zz', username: 'zed'),
        // On the roster with no name, and no username: as is their game.
        _nomination('n-3', title: 'Root', by: 'att-nn', from: 'o-9'),
      ];

      await showGames(tester);

      await expectQuickLookSays(tester, 'n-1', ['Nominated by Bo']);
      await expectQuickLookSays(tester, 'n-2', ['Nominated by zed']);
      await expectQuickLookSays(tester, 'n-3', [
        'Nominated by this person',
        "From this person's games",
      ]);
    });

    testWidgets("each status has its label, at the start of the row's status "
        'line', (tester) async {
      const labels = {
        NominationStatus.open: 'Voting',
        NominationStatus.awaitingApproval: 'Awaiting approval',
        NominationStatus.approved: 'Approved',
        NominationStatus.passed: 'Passed',
        NominationStatus.failed: 'Failed',
        NominationStatus.quorumNotMet: 'Quorum not met',
        NominationStatus.rejected: 'Rejected',
        NominationStatus.withdrawn: 'Withdrawn',
        NominationStatus.paused: 'Paused',
        NominationStatus.unknown: 'Unknown',
      };
      nominationsAnswer = (_) => [
        for (final status in labels.keys)
          _nomination('n-${status.name}', status: status),
      ];
      // Tall enough that every row is built.
      useViewSize(tester, const Size(800, 3200));

      await showGames(tester);

      for (final MapEntry(key: status, value: label) in labels.entries) {
        expect(
          inRow(
            'n-${status.name}',
            '$label · 0 for · 0 against · 0 interested',
          ),
          findsOneWidget,
          reason: label,
        );
      }
    });

    testWidgets('the Interested line says how the event counts it, and only '
        'where its policy is known, in the quick look', (tester) async {
      const lines = {
        InterestedWeight.asFor: 'Interested counts as For',
        InterestedWeight.asAgainst: 'Interested counts as Against',
        InterestedWeight.asAbstain: "Interested isn't counted",
      };
      nominationsAnswer = (_) => [_nomination('n-1')];

      for (final MapEntry(key: weight, value: line) in lines.entries) {
        await tester.pumpWidget(const SizedBox());
        await showGames(tester, detail: detailOf(policy: _policy(weight)));

        expect(inRow('n-1', line), findsNothing, reason: line);
        await expectQuickLookSays(tester, 'n-1', [line]);
      }

      // No policy the viewer may read, or a weight this client can't read.
      for (final detail in [
        detailOf(),
        detailOf(policy: _policy(InterestedWeight.unknown)),
      ]) {
        await tester.pumpWidget(const SizedBox());
        await showGames(tester, detail: detail);

        await expectQuickLookSays(tester, 'n-1', [], absent: ['Interested ']);
      }
    });

    testWidgets('an open nomination says when voting closes; a decided one '
        'says nothing of it, in the quick look', (tester) async {
      nominationsAnswer = (_) => [
        _nomination('n-1', deadline: DateTime(2026, 10, 25, 20)),
        _nomination(
          'n-2',
          title: 'Azul',
          from: 'o-2',
          status: NominationStatus.passed,
          deadline: DateTime(2026, 10, 22, 20),
        ),
      ];

      await showGames(tester);

      expect(
        inRow('n-1', 'Voting closes Sun, Oct 25 · 8:00 PM'),
        findsNothing,
      );
      await expectQuickLookSays(tester, 'n-1', [
        'Voting closes Sun, Oct 25 · 8:00 PM',
      ]);
      await expectQuickLookSays(
        tester,
        'n-2',
        ['Passed'],
        absent: ['close'],
      );
    });

    testWidgets('a passed deadline says it stays open until a host closes '
        'it, in the quick look', (tester) async {
      nominationsAnswer = (_) => [
        _nomination('n-1', deadline: DateTime(2026, 10, 22, 20)),
      ];

      await showGames(tester);

      // Still open: a deadline closes nothing on its own.
      expect(
        inRow('n-1', 'Voting · 0 for · 0 against · 0 interested'),
        findsOneWidget,
      );
      const stays =
          'Was due to close Thu, Oct 22 · 8:00 PM. It stays open until a host '
          'closes the vote.';
      await expectQuickLookSays(tester, 'n-1', [stays, 'Voting']);
    });

    testWidgets('a paused nomination says who left and what it goes back '
        'to, in the quick look', (tester) async {
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          status: NominationStatus.paused,
          pausedFrom: NominationStatus.open,
        ),
      ];

      await showGames(tester);

      expect(
        inRow('n-1', 'Paused · 0 for · 0 against · 0 interested'),
        findsOneWidget,
      );
      await expectQuickLookSays(tester, 'n-1', [
        'Paused',
        "Paused: Ada isn't coming. It goes back to Voting if they come back.",
      ]);
    });

    testWidgets("where voting is off, the quick look still says the viewer's "
        "vote, and when it doesn't count", (tester) async {
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          status: NominationStatus.paused,
          pausedFrom: NominationStatus.open,
          votes: [_vote('att-me', VoteType.forGame)],
        ),
        _nomination(
          'n-2',
          title: 'Azul',
          status: NominationStatus.passed,
          votes: [_vote('att-me', VoteType.against, eligible: false)],
        ),
        _nomination(
          'n-3',
          title: 'Root',
          status: NominationStatus.failed,
          votes: [_vote('att-ada', VoteType.forGame)],
        ),
        _nomination(
          'n-4',
          title: 'Ark Nova',
          votes: [_vote('att-me', VoteType.interested)],
        ),
      ];
      useViewSize(tester, const Size(800, 2400));

      await showGames(tester);

      await expectQuickLookSays(tester, 'n-1', ['Your vote: For']);
      await expectQuickLookSays(tester, 'n-2', [
        "Your vote: Against. It doesn't count.",
      ]);
      // No vote of the viewer's, nothing to say.
      await expectQuickLookSays(tester, 'n-3', [], absent: ['Your vote']);
      // Open: the control says it, chosen, and the line would say it twice.
      await expectQuickLookSays(tester, 'n-4', [], absent: ['Your vote:']);
    });

    testWidgets('a paused nomination whose supplier left names whoever '
        'brings it, in the quick look', (tester) async {
      // Their games left the pool with them.
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          from: 'o-gone',
          status: NominationStatus.paused,
          pausedFrom: NominationStatus.awaitingApproval,
        ),
      ];

      await showGames(tester);

      const paused =
          "Paused: whoever brings it isn't coming. It goes back to Awaiting "
          'approval if they come back.';
      await expectQuickLookSays(tester, 'n-1', [
        'From whoever brings it',
        paused,
      ]);
    });

    testWidgets("a paused nomination of the viewer's own game says so, and "
        'one with nothing to go back to says Unknown, in the quick look', (
      tester,
    ) async {
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          title: 'Azul',
          from: 'o-2',
          status: NominationStatus.paused,
          pausedFrom: NominationStatus.open,
        ),
        _nomination('n-2', status: NominationStatus.paused),
      ];

      await showGames(tester);

      await expectQuickLookSays(tester, 'n-1', [
        "Paused: you aren't coming. It goes back to Voting if you come back.",
      ]);
      await expectQuickLookSays(tester, 'n-2', [
        "Paused: Ada isn't coming. It goes back to Unknown if they come back.",
      ]);
    });
  });

  group('states', () {
    testWidgets('while the first read is out, the section is a spinner, with '
        'no heading over it (#946)', (tester) async {
      final read = Completer<List<EventNomination>>();
      nominationsAnswer = (_) => read.future;

      await showGames(tester);

      expect(heading('Nominations'), findsNothing);
      expect(find.bySemanticsLabel('Loading nominations'), findsOneWidget);
      // A spinner, not a row: the sub-tab holds none yet (#945).
      expect(scrollViewOf(tester).semanticChildCount, 0);

      read.complete([_nomination('n-1')]);
      await animate(tester);

      expect(find.bySemanticsLabel('Loading nominations'), findsNothing);
      expect(row('n-1'), findsOneWidget);
    });

    testWidgets('a first read that fails says so, and Try again reads again, '
        'staying in place while it runs', (tester) async {
      nominationsAnswer = (_) => throw _offline;

      await showGames(tester);

      expect(find.text("Couldn't load nominations"), findsOneWidget);
      expect(remote.nominationReads, ['e-1']);

      final read = Completer<List<EventNomination>>();
      nominationsAnswer = (_) => read.future;
      await tester.ensureVisible(retry());
      await tester.pump();
      await tester.tap(retry());
      await settle(tester);

      expect(remote.nominationReads, ['e-1', 'e-1']);
      expect(find.text("Couldn't load nominations"), findsOneWidget);
      expect(retry(), findsOneWidget);
      expect(find.bySemanticsLabel('Loading nominations'), findsNothing);

      read.complete([_nomination('n-1')]);
      await animate(tester);

      expect(find.text("Couldn't load nominations"), findsNothing);
      expect(row('n-1'), findsOneWidget);
    });

    testWidgets("nominations the server won't show say so", (tester) async {
      nominationsAnswer = (_) =>
          throw const EventRemoteForbiddenException('no', statusCode: 403);

      await showGames(tester);

      expect(find.text("Nominations aren't shown to you"), findsOneWidget);
    });

    testWidgets('none nominated says so, and points to the pool', (
      tester,
    ) async {
      await showGames(tester);

      expect(find.text('Nothing nominated yet'), findsOneWidget);
      expect(
        find.text('Nominate a game from the Pool tab.'),
        findsOneWidget,
      );
      // Nothing to count.
      expect(find.textContaining('nominations'), findsNothing);
    });

    testWidgets("none nominated, for a viewer who can't nominate, says so "
        'and points nowhere', (tester) async {
      // No row of their own on the roster, so no Nominate. (Where only the
      // hosts add games, a view with none nominated has no Nominations
      // sub-tab at all, #519.)
      await showGames(tester, detail: detailOf(viewerGiven: false));

      expect(find.text('Nothing nominated yet'), findsOneWidget);
      expect(
        find.text('Nominate a game from the Pool tab.'),
        findsNothing,
      );
    });

    testWidgets('none nominated, read again, shows no spinner meanwhile', (
      tester,
    ) async {
      await showGames(tester);
      final read = Completer<List<EventNomination>>();
      nominationsAnswer = (_) => read.future;

      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await settle(tester);

      expect(remote.nominationReads, hasLength(2));
      expect(find.bySemanticsLabel('Loading nominations'), findsNothing);
      expect(find.text('Nothing nominated yet'), findsOneWidget);

      read.complete(const []);
      await settle(tester);
    });

    // The section is all its sub-tab holds (#945), so a state fills the rest
    // of the page and centres there, as the pool's do.
    for (final (name, answer, state)
        in <(String, FutureOr<List<EventNomination>> Function(String), Type)>[
          (
            'the wait for a first read',
            (_) => Completer<List<EventNomination>>().future,
            BgeLoadingState,
          ),
          ('a first read that failed', (_) => throw _offline, BgeErrorState),
          (
            'nominations hidden',
            (_) => throw const EventRemoteForbiddenException(
              'no',
              statusCode: 403,
            ),
            BgeEmptyState,
          ),
          ('none nominated', (_) => const [], BgeEmptyState),
        ]) {
      testWidgets('$name fills the rest of the sub-tab', (tester) async {
        nominationsAnswer = answer;

        await showGames(tester);

        expect(
          find.ancestor(
            of: find.byType(state),
            matching: find.byType(BgeStateSliver),
          ),
          findsOneWidget,
        );
      });
    }

    testWidgets('nominations show where the games are hidden', (tester) async {
      // A roster read and withheld, with no row of the viewer's: nobody to
      // read the pool for. The nominations are the event's.
      nominationsAnswer = (_) => [_nomination('n-1')];

      await showGames(
        tester,
        detail: detailOf(roster: const [], viewerGiven: false),
      );

      expect(row('n-1'), findsOneWidget);
      // Nobody named, and no pool to find the game in.
      await expectQuickLookSays(tester, 'n-1', [
        'Nominated by this person',
        'From whoever brings it',
      ]);

      // The pool's own sub-tab says so (#945).
      await chooseSection(tester, EventGamesSection.pool);
      expect(find.text("The games aren't shown to you"), findsOneWidget);
    });
  });

  // Withdraw is in a nomination's quick look alone (#946, #957).
  group('Withdraw', () {
    /// The viewer's own nomination of their own Azul, open for votes, unless
    /// a test says otherwise.
    EventNomination mine({
      NominationStatus status = NominationStatus.open,
      List<EventNominationVote> votes = const [],
    }) => _nomination(
      'n-1',
      title: 'Azul',
      by: 'att-me',
      from: 'o-2',
      status: status,
      votes: votes,
    );

    FocusNode withdrawFocus(WidgetTester tester) =>
        tester.widget<ButtonStyleButton>(withdrawIn).focusNode!;

    /// [text] in the outcome banner the quick look shows.
    Finder outcomeIn(String text) => find.descendant(
      of: inQuickLook(outcome()),
      matching: find.text(text),
    );

    testWidgets("withdraw's confirm names the subtitle (#920)", (tester) async {
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          title: 'Azul',
          subtitle: 'Duel',
          by: 'att-me',
          from: 'o-2',
        ),
      ];

      await showGames(tester);
      await openQuickLook(tester, 'n-1');
      await tester.tap(withdrawIn);
      await animate(tester);

      expect(find.text('Withdraw Azul: Duel?'), findsOneWidget);

      await tester.tap(confirmWithdraw());
      await animate(tester);

      expect(outcomeIn('You withdrew Azul: Duel.'), findsOneWidget);
    });

    testWidgets('Withdraw asks first and sends on confirm', (tester) async {
      nominationsAnswer = (_) => [mine()];

      await showGames(tester);
      expect(inRow('n-1', 'Withdraw'), findsNothing);
      await openQuickLook(tester, 'n-1');
      await tester.tap(withdrawIn);
      await animate(tester);

      // It asks first, naming the game and what is lost.
      expect(remote.withdrawals, isEmpty);
      expect(find.text('Withdraw Azul?'), findsOneWidget);
      expect(
        find.text('Its votes are lost. Nominating it again starts from none.'),
        findsOneWidget,
      );
      expect(
        find.descendant(of: keepIt(), matching: find.text('Keep it')),
        findsOneWidget,
      );
      // Drawn as a destructive action.
      final confirm = tester.widget<TextButton>(confirmWithdraw());
      expect(
        confirm.style?.foregroundColor?.resolve(const {}),
        Theme.of(tester.element(confirmWithdraw())).colorScheme.error,
      );
      expect(
        find.descendant(of: confirmWithdraw(), matching: find.text('Withdraw')),
        findsOneWidget,
      );

      await tester.tap(confirmWithdraw());
      await animate(tester);

      expect(remote.withdrawals, [(eventId: 'e-1', nominationId: 'n-1')]);
      // The answer takes the nomination's place, in the quick look and on
      // the row, and both the quick look and the footer say so.
      expect(textIn('Withdrawn'), findsOneWidget);
      expect(withdrawIn, findsNothing);
      expect(outcomeIn('You withdrew Azul.'), findsOneWidget);
      await closeQuickLook(tester);
      expect(
        inRow('n-1', 'Withdrawn · 0 for · 0 against · 0 interested'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text('You withdrew Azul.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Keep it sends nothing', (tester) async {
      nominationsAnswer = (_) => [mine()];

      await showGames(tester);
      await openQuickLook(tester, 'n-1');
      final focus = withdrawFocus(tester)..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(find.text('Withdraw Azul?'), findsOneWidget);

      await tester.tap(keepIt());
      await animate(tester);

      expect(find.text('Withdraw Azul?'), findsNothing);
      expect(remote.withdrawals, isEmpty);
      expect(outcome(), findsNothing);
      expect(textIn('Voting'), findsOneWidget);
      // Back on Withdraw, which can be pressed again.
      expect(focus.hasPrimaryFocus, isTrue);
      expect(tester.widget<TextButton>(withdrawIn).onPressed, isNotNull);
    });

    testWidgets("Withdraw isn't built on someone else's nomination", (
      tester,
    ) async {
      nominationsAnswer = (_) => [
        _nomination('n-1'),
        _nomination('n-2', title: 'Azul', from: 'o-2'),
      ];

      await showGames(tester);

      for (final id in ['n-1', 'n-2']) {
        await openQuickLook(tester, id);
        expect(withdrawIn, findsNothing, reason: id);
        await closeQuickLook(tester);
      }
    });

    testWidgets("Withdraw is on the viewer's own live nominations, paused "
        'too, and on none decided or withdrawn', (tester) async {
      const offered = {
        NominationStatus.open: true,
        NominationStatus.awaitingApproval: true,
        NominationStatus.paused: true,
        NominationStatus.approved: false,
        NominationStatus.passed: false,
        NominationStatus.failed: false,
        NominationStatus.quorumNotMet: false,
        NominationStatus.rejected: false,
        NominationStatus.withdrawn: false,
        NominationStatus.unknown: false,
      };
      nominationsAnswer = (_) => [
        for (final status in offered.keys)
          _nomination(
            'n-${status.name}',
            by: 'att-me',
            status: status,
            pausedFrom: NominationStatus.open,
          ),
      ];
      // Tall enough that every row is built.
      useViewSize(tester, const Size(800, 4000));

      await showGames(tester);

      for (final MapEntry(key: status, value: built) in offered.entries) {
        await openQuickLook(tester, 'n-${status.name}');
        expect(
          withdrawIn,
          built ? findsOneWidget : findsNothing,
          reason: status.name,
        );
        await closeQuickLook(tester);
      }
    });

    testWidgets("Withdraw isn't built for a viewer who can't nominate", (
      tester,
    ) async {
      nominationsAnswer = (_) => [mine()];

      await showGames(
        tester,
        detail: detailOf(
          viewer: me.copyWith(role: EventRole.guest),
          roster: [
            me.copyWith(role: EventRole.guest),
            ada,
            bo,
            unnamed,
          ],
        ),
      );

      await openQuickLook(tester, 'n-1');
      expect(withdrawIn, findsNothing);
    });

    for (final status in [EventStatus.cancelled, EventStatus.archived]) {
      testWidgets("Withdraw isn't built on a ${status.name} event", (
        tester,
      ) async {
        nominationsAnswer = (_) => [mine()];

        await showGames(tester, detail: detailOf(status: status));

        await openQuickLook(tester, 'n-1');
        expect(withdrawIn, findsNothing);
      });
    }

    testWidgets('a withdrawal is dropped where the event was cancelled while '
        'it asked, and says so', (tester) async {
      nominationsAnswer = (_) => [mine()];

      await showGames(tester);
      await openQuickLook(tester, 'n-1');
      await tester.tap(withdrawIn);
      await animate(tester);

      // Cancelled while the dialog was open.
      cache.add(detailOf(status: EventStatus.cancelled));
      await settle(tester);
      await tester.tap(confirmWithdraw());
      await animate(tester);

      expect(remote.withdrawals, isEmpty);
      expect(
        outcomeIn(
          "Azul wasn't withdrawn: something changed on this event first.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('a withdrawal dropped by the re-check says so', (
      tester,
    ) async {
      nominationsAnswer = (_) => [mine()];

      await showGames(tester);
      await openQuickLook(tester, 'n-1');
      await tester.tap(withdrawIn);
      await animate(tester);

      // Decided while the dialog was open.
      nominationsAnswer = (_) => [mine(status: NominationStatus.passed)];
      blocOf<EventNominationsBloc>(
        tester,
      ).add(const EventNominationsRequested('e-1'));
      await settle(tester);
      await tester.tap(confirmWithdraw());
      await animate(tester);

      expect(remote.withdrawals, isEmpty);
      expect(
        outcomeIn(
          "Azul wasn't withdrawn: something changed on this event first.",
        ),
        findsOneWidget,
      );
    });

    // From the keyboard: the quick look's own suite, below.
    group('after a withdrawal, focus stays in the quick look', () {
      testWidgets("from a screen reader's activation, with focus on nothing", (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        nominationsAnswer = (_) => [mine()];

        await showGames(tester);
        await openQuickLook(tester, 'n-1');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        screenReaderTap(tester, 'Withdraw Azul');
        await animate(tester);
        screenReaderTap(tester, 'Withdraw');
        await animate(tester);

        expect(remote.withdrawals, hasLength(1));
        expect(linesNode(tester), isSemantics(isFocused: true));
        expect(
          linesNode(tester).getSemanticsData().label,
          contains('Withdrawn'),
        );
        handle.dispose();
      });

      testWidgets('not when something else took focus meanwhile', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final sent = Completer<EventNomination>();
        withdrawAnswer = (_) => sent.future;
        nominationsAnswer = (_) => [mine()];

        await showGames(tester);
        await openQuickLook(tester, 'n-1');
        await tester.tap(withdrawIn);
        await animate(tester);
        await tester.tap(confirmWithdraw());
        await animate(tester);
        final elsewhere = Focus.of(
          tester.element(
            find.descendant(
              of: find.byKey(EventDetailScreen.quickLookOpenGameKey),
              matching: find.text('View game'),
            ),
          ),
        )..requestFocus();
        await tester.pump();

        sent.complete(mine(status: NominationStatus.withdrawn));
        await animate(tester);

        expect(elsewhere.hasPrimaryFocus, isTrue);
        expect(linesNode(tester), isSemantics(isFocused: false));
        handle.dispose();
      });

      testWidgets('nowhere new when it is refused: Withdraw keeps it', (
        tester,
      ) async {
        withdrawAnswer = (_) =>
            throw const EventWriteRefusedException('no', statusCode: 403);
        nominationsAnswer = (_) => [mine()];

        await showGames(tester);
        await openQuickLook(tester, 'n-1');
        final focus = withdrawFocus(tester)..requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);
        await tester.tap(confirmWithdraw());
        await animate(tester);

        expect(remote.withdrawals, hasLength(1));
        expect(outcomeIn("You can't withdraw Azul."), findsOneWidget);
        expect(focus.hasPrimaryFocus, isTrue);
        expect(tester.widget<TextButton>(withdrawIn).onPressed, isNotNull);
      });
    });

    testWidgets('Withdraw is disabled offline, and says why once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      // Awaiting approval: no vote control, whose own note would say it.
      nominationsAnswer = (_) => [
        mine(status: NominationStatus.awaitingApproval),
      ];

      await showGames(tester, offline: offline);
      await openQuickLook(tester, 'n-1');

      expect(tester.widget<TextButton>(withdrawIn).onPressed, isNull);
      expect(
        tester.getSemantics(withdrawIn),
        isSemantics(hint: _onlineOnlyCopy, isEnabled: false),
      );
      expect(textIn(_onlineOnlyCopy), findsOneWidget);
      // The row has no write of its own to say it for (#946).
      expect(
        find.descendant(of: row('n-1'), matching: find.text(_onlineOnlyCopy)),
        findsNothing,
      );

      offline.value = false;
      await tester.pump();

      expect(textIn(_onlineOnlyCopy), findsNothing);
      expect(tester.widget<TextButton>(withdrawIn).onPressed, isNotNull);
      handle.dispose();
    });
  });

  // A host's decisions are in a nomination's quick look alone (#946, #957).
  group("a host's decisions (#518)", () {
    final host = me.copyWith(role: EventRole.host);
    final moderator = me.copyWith(role: EventRole.moderator);

    /// `e-1` as [viewer] sees it, with them on the roster in the viewer's
    /// place.
    EventDetail as(EventAttendee viewer) =>
        detailOf(viewer: viewer, roster: [viewer, ada, bo, unnamed]);

    /// Bo's Catan, awaiting approval, unless a test says otherwise.
    EventNomination catan({
      NominationStatus status = NominationStatus.awaitingApproval,
      List<EventNominationVote> votes = const [],
    }) => _nomination('n-1', status: status, votes: votes);

    Finder confirmDecision() =>
        find.byKey(EventDetailScreen.hostDecisionConfirmKey);
    Finder notYet() => find.byKey(EventDetailScreen.hostDecisionKeepKey);

    /// [text] in the outcome banner the quick look shows.
    Finder inOutcome(String text) => find.descendant(
      of: inQuickLook(outcome()),
      matching: find.text(text),
    );
    FocusNode focusOf(WidgetTester tester, Finder button) =>
        tester.widget<ButtonStyleButton>(button).focusNode!;
    VoidCallback? pressOf(WidgetTester tester, Finder button) =>
        tester.widget<TextButton>(button).onPressed;

    /// Which of the three [id]'s quick look offers, by their finders.
    Future<void> expectDecisions(
      WidgetTester tester,
      String id, {
      bool approve = false,
      bool closeVote = false,
    }) async {
      await openQuickLook(tester, id);
      expect(approveIn, approve ? findsOneWidget : findsNothing, reason: id);
      expect(rejectIn, approve ? findsOneWidget : findsNothing, reason: id);
      expect(
        closeVoteIn,
        closeVote ? findsOneWidget : findsNothing,
        reason: id,
      );
      await closeQuickLook(tester);
    }

    testWidgets('an approve outcome names the subtitle (#920)', (tester) async {
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          subtitle: 'Seafarers',
          status: NominationStatus.awaitingApproval,
        ),
      ];

      await showGames(tester, detail: as(host));
      await openQuickLook(tester, 'n-1');
      await tester.tap(approveIn);
      await animate(tester);
      expect(find.text('Approve Catan: Seafarers?'), findsOneWidget);
      await tester.tap(confirmDecision());
      await animate(tester);

      expect(
        inOutcome('Catan: Seafarers is approved and in the lineup.'),
        findsOneWidget,
      );
    });

    testWidgets('Approve asks first and sends on confirm', (tester) async {
      nominationsAnswer = (_) => [catan()];

      await showGames(tester, detail: as(host));
      expect(inRow('n-1', 'Approve'), findsNothing);
      await openQuickLook(tester, 'n-1');
      await tester.tap(approveIn);
      await animate(tester);

      // It asks first, naming the game and what follows.
      expect(remote.approvals, isEmpty);
      expect(find.text('Approve Catan?'), findsOneWidget);
      expect(
        find.text('It goes into the lineup. Nothing can take it out yet.'),
        findsOneWidget,
      );
      expect(
        find.descendant(of: notYet(), matching: find.text('Not yet')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: confirmDecision(), matching: find.text('Approve')),
        findsOneWidget,
      );
      // Not drawn as a destructive action.
      expect(tester.widget<TextButton>(confirmDecision()).style, isNull);

      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.approvals, [(eventId: 'e-1', nominationId: 'n-1')]);
      // The answer takes the nomination's place, with neither decision
      // left, and the quick look says so.
      expect(textIn('Approved'), findsOneWidget);
      expect(approveIn, findsNothing);
      expect(rejectIn, findsNothing);
      expect(
        inOutcome('Catan is approved and in the lineup.'),
        findsOneWidget,
      );
      await closeQuickLook(tester);
      expect(
        inRow('n-1', 'Approved · 0 for · 0 against · 0 interested'),
        findsOneWidget,
      );
    });

    testWidgets('Reject asks first, as a destructive action, and sends on '
        'confirm', (tester) async {
      nominationsAnswer = (_) => [catan()];

      await showGames(tester, detail: as(host));
      await openQuickLook(tester, 'n-1');
      await tester.tap(rejectIn);
      await animate(tester);

      expect(remote.rejections, isEmpty);
      expect(find.text('Reject Catan?'), findsOneWidget);
      expect(find.text("This can't be undone."), findsOneWidget);
      expect(
        find.descendant(of: notYet(), matching: find.text('Not yet')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: confirmDecision(), matching: find.text('Reject')),
        findsOneWidget,
      );
      final confirm = tester.widget<TextButton>(confirmDecision());
      expect(
        confirm.style?.foregroundColor?.resolve(const {}),
        Theme.of(tester.element(confirmDecision())).colorScheme.error,
      );

      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.rejections, [(eventId: 'e-1', nominationId: 'n-1')]);
      expect(textIn('Rejected'), findsOneWidget);
      expect(approveIn, findsNothing);
      expect(rejectIn, findsNothing);
      expect(inOutcome('Catan is rejected.'), findsOneWidget);
    });

    testWidgets("Close vote's dialog shows the counting tally", (
      tester,
    ) async {
      nominationsAnswer = (_) => [
        catan(
          status: NominationStatus.open,
          votes: [
            _vote('att-ada', VoteType.forGame),
            _vote('att-bo', VoteType.forGame),
            _vote('att-me', VoteType.against),
            _vote('att-nn', VoteType.interested),
            // Doesn't count, so isn't in the numbers.
            _vote('att-gone', VoteType.forGame, eligible: false),
          ],
        ),
      ];

      await showGames(tester, detail: as(host));
      await openQuickLook(tester, 'n-1');
      await tester.tap(closeVoteIn);
      await animate(tester);

      expect(remote.resolutions, isEmpty);
      expect(find.text('Close the vote on Catan?'), findsOneWidget);
      expect(
        find.text(
          "2 for, 1 against, 1 interested so far. The result can't be "
          'undone.',
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: notYet(), matching: find.text('Not yet')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: confirmDecision(),
          matching: find.text('Close vote'),
        ),
        findsOneWidget,
      );

      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.resolutions, [(eventId: 'e-1', nominationId: 'n-1')]);
      expect(textIn('Passed'), findsOneWidget);
      expect(closeVoteIn, findsNothing);
      // The resolve's reasons, which no later read carries.
      expect(
        inOutcome('Catan passed: 2 for, 1 against. 3 of 4 counted.'),
        findsOneWidget,
      );
    });

    testWidgets("Close vote's dialog says how the event counts Interested, "
        'as the quick look does', (tester) async {
      nominationsAnswer = (_) => [
        catan(
          status: NominationStatus.open,
          votes: [
            _vote('att-ada', VoteType.forGame),
            _vote('att-me', VoteType.against),
            _vote('att-nn', VoteType.interested),
          ],
        ),
      ];
      final roster = [host, ada, bo, unnamed];

      for (final (weight, line) in [
        (InterestedWeight.asFor, 'Interested counts as For'),
        (InterestedWeight.asAgainst, 'Interested counts as Against'),
        (InterestedWeight.asAbstain, "Interested isn't counted"),
        (InterestedWeight.unknown, null),
      ]) {
        await tester.pumpWidget(const SizedBox());
        await showGames(
          tester,
          detail: detailOf(
            viewer: host,
            roster: roster,
            policy: _policy(weight),
          ),
        );
        await openQuickLook(tester, 'n-1');
        // The quick look's line, where there is one.
        expect(
          line == null
              ? inQuickLook(find.textContaining('Interested '))
              : textIn(line),
          line == null ? findsNothing : findsOneWidget,
          reason: weight.name,
        );

        await tester.tap(closeVoteIn);
        await animate(tester);

        expect(
          find.text(
            line == null
                ? "1 for, 1 against, 1 interested so far. The result can't "
                      'be undone.'
                : '1 for, 1 against, 1 interested so far. $line. The '
                      "result can't be undone.",
          ),
          findsOneWidget,
          reason: weight.name,
        );
        await tester.tap(notYet());
        await animate(tester);
      }
      expect(remote.resolutions, isEmpty);
    });

    testWidgets('Not yet sends nothing, and puts focus back on the button', (
      tester,
    ) async {
      nominationsAnswer = (_) => [
        catan(),
        _nomination('n-2', title: 'Azul', from: 'o-2'),
      ];

      await showGames(tester, detail: as(host));
      for (final (id, button, title) in [
        ('n-1', approveIn, 'Approve Catan?'),
        ('n-1', rejectIn, 'Reject Catan?'),
        ('n-2', closeVoteIn, 'Close the vote on Azul?'),
      ]) {
        await openQuickLook(tester, id);
        final focus = focusOf(tester, button)..requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);
        expect(find.text(title), findsOneWidget);

        await tester.tap(notYet());
        await animate(tester);

        expect(find.text(title), findsNothing, reason: title);
        expect(focus.hasPrimaryFocus, isTrue, reason: title);
        expect(pressOf(tester, button), isNotNull, reason: title);
        await closeQuickLook(tester);
      }
      expect(remote.approvals, isEmpty);
      expect(remote.rejections, isEmpty);
      expect(remote.resolutions, isEmpty);
      expect(outcome(), findsNothing);
      expect(
        inRow('n-1', 'Awaiting approval · 0 for · 0 against · 0 interested'),
        findsOneWidget,
      );
      expect(
        inRow('n-2', 'Voting · 0 for · 0 against · 0 interested'),
        findsOneWidget,
      );
    });

    testWidgets('a host gets Approve and Reject while it awaits approval, '
        'Close vote while it is open, and none on any other', (tester) async {
      nominationsAnswer = (_) => [
        for (final status in NominationStatus.values)
          _nomination(
            'n-${status.name}',
            status: status,
            pausedFrom: NominationStatus.open,
          ),
      ];
      // Tall enough that every row is built.
      useViewSize(tester, const Size(800, 4000));

      await showGames(tester, detail: as(host));

      for (final status in NominationStatus.values) {
        await expectDecisions(
          tester,
          'n-${status.name}',
          approve: status == NominationStatus.awaitingApproval,
          closeVote: status == NominationStatus.open,
        );
      }
    });

    testWidgets('no host buttons on a paused nomination', (tester) async {
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          status: NominationStatus.paused,
          pausedFrom: NominationStatus.open,
        ),
        _nomination(
          'n-2',
          title: 'Azul',
          from: 'o-2',
          status: NominationStatus.paused,
          pausedFrom: NominationStatus.awaitingApproval,
        ),
      ];

      await showGames(tester, detail: as(host));

      for (final id in ['n-1', 'n-2']) {
        expect(
          inRow(id, 'Paused · 0 for · 0 against · 0 interested'),
          findsOneWidget,
          reason: id,
        );
        await expectDecisions(tester, id);
      }
    });

    testWidgets('a moderator gets Close vote but not Approve', (tester) async {
      nominationsAnswer = (_) => [
        _nomination('n-1'),
        _nomination(
          'n-2',
          title: 'Azul',
          from: 'o-2',
          status: NominationStatus.awaitingApproval,
        ),
      ];

      await showGames(tester, detail: as(moderator));

      await expectDecisions(tester, 'n-2');
      await openQuickLook(tester, 'n-1');
      await tester.tap(closeVoteIn);
      await animate(tester);
      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.resolutions, [(eventId: 'e-1', nominationId: 'n-1')]);
    });

    testWidgets("a household's admin with no row on the roster gets Close "
        'vote, and not Approve', (tester) async {
      nominationsAnswer = (_) => [
        _nomination('n-1'),
        _nomination(
          'n-2',
          title: 'Azul',
          from: 'o-2',
          status: NominationStatus.awaitingApproval,
        ),
      ];

      await showGames(
        tester,
        detail: detailOf(
          viewerGiven: false,
          roster: [ada, bo, unnamed],
          householdId: 'h-1',
        ),
        householdRole: (_) async => HouseholdRole.householdAdmin,
      );

      await expectDecisions(tester, 'n-2');
      await openQuickLook(tester, 'n-1');
      await tester.tap(closeVoteIn);
      await animate(tester);
      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.resolutions, [(eventId: 'e-1', nominationId: 'n-1')]);
    });

    testWidgets('a participant gets none', (tester) async {
      nominationsAnswer = (_) => [
        _nomination('n-1'),
        _nomination(
          'n-2',
          title: 'Azul',
          from: 'o-2',
          status: NominationStatus.awaitingApproval,
        ),
      ];

      await showGames(tester);

      await expectDecisions(tester, 'n-1');
      await expectDecisions(tester, 'n-2');
    });

    for (final status in [EventStatus.cancelled, EventStatus.archived]) {
      testWidgets("a host's decisions aren't built on a ${status.name} event", (
        tester,
      ) async {
        nominationsAnswer = (_) => [
          catan(),
          _nomination('n-2', title: 'Azul', from: 'o-2'),
        ];

        await showGames(
          tester,
          detail: detailOf(
            viewer: host,
            roster: [host, ada, bo, unnamed],
            status: status,
          ),
        );

        await expectDecisions(tester, 'n-1');
        await expectDecisions(tester, 'n-2');
      });
    }

    testWidgets('a decision is dropped where the event was cancelled while '
        'it asked, and says so', (tester) async {
      nominationsAnswer = (_) => [catan()];

      await showGames(tester, detail: as(host));
      await openQuickLook(tester, 'n-1');
      await tester.tap(approveIn);
      await animate(tester);

      // Cancelled while the dialog was open.
      cache.add(
        detailOf(
          viewer: host,
          roster: [host, ada, bo, unnamed],
          status: EventStatus.cancelled,
        ),
      );
      await settle(tester);
      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.approvals, isEmpty);
      expect(
        inOutcome(
          "Your decision on Catan wasn't sent: something changed on this "
          'event first.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a decision dropped by the re-check says so', (tester) async {
      nominationsAnswer = (_) => [catan()];

      await showGames(tester, detail: as(host));
      await openQuickLook(tester, 'n-1');
      await tester.tap(approveIn);
      await animate(tester);

      // Decided while the dialog was open.
      nominationsAnswer = (_) => [catan(status: NominationStatus.approved)];
      blocOf<EventNominationsBloc>(
        tester,
      ).add(const EventNominationsRequested('e-1'));
      await settle(tester);
      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.approvals, isEmpty);
      expect(
        inOutcome(
          "Your decision on Catan wasn't sent: something changed on this "
          'event first.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a close of the vote whose tally changed while it asked is '
        'dropped', (tester) async {
      nominationsAnswer = (_) => [
        catan(
          status: NominationStatus.open,
          votes: [_vote('att-ada', VoteType.forGame)],
        ),
      ];

      await showGames(tester, detail: as(host));
      await openQuickLook(tester, 'n-1');
      await tester.tap(closeVoteIn);
      await animate(tester);
      expect(
        find.text(
          "1 for, 0 against, 0 interested so far. The result can't be "
          'undone.',
        ),
        findsOneWidget,
      );

      // Voted on while the dialog was open: closing now would settle counts
      // the host never saw.
      nominationsAnswer = (_) => [
        catan(
          status: NominationStatus.open,
          votes: [
            _vote('att-ada', VoteType.forGame),
            _vote('att-bo', VoteType.against),
          ],
        ),
      ];
      blocOf<EventNominationsBloc>(
        tester,
      ).add(const EventNominationsRequested('e-1'));
      await settle(tester);
      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.resolutions, isEmpty);
      expect(
        inOutcome(
          "Your decision on Catan wasn't sent: something changed on this "
          'event first.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a close of the vote waits for a nominations read that is '
        'out, and is dropped when it finds the tally changed', (tester) async {
      nominationsAnswer = (_) => [
        catan(
          status: NominationStatus.open,
          votes: [_vote('att-ada', VoteType.forGame)],
        ),
      ];

      await showGames(tester, detail: as(host));
      await openQuickLook(tester, 'n-1');
      await tester.tap(closeVoteIn);
      await animate(tester);

      // A read starts while the dialog is open, and is still out at the
      // confirm: the rows still hold the tally the dialog showed.
      final held = Completer<List<EventNomination>>();
      nominationsAnswer = (_) => held.future;
      blocOf<EventNominationsBloc>(
        tester,
      ).add(const EventNominationsRequested('e-1'));
      await settle(tester);
      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.resolutions, isEmpty);

      held.complete([
        catan(
          status: NominationStatus.open,
          votes: [
            _vote('att-ada', VoteType.forGame),
            _vote('att-bo', VoteType.against),
          ],
        ),
      ]);
      await animate(tester);

      expect(remote.resolutions, isEmpty);
      expect(
        inOutcome(
          "Your decision on Catan wasn't sent: something changed on this "
          'event first.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a close of the vote that waited for a nominations read is '
        'sent when the read finds the same tally', (tester) async {
      List<EventNomination> rows() => [
        catan(
          status: NominationStatus.open,
          votes: [_vote('att-ada', VoteType.forGame)],
        ),
      ];
      nominationsAnswer = (_) => rows();

      await showGames(tester, detail: as(host));
      await openQuickLook(tester, 'n-1');
      await tester.tap(closeVoteIn);
      await animate(tester);

      final held = Completer<List<EventNomination>>();
      nominationsAnswer = (_) => held.future;
      blocOf<EventNominationsBloc>(
        tester,
      ).add(const EventNominationsRequested('e-1'));
      await settle(tester);
      await tester.tap(confirmDecision());
      await animate(tester);
      expect(remote.resolutions, isEmpty);

      nominationsAnswer = (_) => rows();
      held.complete(rows());
      await animate(tester);

      expect(remote.resolutions, hasLength(1));
    });

    testWidgets('a close of the vote whose Interested rule changed while it '
        'asked is dropped', (tester) async {
      nominationsAnswer = (_) => [
        catan(
          status: NominationStatus.open,
          votes: [_vote('att-nn', VoteType.interested)],
        ),
      ];
      final roster = [host, ada, bo, unnamed];
      EventDetail weighing(InterestedWeight weight) =>
          detailOf(viewer: host, roster: roster, policy: _policy(weight));

      await showGames(tester, detail: weighing(InterestedWeight.asFor));
      await openQuickLook(tester, 'n-1');
      await tester.tap(closeVoteIn);
      await animate(tester);
      expect(find.textContaining('Interested counts as For'), findsWidgets);

      // The tally is the same, but the rule the dialog stated isn't.
      cache.add(weighing(InterestedWeight.asAgainst));
      await settle(tester);
      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.resolutions, isEmpty);
      expect(
        inOutcome(
          "Your decision on Catan wasn't sent: something changed on this "
          'event first.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a detail read that starts while it asks holds the button, '
        'and the decision waits for it', (tester) async {
      nominationsAnswer = (_) => [catan()];

      await showGames(tester, detail: as(host));
      await openQuickLook(tester, 'n-1');
      final focus = focusOf(tester, approveIn)..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);

      heldRead = Completer<EventSnapshot>();
      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await tester.tap(confirmDecision());
      await animate(tester);

      // Held, so the focus the dialog hands back stays (#607), and nothing
      // goes until the read has ended.
      expect(focus.hasPrimaryFocus, isTrue);
      expect(remote.approvals, isEmpty);

      heldRead!.complete(as(host).snapshot);
      await animate(tester);

      expect(remote.approvals, hasLength(1));
      expect(textIn('Approved'), findsOneWidget);
    });

    testWidgets('disabled while a detail read runs, and while another '
        'nominations write is out', (tester) async {
      final sent = Completer<EventNomination>();
      approveAnswer = (_) => sent.future;
      nominationsAnswer = (_) => [
        catan(),
        _nomination('n-2', title: 'Azul', from: 'o-2'),
      ];

      await showGames(tester, detail: as(host));
      await openQuickLook(tester, 'n-1');
      heldRead = Completer<EventSnapshot>();
      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);

      for (final button in [approveIn, rejectIn]) {
        expect(pressOf(tester, button), isNull, reason: '$button');
      }

      heldRead!.complete(as(host).snapshot);
      heldRead = null;
      await animate(tester);
      for (final button in [approveIn, rejectIn]) {
        expect(pressOf(tester, button), isNotNull, reason: '$button');
      }

      await tester.tap(approveIn);
      await animate(tester);
      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.approvals, hasLength(1));
      expect(pressOf(tester, rejectIn), isNull);

      // Another nomination's, while the approval is out.
      await closeQuickLook(tester);
      await openQuickLook(tester, 'n-2');
      expect(pressOf(tester, closeVoteIn), isNull);

      sent.complete(catan(status: NominationStatus.approved));
      await animate(tester);

      expect(pressOf(tester, closeVoteIn), isNotNull);
    });

    testWidgets('disabled offline, saying why once in the quick look', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      // Catan awaits approval, with no vote control; Azul is open, with the
      // host's vote, whose own note says it there.
      nominationsAnswer = (_) => [
        catan(),
        _nomination('n-2', title: 'Azul', from: 'o-2'),
      ];
      useViewSize(tester, const Size(800, 3200));

      await showGames(tester, detail: as(host), offline: offline);

      for (final (id, buttons) in [
        ('n-1', [approveIn, rejectIn]),
        ('n-2', [closeVoteIn]),
      ]) {
        await openQuickLook(tester, id);
        for (final button in buttons) {
          expect(pressOf(tester, button), isNull, reason: '$id $button');
          expect(
            tester.getSemantics(button),
            isSemantics(hint: _onlineOnlyCopy, isEnabled: false),
            reason: '$id $button',
          );
        }
        expect(textIn(_onlineOnlyCopy), findsOneWidget, reason: id);
        await closeQuickLook(tester);
      }

      offline.value = false;
      await tester.pump();

      await openQuickLook(tester, 'n-1');
      expect(textIn(_onlineOnlyCopy), findsNothing);
      for (final button in [approveIn, rejectIn]) {
        expect(pressOf(tester, button), isNotNull, reason: '$button');
      }
      handle.dispose();
    });

    // Refused, the button keeps it: the quick look's own suite, below.
    group('after a decision, focus stays in the quick look', () {
      testWidgets('from the keyboard', (tester) async {
        final handle = tester.ensureSemantics();
        final sent = Completer<EventNomination>();
        approveAnswer = (_) => sent.future;
        nominationsAnswer = (_) => [catan()];

        await showGames(tester, detail: as(host));
        await openQuickLook(tester, 'n-1');
        final focus = focusOf(tester, approveIn)..requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);
        // Not yet, then Approve.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);

        // Held while it is out, so it keeps focus (#607).
        expect(remote.approvals, hasLength(1));
        expect(focus.hasPrimaryFocus, isTrue);

        sent.complete(catan(status: NominationStatus.approved));
        await animate(tester);

        expect(approveIn, findsNothing);
        expect(
          linesNode(tester),
          isSemantics(isFocusable: true, isFocused: true),
        );
        expect(
          linesNode(tester).getSemanticsData().label,
          contains('Approved'),
        );

        // Tab goes on from the lines.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(linesNode(tester), isSemantics(isFocused: false));
        handle.dispose();
      });

      testWidgets("from a screen reader's activation, with focus on nothing", (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        nominationsAnswer = (_) => [catan(status: NominationStatus.open)];

        await showGames(tester, detail: as(host));
        await openQuickLook(tester, 'n-1');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        screenReaderTap(tester, 'Close the vote on Catan');
        await animate(tester);
        screenReaderTap(tester, 'Close vote');
        await animate(tester);

        expect(remote.resolutions, hasLength(1));
        expect(linesNode(tester), isSemantics(isFocused: true));
        expect(linesNode(tester).getSemanticsData().label, contains('Passed'));
        handle.dispose();
      });
    });
  });

  group('filters and sort', () {
    /// Five nominations, in the server's order: Catan and Azul open for
    /// votes, Azul the viewer's own and voted on by them; Root awaiting
    /// approval; Wingspan, the viewer's, withdrawn; Brass passed, for
    /// Friday. By the votes that count, Azul has most support, then Brass,
    /// then Catan.
    List<EventNomination> spread() => [
      _nomination('n-1', votes: [_vote('att-ada', VoteType.forGame)]),
      _nomination(
        'n-2',
        title: 'Azul',
        by: 'att-me',
        from: 'o-2',
        votes: [
          _vote('att-me', VoteType.forGame),
          _vote('att-ada', VoteType.forGame),
          _vote('att-bo', VoteType.forGame),
        ],
      ),
      _nomination(
        'n-3',
        title: 'Root',
        from: 'o-gone',
        status: NominationStatus.awaitingApproval,
      ),
      _nomination(
        'n-4',
        title: 'Wingspan',
        by: 'att-me',
        from: 'o-2',
        status: NominationStatus.withdrawn,
      ),
      _nomination(
        'n-5',
        title: 'Brass',
        status: NominationStatus.passed,
        occurrenceId: 'd-1',
        votes: [
          _vote('att-ada', VoteType.forGame),
          _vote('att-nn', VoteType.forGame),
        ],
      ),
    ];

    const every = ['n-1', 'n-2', 'n-3', 'n-4', 'n-5'];

    /// The nominations shown, by id, in order down the page.
    List<String> rowsShown(WidgetTester tester) =>
        [
          for (final id in every)
            if (row(id).evaluate().isNotEmpty) id,
        ]..sort(
          (a, b) => tester
              .getTopLeft(row(a))
              .dy
              .compareTo(tester.getTopLeft(row(b)).dy),
        );

    Finder filters() => find.byKey(
      EventDetailScreen.nominationsFiltersKey,
      skipOffstage: false,
    );
    Finder sort() =>
        find.byKey(EventDetailScreen.nominationsSortKey, skipOffstage: false);
    Finder count() =>
        find.byKey(EventDetailScreen.nominationsCountKey, skipOffstage: false);
    Finder inUse(String id) => find.byKey(
      EventDetailScreen.nominationsInUseKey(id),
      skipOffstage: false,
    );
    Finder clearFilters() => find.byKey(
      EventDetailScreen.nominationsClearFiltersKey,
      skipOffstage: false,
    );
    FocusNode filtersFocus(WidgetTester tester) =>
        tester.widget<ButtonStyleButton>(filters()).focusNode!;

    /// Shows the five, in a view tall enough that every row is built.
    Future<void> showSpread(WidgetTester tester) async {
      useViewSize(tester, const Size(800, 3200));
      nominationsAnswer = (_) => spread();
      await showGames(tester);
    }

    /// Opens Filters, presses each of [keys] in it, and closes it.
    Future<void> filterBy(WidgetTester tester, List<Key> keys) async {
      await press(tester, filters());
      await animate(tester);
      for (final key in keys) {
        await tester.tap(find.byKey(key));
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);
    }

    /// Opens Sort and picks [order].
    Future<void> sortBy(WidgetTester tester, NominationSort order) async {
      await press(tester, sort());
      await animate(tester);
      await tester.tap(
        find.byKey(EventDetailScreen.nominationsSortItemKey(order)),
      );
      // A menu item's press lands after the frame its tap ends in.
      await tester.pump();
      await animate(tester);
    }

    testWidgets('the status filter narrows and the count is announced', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await showSpread(tester);

      expect(rowsShown(tester), every);
      // Counted, and not announced, while nothing narrows.
      expect(
        tester.getSemantics(count()),
        matchesSemantics(label: '5 nominations'),
      );

      await filterBy(tester, [
        EventDetailScreen.nominationsStatusKey(NominationStatusGroup.voting),
      ]);

      expect(rowsShown(tester), ['n-1', 'n-2']);
      expect(
        tester.getSemantics(count()),
        matchesSemantics(label: '2 of 5 nominations', isLiveRegion: true),
      );
      expect(
        find.descendant(
          of: inUse('status_voting'),
          matching: find.text('Voting'),
        ),
        findsOneWidget,
      );
      // The rows shown: the two nominations, the Nominations sub-tab's
      // alone (#945).
      expect(scrollViewOf(tester).semanticChildCount, 2);
      // Back on Filters as the filters close.
      expect(filtersFocus(tester).hasPrimaryFocus, isTrue);

      // A second status keeps its rows too.
      await filterBy(tester, [
        EventDetailScreen.nominationsStatusKey(NominationStatusGroup.decided),
      ]);

      expect(rowsShown(tester), ['n-1', 'n-2', 'n-5']);
      expect(find.text('3 of 5 nominations'), findsOneWidget);
      handle.dispose();
    });

    testWidgets(
      "Not voted yet keeps open nominations without the viewer's vote",
      (tester) async {
        await showSpread(tester);

        await filterBy(tester, [EventDetailScreen.nominationsNotVotedKey]);

        // Azul is open, and the viewer voted on it; the rest aren't open.
        expect(rowsShown(tester), ['n-1']);
        expect(find.text('1 of 5 nominations'), findsOneWidget);
        expect(
          find.descendant(
            of: inUse('not_voted'),
            matching: find.text('Not voted yet'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('a focused filter row is ringed (#758)', (tester) async {
      await showSpread(tester);
      await press(tester, filters());
      await animate(tester);

      for (final key in [
        EventDetailScreen.nominationsDateKey(null),
        EventDetailScreen.nominationsMineKey,
      ]) {
        expect(
          await keyboardFocusShowsRing(
            tester,
            find.descendant(of: find.byKey(key), matching: find.byType(Text)),
          ),
          isTrue,
          reason: '$key',
        );
      }
    });

    testWidgets("Mine keeps the viewer's own nominations", (tester) async {
      await showSpread(tester);

      await filterBy(tester, [EventDetailScreen.nominationsMineKey]);

      expect(rowsShown(tester), ['n-2', 'n-4']);
      expect(
        find.descendant(of: inUse('mine'), matching: find.text('Mine')),
        findsOneWidget,
      );
    });

    testWidgets("the date filter keeps one date's nominations, or the whole "
        "event's, and its chip names it", (tester) async {
      await showSpread(tester);

      await filterBy(tester, [
        EventDetailScreen.nominationsDateKey(const DateScope('d-1')),
      ]);

      expect(rowsShown(tester), ['n-5']);
      expect(
        find.descendant(
          of: inUse('date'),
          matching: find.text('For Fri, Nov 6 · 7:00 PM'),
        ),
        findsOneWidget,
      );

      await filterBy(tester, [
        EventDetailScreen.nominationsDateKey(const WholeEventScope()),
      ]);

      expect(rowsShown(tester), ['n-1', 'n-2', 'n-3', 'n-4']);

      await filterBy(tester, [EventDetailScreen.nominationsDateKey(null)]);

      expect(rowsShown(tester), every);
      expect(inUse('date'), findsNothing);
    });

    testWidgets('sorting by most support reorders the rows', (tester) async {
      final handle = tester.ensureSemantics();
      await showSpread(tester);

      await sortBy(tester, NominationSort.mostSupport);

      expect(rowsShown(tester), ['n-2', 'n-5', 'n-1', 'n-3', 'n-4']);

      // The menu marks the order chosen.
      await press(tester, sort());
      await animate(tester);
      expect(
        tester.getSemantics(
          find.byKey(
            EventDetailScreen.nominationsSortItemKey(
              NominationSort.mostSupport,
            ),
          ),
        ),
        isSemantics(label: 'Most support', isSelected: true),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);

      await sortBy(tester, NominationSort.newest);

      expect(rowsShown(tester), every);
      handle.dispose();
    });

    testWidgets('Sort names the order chosen, once, on its face and to a '
        'screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await showSpread(tester);

      Future<void> expectNamed(String order) async {
        expect(
          find.descendant(of: sort(), matching: find.text('Sort: $order')),
          findsOneWidget,
          reason: order,
        );
        final node = tester.getSemantics(sort()).getSemanticsData();
        expect(node.label, 'Sort: $order', reason: order);
        // Not said again as a value.
        expect(node.value, isEmpty, reason: order);
      }

      await expectNamed('Newest');

      await sortBy(tester, NominationSort.mostSupport);
      await expectNamed('Most support');

      await sortBy(tester, NominationSort.soonestDeadline);
      await expectNamed('Soonest deadline');
      handle.dispose();
    });

    testWidgets('the header fits at 320dp and 200% text, the longest order '
        'named whole', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      nominationsAnswer = (_) => spread();
      await showGames(tester);
      await sortBy(tester, NominationSort.soonestDeadline);

      expect(tester.takeException(), isNull);
      await tester.ensureVisible(sort());
      await tester.pump();
      for (final (button, label) in [
        (filters(), 'Filters'),
        (sort(), 'Sort: Soonest deadline'),
      ]) {
        final text = find.descendant(of: button, matching: find.text(label));
        expect(text, findsOneWidget, reason: label);
        final buttonRect = tester.getRect(button);
        final textRect = tester.getRect(text);
        // Whole, inside its button, inside the window.
        expect(buttonRect.intersect(textRect), textRect, reason: label);
        expect(buttonRect.right, lessThanOrEqualTo(320), reason: label);
        expect(buttonRect.left, greaterThanOrEqualTo(0), reason: label);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: text, matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: label);
        expect(
          paragraph.size.height,
          paragraph.getMaxIntrinsicHeight(paragraph.size.width),
          reason: label,
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('Sort, from the keyboard, opens into its menu and takes focus '
        'back after a pick or Escape', (
      tester,
    ) async {
      await showSpread(tester);
      final focus = tester.widget<ButtonStyleButton>(sort()).focusNode!;

      await activateByKeyboard(tester, sort());
      FocusNode itemFocus(NominationSort order) => Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(EventDetailScreen.nominationsSortItemKey(order)),
            matching: find.byType(Text),
          ),
        ),
      );
      // Down to Newest, the first, then on to Most support.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(itemFocus(NominationSort.newest).hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(itemFocus(NominationSort.mostSupport).hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      // A menu item's press lands after the frame its key ends in.
      await tester.pump();
      await animate(tester);

      expect(rowsShown(tester), ['n-2', 'n-5', 'n-1', 'n-3', 'n-4']);
      expect(focus.hasPrimaryFocus, isTrue);

      // Open again, up to the last order, and leave with Escape.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(itemFocus(NominationSort.soonestDeadline).hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);

      expect(
        find.byKey(
          EventDetailScreen.nominationsSortItemKey(NominationSort.newest),
        ),
        findsNothing,
      );
      expect(focus.hasPrimaryFocus, isTrue);
    });

    testWidgets('No nominations match fills the rest of the sub-tab, as the '
        "pool's does (#945)", (tester) async {
      await showSpread(tester);
      await filterBy(tester, [
        EventDetailScreen.nominationsMineKey,
        EventDetailScreen.nominationsStatusKey(
          NominationStatusGroup.awaitingApproval,
        ),
      ]);

      expect(
        find.ancestor(
          of: find.text('No nominations match'),
          matching: find.byType(BgeStateSliver),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Clear filters brings every nomination back and takes focus '
        'to Filters', (tester) async {
      await showSpread(tester);
      // The viewer's own awaiting approval: none.
      await filterBy(tester, [
        EventDetailScreen.nominationsMineKey,
        EventDetailScreen.nominationsStatusKey(
          NominationStatusGroup.awaitingApproval,
        ),
      ]);

      expect(find.text('No nominations match'), findsOneWidget);
      expect(rowsShown(tester), isEmpty);
      expect(find.text('0 of 5 nominations'), findsOneWidget);
      // No rows: the pool's are on their own sub-tab (#945).
      expect(scrollViewOf(tester).semanticChildCount, 0);

      await tester.ensureVisible(clearFilters());
      await tester.pump();
      tester
          .widget<ButtonStyleButton>(clearFilters())
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);

      expect(clearFilters(), findsNothing);
      expect(find.text('No nominations match'), findsNothing);
      expect(rowsShown(tester), every);
      expect(inUse('mine'), findsNothing);
      expect(filtersFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets("Clear filters, by a screen reader's activation, takes focus "
        'to Filters', (tester) async {
      final handle = tester.ensureSemantics();
      await showSpread(tester);
      await filterBy(tester, [
        EventDetailScreen.nominationsMineKey,
        EventDetailScreen.nominationsStatusKey(
          NominationStatusGroup.awaitingApproval,
        ),
      ]);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      screenReaderTap(tester, 'Clear filters');
      await animate(tester);

      expect(rowsShown(tester), every);
      expect(filtersFocus(tester).hasPrimaryFocus, isTrue);
      handle.dispose();
    });

    testWidgets('the last chip removed hands focus to Filters', (
      tester,
    ) async {
      await showSpread(tester);
      await filterBy(tester, [EventDetailScreen.nominationsMineKey]);
      tester.widget<InputChip>(inUse('mine')).focusNode!.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);

      expect(inUse('mine'), findsNothing);
      expect(rowsShown(tester), every);
      expect(filtersFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets('the filter survives switching to Details and back', (
      tester,
    ) async {
      await showSpread(tester);
      await filterBy(tester, [
        EventDetailScreen.nominationsStatusKey(NominationStatusGroup.voting),
        EventDetailScreen.nominationsStatusKey(NominationStatusGroup.decided),
      ]);
      await sortBy(tester, NominationSort.mostSupport);
      expect(rowsShown(tester), ['n-2', 'n-5', 'n-1']);

      await tester.tap(
        find.byKey(EventDetailScreen.tabKey(EventDetailTab.details)),
      );
      await animate(tester);
      expect(rowsShown(tester), isEmpty);
      await tester.tap(
        find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
      );
      await animate(tester);
      await chooseSection(tester, EventGamesSection.nominations);

      expect(rowsShown(tester), ['n-2', 'n-5', 'n-1']);
      expect(inUse('status_voting'), findsOneWidget);
      expect(inUse('status_decided'), findsOneWidget);
      expect(find.text('3 of 5 nominations'), findsOneWidget);
    });

    group('a vote, withdrawal or decision that takes its row out of the '
        'filter', () {
      /// The viewer's own Azul, open, which a withdrawal takes out of
      /// Voting.
      final azul = _nomination('n-1', title: 'Azul', by: 'att-me', from: 'o-2');

      /// Bo's Catan, open.
      final catan = _nomination('n-2');

      /// The head of [id]'s row, which opens its quick look (#957).
      FocusNode headOf(WidgetTester tester, String id) => tester
          .widget<InkWell>(
            find.descendant(
              of: find.byKey(
                EventDetailScreen.nominationRowHeadKey(id),
                skipOffstage: false,
              ),
              matching: find.byType(InkWell, skipOffstage: false),
              skipOffstage: false,
            ),
          )
          .focusNode!;

      /// The [type] choice of [id]'s vote, as focus finds it.
      FocusNode choiceOf(WidgetTester tester, String id, VoteType type) =>
          Focus.of(
            tester.element(
              find.byKey(
                EventDetailScreen.nominationVoteKey(id, type),
                skipOffstage: false,
              ),
            ),
          );

      /// The For choice of [id]'s vote, as focus finds it.
      FocusNode forOf(WidgetTester tester, String id) =>
          choiceOf(tester, id, VoteType.forGame);

      /// Shows [shown] under Voting alone.
      Future<void> showVoting(
        WidgetTester tester,
        List<EventNomination> shown,
      ) async {
        useViewSize(tester, const Size(800, 3200));
        nominationsAnswer = (_) => shown;
        await showGames(tester);
        await filterBy(tester, [
          EventDetailScreen.nominationsStatusKey(NominationStatusGroup.voting),
        ]);
      }

      /// Withdraws Azul from the keyboard in its quick look, where Withdraw
      /// is (#946): Withdraw, then the dialog's Withdraw, reached by Tab.
      Future<void> withdrawByKeyboard(WidgetTester tester) async {
        await openQuickLook(tester, 'n-1');
        tester.widget<ButtonStyleButton>(withdrawIn).focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);
        // Keep it, then Withdraw.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);
      }

      testWidgets('a withdrawal in the quick look, once it closes, hands '
          "focus to the next row's head (#957)", (tester) async {
        await showVoting(tester, [azul, catan]);

        await withdrawByKeyboard(tester);
        expect(remote.withdrawals, hasLength(1));
        expect(rowsShown(tester), ['n-2']);
        await closeQuickLook(tester);

        expect(headOf(tester, 'n-2').hasPrimaryFocus, isTrue);
      });

      testWidgets('a withdrawal in the quick look whose answer lands after '
          "it closes, before the next frame, hands focus to the next row's "
          'head', (tester) async {
        final answer = Completer<EventNomination>();
        withdrawAnswer = (_) => answer.future;
        await showVoting(tester, [azul, catan]);
        await withdrawByKeyboard(tester);
        expect(remote.withdrawals, hasLength(1));
        expect(rowsShown(tester), ['n-1', 'n-2']);

        // Closed, and the close's own work done, with no frame since.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        for (var i = 0; i < 20; i++) {
          await Future<void>.value();
        }
        // Then the answer lands, still before the next frame.
        answer.complete(azul.copyWith(status: NominationStatus.withdrawn));
        for (var i = 0; i < 20; i++) {
          await Future<void>.value();
        }
        await animate(tester);
        await animate(tester);

        expect(rowsShown(tester), ['n-2']);
        expect(headOf(tester, 'n-2').hasPrimaryFocus, isTrue);
      });

      testWidgets("a withdrawal by a screen reader's activation, with focus "
          'on nothing, hands it on too', (tester) async {
        final handle = tester.ensureSemantics();
        await showVoting(tester, [azul, catan]);
        await openQuickLook(tester, 'n-1');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();

        screenReaderTap(tester, 'Withdraw Azul');
        await animate(tester);
        screenReaderTap(tester, 'Withdraw');
        await animate(tester);
        expect(rowsShown(tester), ['n-2']);
        await closeQuickLook(tester);

        expect(headOf(tester, 'n-2').hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets('from the last row shown, to the one before', (
        tester,
      ) async {
        await showVoting(tester, [catan, azul]);

        await withdrawByKeyboard(tester);
        expect(rowsShown(tester), ['n-2']);
        await closeQuickLook(tester);

        expect(headOf(tester, 'n-2').hasPrimaryFocus, isTrue);
      });

      for (final type in [VoteType.forGame, VoteType.against]) {
        testWidgets('a vote under Not voted yet hands focus to the same '
            'choice on the next row: ${type.name}', (tester) async {
          useViewSize(tester, const Size(800, 3200));
          nominationsAnswer = (_) => [
            catan,
            _nomination('n-3', title: 'Root'),
          ];
          nominationAnswer = (_) =>
              catan.copyWith(votes: [_vote('att-me', type)]);
          await showGames(tester);
          await filterBy(tester, [EventDetailScreen.nominationsNotVotedKey]);
          expect(rowsShown(tester), ['n-2', 'n-3']);

          choiceOf(tester, 'n-2', type).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await animate(tester);

          expect(remote.votes, hasLength(1));
          expect(rowsShown(tester), ['n-3']);
          // In the same place among the next row's controls (#946).
          expect(choiceOf(tester, 'n-3', type).hasPrimaryFocus, isTrue);
        });
      }

      testWidgets("a vote by a screen reader's activation under Not voted "
          "yet hands focus on where the row's own read fails", (tester) async {
        final handle = tester.ensureSemantics();
        useViewSize(tester, const Size(800, 3200));
        nominationsAnswer = (_) => [catan, _nomination('n-3', title: 'Root')];
        nominationAnswer = (_) => throw _offline;
        await showGames(tester);
        await filterBy(tester, [EventDetailScreen.nominationsNotVotedKey]);
        expect(rowsShown(tester), ['n-2', 'n-3']);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        // The whole list's read, after the row's own failed, has the vote.
        nominationsAnswer = (_) => [
          catan.copyWith(votes: [_vote('att-me', VoteType.forGame)]),
          _nomination('n-3', title: 'Root'),
        ];

        // A segment's tap is on its button, whose label is a node under it.
        tester.semantics.tap(
          find.semantics.byPredicate((node) {
            if (!node.getSemanticsData().hasAction(SemanticsAction.tap)) {
              return false;
            }
            var named = false;
            node.visitChildren((child) {
              named = named || child.label == 'For Catan';
              return !named;
            });
            return named;
          }, describeMatch: (_) => 'the For Catan segment'),
        );
        await animate(tester);

        expect(remote.votes, hasLength(1));
        expect(rowsShown(tester), ['n-3']);
        expect(forOf(tester, 'n-3').hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets("a host's approval in the quick look, by a screen reader's "
          "activation under Awaiting approval, hands focus to the next row's "
          'head once it closes (#518)', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        final host = me.copyWith(role: EventRole.host);
        useViewSize(tester, const Size(800, 3200));
        nominationsAnswer = (_) => [
          _nomination('n-1', status: NominationStatus.awaitingApproval),
          _nomination(
            'n-2',
            title: 'Azul',
            from: 'o-2',
            status: NominationStatus.awaitingApproval,
          ),
        ];
        await showGames(
          tester,
          detail: detailOf(viewer: host, roster: [host, ada, bo, unnamed]),
        );
        await filterBy(tester, [
          EventDetailScreen.nominationsStatusKey(
            NominationStatusGroup.awaitingApproval,
          ),
        ]);
        await openQuickLook(tester, 'n-1');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();

        screenReaderTap(tester, 'Approve Catan');
        await animate(tester);
        screenReaderTap(tester, 'Approve');
        await animate(tester);
        expect(remote.approvals, hasLength(1));
        expect(rowsShown(tester), ['n-2']);
        await closeQuickLook(tester);

        expect(headOf(tester, 'n-2').hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets("from its head, to the next row's head, though that row "
          'has a vote (#946)', (tester) async {
        useViewSize(tester, const Size(800, 3200));
        final root = _nomination('n-3', title: 'Root');
        nominationsAnswer = (_) => [catan, root];
        await showGames(tester);
        headOf(tester, 'n-2').requestFocus();
        await tester.pump();

        // Catan leaves on the next read, its head holding focus.
        nominationsAnswer = (_) => [root];
        blocOf<EventNominationsBloc>(
          tester,
        ).add(const EventNominationsRequested('e-1'));
        await animate(tester);

        expect(row('n-2'), findsNothing);
        expect(headOf(tester, 'n-3').hasPrimaryFocus, isTrue);
        expect(forOf(tester, 'n-3').hasFocus, isFalse);
      });

      testWidgets("from a vote's choice, to the next row's head where it has "
          'no vote (#946)', (tester) async {
        useViewSize(tester, const Size(800, 3200));
        final root = _nomination(
          'n-3',
          title: 'Root',
          status: NominationStatus.passed,
        );
        nominationsAnswer = (_) => [catan, root];
        await showGames(tester);
        choiceOf(tester, 'n-2', VoteType.against).requestFocus();
        await tester.pump();

        // Catan leaves on the next read, its Against holding focus.
        nominationsAnswer = (_) => [root];
        blocOf<EventNominationsBloc>(
          tester,
        ).add(const EventNominationsRequested('e-1'));
        await animate(tester);

        expect(row('n-2'), findsNothing);
        expect(headOf(tester, 'n-3').hasPrimaryFocus, isTrue);
      });

      testWidgets("to the next row's head where it has no other control "
          '(#957)', (tester) async {
        useViewSize(tester, const Size(800, 3200));
        // Bo's Root, passed, with no votes: nothing to vote on, decide or
        // withdraw, and no one to list as having voted.
        final root = _nomination(
          'n-3',
          title: 'Root',
          status: NominationStatus.passed,
        );
        nominationsAnswer = (_) => [catan, root];
        await showGames(tester);
        headOf(tester, 'n-2').requestFocus();
        await tester.pump();

        // Catan leaves on the next read, its head holding focus.
        nominationsAnswer = (_) => [root];
        blocOf<EventNominationsBloc>(
          tester,
        ).add(const EventNominationsRequested('e-1'));
        await animate(tester);

        expect(row('n-2'), findsNothing);
        expect(
          find.descendant(
            of: row('n-3'),
            matching: find.byType(ButtonStyleButton, skipOffstage: false),
            skipOffstage: false,
          ),
          findsNothing,
        );
        expect(headOf(tester, 'n-3').hasPrimaryFocus, isTrue);
      });

      testWidgets('from the only row shown, to Filters', (tester) async {
        await showVoting(tester, [azul]);
        // Last on Sort, where Flutter would put focus back on its own.
        tester.widget<ButtonStyleButton>(sort()).focusNode!.requestFocus();
        await tester.pump();

        await withdrawByKeyboard(tester);
        expect(find.text('No nominations match'), findsOneWidget);
        await closeQuickLook(tester);

        expect(filtersFocus(tester).hasPrimaryFocus, isTrue);
      });
    });

    testWidgets('no header over nothing nominated', (tester) async {
      await showGames(tester);

      expect(find.text('Nothing nominated yet'), findsOneWidget);
      expect(filters(), findsNothing);
      expect(sort(), findsNothing);
      expect(count(), findsNothing);
    });
  });

  // The nominations as the row of dates chooses (#1042): a date's, then
  // the whole event's, marked, or the whole event's alone under Every date.
  group('the date view (#1042)', () {
    /// One for the whole event, one for Friday and one for Saturday.
    List<EventNomination> spread() => [
      _nomination('n-1'),
      _nomination('n-2', title: 'Azul', from: 'o-2', occurrenceId: 'd-1'),
      _nomination('n-3', title: 'Root', from: 'o-3', occurrenceId: 'd-2'),
    ];

    /// The nominations shown, by id, in order down the page.
    List<String> rowsShown(WidgetTester tester) =>
        [
          for (final id in ['n-1', 'n-2', 'n-3'])
            if (row(id).evaluate().isNotEmpty) id,
        ]..sort(
          (a, b) => tester
              .getTopLeft(row(a))
              .dy
              .compareTo(tester.getTopLeft(row(b)).dy),
        );

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

    Finder count() =>
        find.byKey(EventDetailScreen.nominationsCountKey, skipOffstage: false);
    Finder filters() => find.byKey(
      EventDetailScreen.nominationsFiltersKey,
      skipOffstage: false,
    );
    Finder inUse(String id) => find.byKey(
      EventDetailScreen.nominationsInUseKey(id),
      skipOffstage: false,
    );

    /// Opens Filters, presses each of [keys] in it, and closes it.
    Future<void> filterBy(WidgetTester tester, List<Key> keys) async {
      await press(tester, filters());
      await animate(tester);
      for (final key in keys) {
        await tester.tap(find.byKey(key));
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);
    }

    testWidgets('a date lists its nominations and the whole-event ones, '
        'marked', (tester) async {
      final handle = tester.ensureSemantics();
      useViewSize(tester, const Size(800, 2400));
      nominationsAnswer = (_) => spread();

      await showGames(tester, detail: detailOf(dates: [friday, saturday]));

      // Friday, the next date still to come: its own, then the whole
      // event's, each in the order chosen.
      expect(rowsShown(tester), ['n-2', 'n-1']);
      // The whole event's says it is for every date, last on its status
      // line, and spoken with commas; Friday's own doesn't.
      expect(
        inRow('n-1', 'Voting · 0 for · 0 against · 0 interested · Every date'),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(inRow('n-1', 'Catan')).label,
        'Catan\nVoting, 0 for, 0 against, 0 interested, Every date',
      );
      expect(
        inRow('n-2', 'Voting · 0 for · 0 against · 0 interested'),
        findsOneWidget,
      );
      // The count is of the view's.
      expect(
        find.descendant(of: count(), matching: find.text('2 nominations')),
        findsOneWidget,
      );

      await chooseDate(tester, 'd-2');

      expect(rowsShown(tester), ['n-3', 'n-1']);
      handle.dispose();
    });

    testWidgets("a date's own come first, then the whole event's, each in "
        'the order chosen', (tester) async {
      useViewSize(tester, const Size(800, 2400));
      // Two of each, the less supported first as the server orders them.
      nominationsAnswer = (_) => [
        _nomination('n-1'),
        _nomination(
          'n-4',
          title: 'Brass',
          from: 'o-4',
          votes: [_vote('att-ada', VoteType.forGame)],
        ),
        _nomination('n-2', title: 'Azul', from: 'o-2', occurrenceId: 'd-1'),
        _nomination(
          'n-5',
          title: 'Wingspan',
          from: 'o-5',
          occurrenceId: 'd-1',
          votes: [_vote('att-ada', VoteType.forGame)],
        ),
      ];
      await showGames(tester, detail: detailOf(dates: [friday, saturday]));
      List<String> shown() =>
          [
            for (final id in ['n-1', 'n-2', 'n-4', 'n-5'])
              if (row(id).evaluate().isNotEmpty) id,
          ]..sort(
            (a, b) => tester
                .getTopLeft(row(a))
                .dy
                .compareTo(tester.getTopLeft(row(b)).dy),
          );
      expect(shown(), ['n-2', 'n-5', 'n-1', 'n-4']);

      await press(
        tester,
        find.byKey(
          EventDetailScreen.nominationsSortKey,
          skipOffstage: false,
        ),
      );
      await animate(tester);
      await tester.tap(
        find.byKey(
          EventDetailScreen.nominationsSortItemKey(NominationSort.mostSupport),
        ),
      );
      await tester.pump();
      await animate(tester);

      expect(shown(), ['n-5', 'n-2', 'n-4', 'n-1']);
    });

    // The hand-off follows the rows as shown: the date's own, then the
    // whole event's.
    testWidgets("a row that leaves a date's view hands focus to the next row "
        'shown there', (tester) async {
      useViewSize(tester, const Size(800, 2400));
      // In the server's order the whole event's comes first; shown, Friday's
      // two come first.
      final whole = _nomination('n-1');
      final first = _nomination(
        'n-2',
        title: 'Azul',
        from: 'o-2',
        occurrenceId: 'd-1',
      );
      final second = _nomination(
        'n-9',
        title: 'Root',
        from: 'o-9',
        occurrenceId: 'd-1',
      );
      nominationsAnswer = (_) => [whole, first, second];
      await showGames(tester, detail: detailOf(dates: [friday, saturday]));
      expect(rowsShown(tester), ['n-2', 'n-1']);
      headFocus(tester, 'n-9').requestFocus();
      await tester.pump();

      // Someone else took it away: a read finds it gone.
      nominationsAnswer = (_) => [whole, first];
      blocOf<EventNominationsBloc>(
        tester,
      ).add(const EventNominationsRequested('e-1'));
      await animate(tester);

      expect(row('n-9'), findsNothing);
      expect(headFocus(tester, 'n-1').hasPrimaryFocus, isTrue);
    });

    testWidgets('Every date lists only whole-event nominations', (
      tester,
    ) async {
      useViewSize(tester, const Size(800, 2400));
      nominationsAnswer = (_) => spread();
      await showGames(tester, detail: detailOf(dates: [friday, saturday]));

      await chooseDate(tester, null);

      expect(rowsShown(tester), ['n-1']);
      // The view says it: the row doesn't.
      expect(
        inRow('n-1', 'Voting · 0 for · 0 against · 0 interested'),
        findsOneWidget,
      );
      expect(
        find.descendant(of: count(), matching: find.text('1 nomination')),
        findsOneWidget,
      );
    });

    testWidgets('a date with none in view says nothing is nominated', (
      tester,
    ) async {
      nominationsAnswer = (_) => [spread()[1]];
      await showGames(tester, detail: detailOf(dates: [friday, saturday]));

      await chooseDate(tester, 'd-2');

      expect(row('n-2'), findsNothing);
      expect(find.text('Nothing nominated yet'), findsOneWidget);
    });

    testWidgets("none in a started date's view points nowhere, as Nominate "
        "isn't offered there", (tester) async {
      final started = confirmed(
        'd-0',
        DateTime(2026, 10, 2, 19),
      ).copyWith(eventId: 'e-1');
      await showGames(tester, detail: detailOf(dates: [started, friday]));

      await chooseDate(tester, 'd-0');
      expect(find.text('Nothing nominated yet'), findsOneWidget);
      expect(find.text('Nominate a game from the Pool tab.'), findsNothing);

      await chooseDate(tester, 'd-1');
      expect(find.text('Nominate a game from the Pool tab.'), findsOneWidget);
    });

    testWidgets('the Filters sheet has no date choice while the row shows', (
      tester,
    ) async {
      nominationsAnswer = (_) => spread();
      await showGames(tester, detail: detailOf(dates: [friday, saturday]));

      await press(tester, filters());
      await animate(tester);

      // The statuses are offered, and no date: the row chooses that.
      expect(
        find.byKey(
          EventDetailScreen.nominationsStatusKey(NominationStatusGroup.voting),
        ),
        findsOneWidget,
      );
      expect(find.text('Date'), findsNothing);
      for (final scope in <NominationScope?>[
        null,
        const WholeEventScope(),
        const DateScope('d-1'),
        const DateScope('d-2'),
      ]) {
        expect(
          find.byKey(EventDetailScreen.nominationsDateKey(scope)),
          findsNothing,
          reason: '$scope',
        );
      }
    });

    // The row takes the date facet's place: a date filter set while there
    // was no row is cleared as the row appears, and isn't set back when the
    // row goes, as the row's choice isn't carried into the filter.
    testWidgets('a date filter set before the row appears is cleared, and '
        'stays cleared as the row goes', (tester) async {
      useViewSize(tester, const Size(800, 2400));
      nominationsAnswer = (_) => spread();
      final oneDate = detailOf();
      await showGames(tester, detail: oneDate);
      await filterBy(tester, [
        EventDetailScreen.nominationsDateKey(const DateScope('d-1')),
      ]);
      expect(rowsShown(tester), ['n-2']);
      expect(inUse('date'), findsOneWidget);

      // A second date is added.
      cache.add(detailOf(dates: [friday, saturday]));
      await animate(tester);

      expect(inUse('date'), findsNothing);
      expect(rowsShown(tester), ['n-2', 'n-1']);

      // It is removed again.
      cache.add(oneDate);
      await animate(tester);

      expect(inUse('date'), findsNothing);
      expect(rowsShown(tester), ['n-1', 'n-2', 'n-3']);
    });

    testWidgets('a one-date event has no row, and the nominations are as '
        'before', (tester) async {
      useViewSize(tester, const Size(800, 2400));
      nominationsAnswer = (_) => spread();
      await showGames(tester);

      expect(find.byKey(EventDetailScreen.dateChipKey(null)), findsNothing);
      // Every nomination, whatever it is for, none of them marked.
      expect(rowsShown(tester), ['n-1', 'n-2', 'n-3']);
      expect(
        inRow('n-1', 'Voting · 0 for · 0 against · 0 interested'),
        findsOneWidget,
      );
      expect(
        find.descendant(of: count(), matching: find.text('3 nominations')),
        findsOneWidget,
      );
      // And the date facet is offered.
      await press(tester, filters());
      await animate(tester);
      expect(find.text('Date'), findsOneWidget);
      expect(
        find.byKey(
          EventDetailScreen.nominationsDateKey(const DateScope('d-1')),
        ),
        findsOneWidget,
      );
    });
  });

  group('quick look (#957)', () {
    final host = me.copyWith(role: EventRole.host);

    /// `e-1` as [viewer] sees it, with them on the roster in the viewer's
    /// place.
    EventDetail as(EventAttendee viewer, {EventPolicy? policy}) => detailOf(
      viewer: viewer,
      roster: [viewer, ada, bo, unnamed],
      policy: policy,
    );

    final gone = find.byKey(EventDetailScreen.quickLookGoneKey);
    final lines = quickLookLines;
    final openGame = find.byKey(EventDetailScreen.quickLookOpenGameKey);
    final voteIn = inQuickLook(find.byType(SegmentedButton<VoteType>));
    Finder confirmDecision() =>
        find.byKey(EventDetailScreen.hostDecisionConfirmKey);
    final anyButton = find.byWidgetPredicate(
      (widget) => widget is ButtonStyleButton,
      description: 'a button',
    );

    FocusNode focusOf(WidgetTester tester, Finder button) =>
        tester.widget<ButtonStyleButton>(button).focusNode!;

    group('a nomination that put its game in the lineup (#519)', () {
      final lineupIn = find.byKey(EventDetailScreen.quickLookOpenLineupKey);
      const named = 'See in lineup: Catan';
      final lineupGone = find.text('This game is no longer in the lineup.');

      testWidgets("opens that game's quick look over its own, and focus comes "
          "back as it closes, a screen reader's activation included", (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        nominationsAnswer = (_) => [
          _nomination(
            'n-1',
            status: NominationStatus.passed,
            elevatedTo: (id: 'l-1', occurrenceId: null),
          ),
        ];
        lineupAnswer = (_) => [_lineupGame('l-1', nominationId: 'n-1')];
        await showGames(tester);
        await openQuickLook(tester, 'n-1');

        expect(
          tester.getSemantics(lineupIn),
          isSemantics(
            label: named,
            isButton: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        expect(
          tester.getSize(lineupIn).height,
          greaterThanOrEqualTo(kMinInteractiveDimension),
        );
        expect(
          tester.getSize(lineupIn).width,
          greaterThanOrEqualTo(kMinInteractiveDimension),
        );

        screenReaderTap(tester, named);
        await animate(tester);

        // The lineup game's, over the nomination's, which stays.
        expect(quickLook, findsNWidgets(2));
        expect(find.text('Added from a nomination'), findsOneWidget);
        expect(lineupGone, findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await animate(tester);
        expect(quickLook, findsOneWidget);
        expect(find.text('Added from a nomination'), findsNothing);
        expect(focusOf(tester, lineupIn).hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets("an outcome that lands while the lineup game's is open is "
          'said there, and not again here as that one closes', (tester) async {
        final handle = tester.ensureSemantics();
        nominationsAnswer = (_) => [
          _nomination(
            'n-1',
            status: NominationStatus.passed,
            elevatedTo: (id: 'l-1', occurrenceId: null),
          ),
        ];
        lineupAnswer = (_) => [_lineupGame('l-1', nominationId: 'n-1')];
        await showGames(tester);
        await openQuickLook(tester, 'n-1');
        await press(tester, lineupIn);
        await animate(tester);
        expect(quickLook, findsNWidgets(2));

        blocOf<EventLineupBloc>(tester).add(
          const LineupWriteDropped(LineupWrite.remove, title: 'Catan'),
        );
        await settle(tester);
        const copy =
            "Catan wasn't taken out: something changed on this event first.";
        expect(
          tester.getSemantics(
            find.descendant(of: quickLook.last, matching: find.text(copy)),
          ),
          isSemantics(isLiveRegion: true),
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await animate(tester);
        expect(quickLook, findsOneWidget);
        // Shown here still, but no live region to be read out again.
        final here = find.descendant(of: quickLook, matching: find.text(copy));
        expect(here, findsOneWidget);
        expect(tester.getSemantics(here), isSemantics(isLiveRegion: false));
        handle.dispose();
      });

      // Not offered where the lineup isn't known to hold the game, so the
      // stacked quick look never says it has gone for a lineup not read.
      for (final (name, answer) in <(String, List<LineupGame> Function())>[
        ('no longer holds it', () => [_lineupGame('l-2')]),
        ("couldn't be read", () => throw _offline),
      ]) {
        testWidgets('where the lineup $name, there is no way to it', (
          tester,
        ) async {
          nominationsAnswer = (_) => [
            _nomination(
              'n-1',
              status: NominationStatus.approved,
              elevatedTo: (id: 'l-1', occurrenceId: 'd-1'),
            ),
          ];
          lineupAnswer = (_) => answer();
          await showGames(tester);
          await openQuickLook(tester, 'n-1');

          expect(lineupIn, findsNothing);
          expect(quickLook, findsOneWidget);
        });
      }

      testWidgets('the lineup quick look opened from it offers no View game, '
          'the nomination under it has one', (tester) async {
        nominationsAnswer = (_) => [
          _nomination(
            'n-1',
            status: NominationStatus.passed,
            elevatedTo: (id: 'l-1', occurrenceId: null),
          ),
        ];
        lineupAnswer = (_) => [_lineupGame('l-1', nominationId: 'n-1')];
        await showGames(tester);
        await openQuickLook(tester, 'n-1');
        await press(tester, lineupIn);
        await animate(tester);

        expect(quickLook, findsNWidgets(2));
        expect(
          find.descendant(of: quickLook.first, matching: openGame),
          findsOneWidget,
        );
        expect(
          find.descendant(of: quickLook.last, matching: openGame),
          findsNothing,
        );
      });

      testWidgets('at 320×640 and 200% text, it lays out beside Who voted '
          'with no overflow', (tester) async {
        useViewSize(tester, const Size(320, 640));
        tester.platformDispatcher.textScaleFactorTestValue =
            BgeTextScale.maxScaleFactor;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        pool = [_game('o-1', 'att-ada', _longTitle), azulMine];
        nominationsAnswer = (_) => [
          _nomination(
            'n-1',
            title: _longTitle,
            status: NominationStatus.passed,
            elevatedTo: (id: 'l-1', occurrenceId: null),
            votes: [_vote('att-ada', VoteType.forGame)],
          ),
        ];
        lineupAnswer = (_) => [_lineupGame('l-1', nominationId: 'n-1')];
        await showGames(tester);
        await openQuickLook(tester, 'n-1');

        expect(tester.takeException(), isNull);
        for (final control in [votersIn, lineupIn, openGame]) {
          await tester.ensureVisible(control);
          await tester.pump();
          expect(tester.takeException(), isNull, reason: '$control');
          final rect = tester.getRect(control);
          expect(rect.left, greaterThanOrEqualTo(0), reason: '$control');
          expect(rect.right, lessThanOrEqualTo(320), reason: '$control');
          expect(
            rect.height,
            greaterThanOrEqualTo(kMinInteractiveDimension),
            reason: '$control',
          );
        }
      });

      testWidgets('one not in the lineup has no way there', (tester) async {
        nominationsAnswer = (_) => [
          _nomination('n-1', status: NominationStatus.passed),
          _nomination('n-2', title: 'Azul', from: 'o-2'),
        ];
        lineupAnswer = (_) => [_lineupGame('l-1')];
        await showGames(tester);

        for (final id in ['n-1', 'n-2']) {
          await openQuickLook(tester, id);
          expect(lineupIn, findsNothing, reason: id);
          await closeQuickLook(tester);
        }
      });
    });

    testWidgets("a nomination's quick look names a date the event no longer "
        'has as gone, as the filters do', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        _nomination('n-1', by: 'att-me', occurrenceId: 'd-gone'),
      ];
      await showGames(tester);

      await openQuickLook(tester, 'n-1');

      expect(
        linesNode(tester).getSemanticsData().label,
        contains('For a date no longer on the event'),
      );
      handle.dispose();
    });

    testWidgets("a nomination's quick look holds who nominated it, whose "
        'copy, its scope, status, tally spoken without symbols, how '
        "Interested counts, the viewer's vote, when voting closes, a pause, "
        'Who voted, Withdraw and View game', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        // The viewer's own, of Ada's Catan, open, with their vote on it.
        _nomination(
          'n-1',
          by: 'att-me',
          deadline: DateTime(2026, 10, 25, 20),
          votes: [
            _vote('att-me', VoteType.forGame),
            _vote('att-ada', VoteType.against),
            _vote('att-nn', VoteType.interested),
          ],
        ),
        // Bo's, of the viewer's own Azul, for Friday, paused.
        _nomination(
          'n-2',
          title: 'Azul',
          from: 'o-2',
          occurrenceId: 'd-1',
          status: NominationStatus.paused,
          pausedFrom: NominationStatus.open,
          votes: [_vote('att-me', VoteType.forGame)],
        ),
      ];
      await showGames(
        tester,
        detail: detailOf(policy: _policy(InterestedWeight.asFor)),
      );

      // The row's cover and lines are one button.
      await tester.ensureVisible(head('n-1'));
      await tester.pump();
      expect(
        tester.getSemantics(head('n-1')),
        isSemantics(isButton: true, isFocusable: true, hasTapAction: true),
      );

      await openQuickLook(tester, 'n-1');

      // Named for its game as it opens, and headed by it.
      expect(
        find.semantics.byPredicate(
          (node) =>
              node.label == 'Catan' &&
              node.getSemanticsData().flagsCollection.namesRoute,
          describeMatch: (_) => 'a route named "Catan"',
        ),
        findsOneWidget,
      );
      expect(textIn('Catan'), findsOneWidget);
      // Every line the row says, as one node, the tally read without the
      // symbol between its counts.
      expect(textIn('1 for · 1 against · 1 interested'), findsOneWidget);
      expect(
        linesNode(tester).getSemanticsData().label,
        'Tabletop\nNominated by you\n'
        "From Ada's games\nFor the whole event\nVoting\n"
        '1 for, 1 against, 1 interested\nInterested counts as For\n'
        'Voting closes Sun, Oct 25 · 8:00 PM',
      );
      // The viewer's vote, chosen on the vote control.
      expect(tester.widget<SegmentedButton<VoteType>>(voteIn).selected, {
        VoteType.forGame,
      });
      expect(
        tester.getSemantics(votersIn),
        isSemantics(label: 'Who voted on Catan: 3 votes', isButton: true),
      );
      expect(
        tester.getSemantics(withdrawIn),
        isSemantics(label: 'Withdraw Catan', isButton: true, isEnabled: true),
      );
      expect(
        tester.getSemantics(openGame),
        isSemantics(label: 'View game: Catan', isButton: true),
      );
      await tester.tap(openGame);
      await tester.pump();
      expect(openedGames, [
        (ModalRoute.of(tester.element(quickLook)), 'g-n-1'),
      ]);
      await closeQuickLook(tester);

      // Paused, with no vote control: the viewer's vote is in its lines.
      await openQuickLook(tester, 'n-2');
      for (final line in [
        'Nominated by Bo',
        'From your games',
        'For Fri, Nov 6 · 7:00 PM',
        'Paused',
        'Your vote: For',
        "Paused: you aren't coming. It goes back to Voting if you come back.",
      ]) {
        expect(textIn(line), findsOneWidget, reason: line);
      }
      expect(voteIn, findsNothing);
      expect(withdrawIn, findsNothing);
      expect(inQuickLook(votersIn), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a host sees Approve and Reject on one awaiting approval, and '
        'Close vote on an open one, in the quick look', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        _nomination('n-1', status: NominationStatus.awaitingApproval),
        _nomination('n-2', title: 'Azul', from: 'o-2'),
      ];
      await showGames(tester, detail: as(host));

      await openQuickLook(tester, 'n-1');
      expect(textIn('Awaiting approval'), findsOneWidget);
      for (final (button, label) in [
        (approveIn, 'Approve Catan'),
        (rejectIn, 'Reject Catan'),
      ]) {
        expect(inQuickLook(button), findsOneWidget, reason: label);
        expect(
          tester.getSemantics(button),
          isSemantics(
            label: label,
            isButton: true,
            isEnabled: true,
            hasTapAction: true,
          ),
          reason: label,
        );
      }
      expect(closeVoteIn, findsNothing);
      expect(voteIn, findsNothing);
      await closeQuickLook(tester);

      await openQuickLook(tester, 'n-2');
      expect(
        tester.getSemantics(closeVoteIn),
        isSemantics(
          label: 'Close the vote on Azul',
          isButton: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      expect(approveIn, findsNothing);
      expect(rejectIn, findsNothing);

      // It asks first, as the row's does, then sends.
      await tester.tap(closeVoteIn);
      await animate(tester);
      expect(find.text('Close the vote on Azul?'), findsOneWidget);
      await tester.tap(confirmDecision());
      await animate(tester);
      expect(remote.resolutions, [(eventId: 'e-1', nominationId: 'n-2')]);
      handle.dispose();
    });

    testWidgets("the vote control in it sends as the row's does, and the row "
        'redraws with it', (tester) async {
      nominationsAnswer = (_) => [_nomination('n-1')];
      nominationAnswer = (request) => _nomination(
        request.nominationId,
        votes: [_vote('att-me', VoteType.forGame)],
      );
      await showGames(tester);
      await openQuickLook(tester, 'n-1');
      expect(
        tester.widget<SegmentedButton<VoteType>>(voteIn).selected,
        isEmpty,
      );

      await tester.tap(
        inQuickLook(
          find.byKey(
            EventDetailScreen.nominationVoteKey('n-1', VoteType.forGame),
          ),
        ),
      );
      await animate(tester);

      expect(remote.votes, [
        (
          eventId: 'e-1',
          nominationId: 'n-1',
          voteType: VoteType.forGame,
          comment: null,
        ),
      ]);
      expect(quickLook, findsOneWidget);
      expect(tester.widget<SegmentedButton<VoteType>>(voteIn).selected, {
        VoteType.forGame,
      });
      expect(textIn('1 for · 0 against · 0 interested'), findsOneWidget);
      // The row under it, read from the same state.
      expect(
        inRow('n-1', 'Voting · 1 for · 0 against · 0 interested'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SegmentedButton<VoteType>>(
              find.descendant(
                of: row('n-1'),
                matching: find.byType(
                  SegmentedButton<VoteType>,
                  skipOffstage: false,
                ),
                skipOffstage: false,
              ),
            )
            .selected,
        {VoteType.forGame},
      );
      expect(
        find.descendant(
          of: inQuickLook(outcome()),
          matching: find.text('Your vote on Catan is in.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Withdraw from it, confirmed, leaves it on its lines, focused, '
        'with Withdraw gone', (tester) async {
      final handle = tester.ensureSemantics();
      final sent = Completer<EventNomination>();
      withdrawAnswer = (_) => sent.future;
      final azul = _nomination('n-1', title: 'Azul', by: 'att-me', from: 'o-2');
      nominationsAnswer = (_) => [azul];
      await showGames(tester);
      await openQuickLook(tester, 'n-1');
      // No stop of their own until a write hands them focus.
      expect(linesNode(tester), isSemantics(isFocusable: false));

      final focus = focusOf(tester, withdrawIn)..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      expect(find.text('Withdraw Azul?'), findsOneWidget);
      // Keep it, then Withdraw.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);

      // Held while it is out, so it keeps focus (#607).
      expect(remote.withdrawals, [(eventId: 'e-1', nominationId: 'n-1')]);
      expect(focus.hasPrimaryFocus, isTrue);

      sent.complete(azul.copyWith(status: NominationStatus.withdrawn));
      await animate(tester);

      expect(quickLook, findsOneWidget);
      expect(withdrawIn, findsNothing);
      expect(
        linesNode(tester),
        isSemantics(isFocusable: true, isFocused: true),
      );
      expect(linesNode(tester).getSemanticsData().label, contains('Withdrawn'));
      // Nothing under the pop-up took it.
      expect(headFocus(tester, 'n-1').hasFocus, isFalse);

      // Tab goes on from the lines, which are no stop of their own.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        linesNode(tester),
        isSemantics(isFocusable: false, isFocused: false),
      );
      handle.dispose();
    });

    testWidgets('a decision refused leaves focus on the button pressed', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      rejectAnswer = (_) =>
          throw const EventWriteRefusedException('no', statusCode: 403);
      nominationsAnswer = (_) => [
        _nomination('n-1', status: NominationStatus.awaitingApproval),
      ];
      await showGames(tester, detail: as(host));
      await openQuickLook(tester, 'n-1');

      final focus = focusOf(tester, rejectIn)..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.rejections, hasLength(1));
      expect(
        find.descendant(
          of: inQuickLook(outcome()),
          matching: find.text("You can't decide on Catan."),
        ),
        findsOneWidget,
      );
      expect(focus.hasPrimaryFocus, isTrue);
      expect(tester.widget<TextButton>(rejectIn).onPressed, isNotNull);
      expect(linesNode(tester), isSemantics(isFocused: false));
      handle.dispose();
    });

    testWidgets('a nomination that leaves the list while open says so; '
        "closing it focuses the next row's head", (tester) async {
      final handle = tester.ensureSemantics();
      final azul = _nomination('n-2', title: 'Azul', from: 'o-2');
      nominationsAnswer = (_) => [_nomination('n-1'), azul];
      await showGames(tester);
      await openQuickLook(tester, 'n-1');

      // Gone from the next read.
      nominationsAnswer = (_) => [azul];
      blocOf<EventNominationsBloc>(
        tester,
      ).add(const EventNominationsRequested('e-1'));
      await animate(tester);

      expect(row('n-1'), findsNothing);
      expect(inQuickLook(gone), findsOneWidget);
      expect(
        textIn('This nomination is no longer on the list.'),
        findsOneWidget,
      );
      expect(tester.getSemantics(gone), isSemantics(isLiveRegion: true));
      expect(inQuickLook(anyButton), findsNothing);
      // Still headed by its game.
      expect(textIn('Catan'), findsOneWidget);

      await closeQuickLook(tester);

      expect(headFocus(tester, 'n-2').hasPrimaryFocus, isTrue);
      handle.dispose();
    });

    testWidgets('Who voted, opened from the quick look, hands focus back to it '
        'on close', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        _nomination('n-1', votes: [_vote('att-ada', VoteType.forGame)]),
      ];
      await showGames(tester);
      await openQuickLook(tester, 'n-1');
      final voters = find.text('Who voted on Catan');

      // By a pointer.
      await tester.tap(votersIn);
      await animate(tester);
      expect(voters, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);
      expect(voters, findsNothing);
      expect(quickLook, findsOneWidget);
      expect(focusOf(tester, votersIn).hasPrimaryFocus, isTrue);

      // By a screen reader's activation, with focus left elsewhere.
      final elsewhere = Focus.of(
        tester.element(
          find.descendant(of: openGame, matching: find.text('View game')),
        ),
      )..requestFocus();
      await tester.pump();
      expect(elsewhere.hasPrimaryFocus, isTrue);
      screenReaderTap(tester, 'Who voted on Catan: 1 vote');
      await animate(tester);
      expect(voters, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await animate(tester);

      expect(quickLook, findsOneWidget);
      expect(focusOf(tester, votersIn).hasPrimaryFocus, isTrue);
      handle.dispose();
    });

    testWidgets("a decision's outcome is said inside the pop-up", (
      tester,
    ) async {
      nominationsAnswer = (_) => [
        _nomination('n-1', status: NominationStatus.awaitingApproval),
        _nomination(
          'n-2',
          title: 'Azul',
          from: 'o-2',
          status: NominationStatus.awaitingApproval,
        ),
      ];
      await showGames(tester, detail: as(host));
      // An outcome in the footer as the quick look opens isn't said again:
      // one from another quick look, closed since.
      await openQuickLook(tester, 'n-2');
      await tester.tap(approveIn);
      await animate(tester);
      await tester.tap(confirmDecision());
      await animate(tester);
      await closeQuickLook(tester);
      expect(outcome(), findsOneWidget);

      await openQuickLook(tester, 'n-1');
      expect(inQuickLook(outcome()), findsNothing);

      await tester.tap(approveIn);
      await animate(tester);
      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.approvals, [
        (eventId: 'e-1', nominationId: 'n-2'),
        (eventId: 'e-1', nominationId: 'n-1'),
      ]);
      expect(textIn('Approved'), findsOneWidget);
      expect(inQuickLook(outcome()), findsOneWidget);
      expect(
        find.descendant(
          of: inQuickLook(outcome()),
          matching: find.text('Catan is approved and in the lineup.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets("the pool's outcome landing while it is open is said inside "
        "the pop-up, and the footer's banner of it is no live region", (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [_nomination('n-1')];
      await showGames(tester);
      await openQuickLook(tester, 'n-1');
      final poolOutcome = find.byKey(EventDetailScreen.poolOutcomeKey);
      expect(inQuickLook(poolOutcome), findsNothing);

      // A take-back begun on the pool before the quick look opened ends.
      blocOf<EventGamesBloc>(tester).add(
        const EventGamesWriteDropped(EventGamesWrite.takeBack, title: 'Azul'),
      );
      await animate(tester);

      BgeInlineBanner banner(Finder finder) =>
          tester.widget<BgeInlineBanner>(finder);
      final inFooter = find.descendant(
        of: find.byType(EventGamesFooter),
        matching: poolOutcome,
      );
      expect(banner(inQuickLook(poolOutcome)).announce, isTrue);
      expect(banner(inFooter).announce, isFalse);
      handle.dispose();
    });

    testWidgets("at 320×640 and 200% text, a host's quick look with every "
        'control lays out with no overflow', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final offline = ValueNotifier(false);
      addTearDown(offline.dispose);
      pool = [_game('o-1', 'att-ada', _longTitle), azulMine];
      final votes = [
        _vote('att-ada', VoteType.forGame),
        _vote('att-me', VoteType.interested),
      ];
      nominationsAnswer = (_) => [
        // The host's own, open, past its deadline: the vote control, Who
        // voted, Withdraw and Close vote.
        _nomination(
          'n-1',
          title: _longTitle,
          by: 'att-me',
          occurrenceId: 'd-1',
          deadline: DateTime(2026, 10, 22, 20),
          votes: votes,
        ),
        // The host's own, awaiting approval: Who voted, Withdraw, Approve
        // and Reject.
        _nomination(
          'n-2',
          title: _longTitle,
          by: 'att-me',
          status: NominationStatus.awaitingApproval,
          votes: votes,
        ),
      ];
      await showGames(
        tester,
        detail: as(host, policy: _policy(InterestedWeight.asAbstain)),
        offline: offline,
      );

      for (final (id, controls) in [
        ('n-1', [voteIn, votersIn, withdrawIn, closeVoteIn]),
        ('n-2', [votersIn, withdrawIn, approveIn, rejectIn]),
      ]) {
        await openQuickLook(tester, id);
        expect(tester.takeException(), isNull, reason: id);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: textIn(_longTitle),
            matching: find.byType(RichText),
          ),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: id);
        for (final control in [lines, ...controls, openGame]) {
          expect(inQuickLook(control), findsOneWidget, reason: '$id $control');
          await tester.ensureVisible(control);
          await tester.pump();
          expect(tester.takeException(), isNull, reason: '$id $control');
          final rect = tester.getRect(control);
          expect(rect.left, greaterThanOrEqualTo(0), reason: '$id $control');
          expect(rect.right, lessThanOrEqualTo(320), reason: '$id $control');
        }
        await closeQuickLook(tester);
      }

      // Offline, with the one note its writes share.
      offline.value = true;
      await tester.pump();
      await openQuickLook(tester, 'n-2');
      final note = inQuickLook(find.byType(BgeOnlineOnlyNote));
      expect(note, findsOneWidget);
      await tester.ensureVisible(note);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(note).right, lessThanOrEqualTo(320));
    });
  });

  group('accessibility audit', () {
    testWidgets('at 840×900 and 200% text, two nomination rows to a line lay '
        'out with no overflow, vote control included', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      pool = [_game('o-1', 'att-ada', _longTitle), azulMine];
      // The viewer's Interested chosen on both: the longest choice, beside
      // its check.
      nominationsAnswer = (_) => [
        for (final id in ['n-1', 'n-2'])
          _nomination(
            id,
            title: _longTitle,
            votes: [_vote('att-me', VoteType.interested)],
          ),
      ];
      const choices = [VoteType.forGame, VoteType.against, VoteType.interested];
      Finder choice(String id, VoteType type) =>
          find.byKey(EventDetailScreen.nominationVoteKey(id, type));
      Finder label(String id, VoteType type) => find.descendant(
        of: choice(id, type),
        matching: find.byType(RichText),
      );
      Finder control(String id) => find.descendant(
        of: row(id),
        matching: find.byType(SegmentedButton<VoteType>),
      );

      /// How far [id]'s choice of [type] is scaled down to fit its segment:
      /// 1 where it isn't.
      double scaleOf(String id, VoteType type) =>
          tester.getRect(label(id, type)).width /
          tester.renderObject<RenderParagraph>(label(id, type)).size.width;

      // On the narrowest phone first, one row to a line: what the vote
      // control's labels are scaled to there, at the same text size.
      useViewSize(tester, const Size(320, 640));
      await showGames(tester);
      await tester.scrollUntilVisible(
        control('n-1'),
        100,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(control('n-1'));
      await tester.pump();
      final onPhone = {for (final type in choices) type: scaleOf('n-1', type)};

      // The narrowest expanded window, where two rows to a line have the
      // least room (#949).
      useViewSize(tester, const Size(840, 900));
      await tester.pump();
      for (final id in ['n-1', 'n-2']) {
        await tester.ensureVisible(control(id));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: id);
      }

      final first = tester.getRect(row('n-1'));
      final second = tester.getRect(row('n-2'));
      // Two to a line, each within the window.
      expect(second.top, first.top);
      expect(second.left, greaterThan(first.right));
      expect(second.right, lessThanOrEqualTo(840));
      for (final id in ['n-1', 'n-2']) {
        final rowRect = tester.getRect(row(id));
        final title = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: inRow(id, _longTitle),
            matching: find.byType(RichText),
          ),
        );
        expect(title.didExceedMaxLines, isFalse, reason: id);
        final controlRect = tester.getRect(control(id));
        expect(rowRect.intersect(controlRect), controlRect, reason: id);
        for (final type in choices) {
          final reason = '$id ${type.name}';
          final paragraph = tester.renderObject<RenderParagraph>(
            label(id, type),
          );
          // One line, whole, inside its segment.
          expect(paragraph.didExceedMaxLines, isFalse, reason: reason);
          final segment = tester.getRect(
            find.ancestor(
              of: choice(id, type),
              matching: find.byType(TextButton),
            ),
          );
          final drawn = tester.getRect(label(id, type));
          expect(
            segment.contains(drawn.topLeft) &&
                segment.contains(drawn.bottomRight - const Offset(1, 1)),
            isTrue,
            reason: reason,
          );
          // Legible: scaled down no further than on a phone, where each row
          // has the window to itself.
          expect(
            scaleOf(id, type),
            greaterThanOrEqualTo(onPhone[type]!),
            reason: reason,
          );
        }
      }
    });

    testWidgets('a row fits at 320dp and 200% text with no overflow', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      pool = [_game('o-1', 'att-ada', _longTitle), azulMine];
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          title: _longTitle,
          occurrenceId: 'd-1',
          deadline: DateTime(2026, 10, 22, 20),
          votes: [_vote('att-ada', VoteType.forGame)],
        ),
        _nomination(
          'n-2',
          title: _longTitle,
          from: 'o-gone',
          status: NominationStatus.paused,
          pausedFrom: NominationStatus.awaitingApproval,
        ),
      ];

      await showGames(
        tester,
        detail: detailOf(policy: _policy(InterestedWeight.asAbstain)),
      );

      expect(tester.takeException(), isNull);
      for (final id in ['n-1', 'n-2']) {
        // Built only once near the view; then the whole row on screen.
        await tester.scrollUntilVisible(
          row(id),
          100,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(row(id));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: id);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: inRow(id, _longTitle),
            matching: find.byType(RichText),
          ),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: id);
        // Within the window, so nothing is cut off at its end.
        expect(tester.getRect(row(id)).right, lessThanOrEqualTo(320));
      }
    });

    testWidgets('Withdraw, beside who voted in the quick look, and its '
        'dialog fit at 320dp and 200% text', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      pool = [catanAdas, _game('o-2', 'att-me', _longTitle)];
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          title: _longTitle,
          by: 'att-me',
          from: 'o-2',
          votes: [_vote('att-ada', VoteType.forGame)],
        ),
      ];

      await showGames(tester);
      await openQuickLook(tester, 'n-1');

      expect(tester.takeException(), isNull);
      for (final control in [withdrawIn, votersIn]) {
        await tester.ensureVisible(control);
        await tester.pump();
        expect(tester.getRect(control).right, lessThanOrEqualTo(320));
      }

      await tester.tap(withdrawIn);
      await animate(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Withdraw $_longTitle?'), findsOneWidget);
      for (final button in [keepIt(), confirmWithdraw()]) {
        await tester.ensureVisible(button);
        await tester.pump();
        expect(tester.getRect(button).right, lessThanOrEqualTo(320));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets("a host's Approve, Reject and Close vote in the quick look, "
        'and their dialogs, fit at 320dp and 200% text (#518)', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final host = me.copyWith(role: EventRole.host);
      pool = [_game('o-1', 'att-ada', _longTitle), azulMine];
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          title: _longTitle,
          status: NominationStatus.awaitingApproval,
        ),
        _nomination(
          'n-2',
          title: _longTitle,
          votes: [_vote('att-ada', VoteType.forGame)],
        ),
      ];
      Finder confirm() => find.byKey(EventDetailScreen.hostDecisionConfirmKey);
      Finder notYet() => find.byKey(EventDetailScreen.hostDecisionKeepKey);

      await showGames(
        tester,
        detail: detailOf(viewer: host, roster: [host, ada, bo, unnamed]),
      );

      expect(tester.takeException(), isNull);
      for (final (id, button, title) in [
        ('n-1', approveIn, 'Approve $_longTitle?'),
        ('n-1', rejectIn, 'Reject $_longTitle?'),
        ('n-2', closeVoteIn, 'Close the vote on $_longTitle?'),
      ]) {
        await openQuickLook(tester, id);
        await tester.ensureVisible(button);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: title);
        expect(tester.getRect(button).right, lessThanOrEqualTo(320));

        await tester.tap(button);
        await animate(tester);

        expect(tester.takeException(), isNull, reason: title);
        expect(find.text(title), findsOneWidget);
        for (final choice in [notYet(), confirm()]) {
          await tester.ensureVisible(choice);
          await tester.pump();
          expect(tester.getRect(choice).right, lessThanOrEqualTo(320));
        }
        await tester.tap(notYet());
        await animate(tester);
        expect(tester.takeException(), isNull, reason: title);
        await closeQuickLook(tester);
      }
    });
  });
}

/// The page's one scroll view, whose count a screen reader reads.
CustomScrollView scrollViewOf(WidgetTester tester) =>
    tester.widget<CustomScrollView>(find.byType(CustomScrollView));
