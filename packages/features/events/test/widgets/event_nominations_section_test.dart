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
  NominationStatus status = NominationStatus.open,
  String by = 'att-bo',
  String? username,
  String from = 'o-1',
  String? occurrenceId,
  NominationStatus? pausedFrom,
  DateTime? deadline,
  List<EventNominationVote> votes = const [],
}) => EventNomination(
  id: id,
  eventId: 'e-1',
  platformGameId: 'pg-$id',
  gameId: 'g-$id',
  title: title,
  platformName: 'Tabletop',
  status: status,
  nominatedById: by,
  nominatedByUsername: username,
  suppliedFromId: from,
  occurrenceId: occurrenceId,
  pausedFrom: pausedFrom,
  votingDeadline: deadline,
  votes: votes,
  createdAt: kItemInstant,
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

  /// Event `e-1` as the viewer sees it, with [roster] (the viewer, Ada, Bo
  /// and someone unnamed by default) and [policy] on it, and on the
  /// household [householdId]'s events where it is given. Scheduled unless
  /// [status] says otherwise.
  EventDetail detailOf({
    List<EventAttendee>? roster,
    EventPolicy? policy,
    EventAttendee? viewer,
    bool viewerGiven = true,
    String? householdId,
    EventStatus status = EventStatus.scheduled,
  }) => EventDetail(
    snapshot: EventSnapshot(
      event: item('e-1', title: 'Catan night').event.copyWith(
        status: status,
        householdId: householdId,
      ),
      occurrences: [friday],
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
        remote: remote,
        householdRole: householdRole,
        onBack: (_) {},
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

  /// Shows [detail] (the viewer's, by default) and opens the Games tab, with
  /// the reads that starts ended. [householdRole] answers the viewer's role
  /// in the event's household.
  Future<void> showGames(
    WidgetTester tester, {
    EventDetail? detail,
    Future<HouseholdRole?> Function(String householdId)? householdRole,
  }) async {
    final shown = detail ?? detailOf();
    await tester.pumpWidget(harness(shown, householdRole: householdRole));
    cache.add(shown);
    await settle(tester);
    await settle(tester);
    await tester.tap(
      find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
    );
    await animate(tester);
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
      find.byKey(EventDetailScreen.nominationRowKey(id), skipOffstage: false);
  Finder inRow(String id, String text) => find.descendant(
    of: row(id),
    matching: find.text(text, skipOffstage: false),
    skipOffstage: false,
  );
  Finder retry() => find.byKey(EventDetailScreen.nominationsRetryKey);
  Finder withdraw(String id) => find.byKey(
    EventDetailScreen.nominationWithdrawKey(id),
    skipOffstage: false,
  );
  Finder confirmWithdraw() => find.byKey(EventDetailScreen.withdrawConfirmKey);
  Finder keepIt() => find.byKey(EventDetailScreen.withdrawKeepKey);
  Finder outcome() => find.byKey(EventDetailScreen.nominationsOutcomeKey);
  FocusNode withdrawFocus(WidgetTester tester) =>
      tester.widget<ButtonStyleButton>(withdraw('n-1')).focusNode!;

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

  group('rows', () {
    testWidgets('a row shows status, tally of counting votes, and who '
        'nominated it', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          votes: [
            _vote('att-ada', VoteType.forGame),
            _vote('att-bo', VoteType.forGame),
            _vote('att-me', VoteType.against),
            _vote('att-nn', VoteType.interested),
            // Not counted: the server says this one doesn't count, and this
            // client can't read the other.
            _vote('att-zz', VoteType.forGame, eligible: false),
            _vote('att-yy', VoteType.unknown),
          ],
        ),
      ];

      await showGames(tester);

      for (final line in [
        'Catan',
        'Tabletop',
        'Nominated by Bo',
        "From Ada's games",
        'For the whole event',
        'Voting',
        '2 for · 1 against · 1 interested',
      ]) {
        expect(inRow('n-1', line), findsOneWidget, reason: line);
      }
      // One node, the tally read without the symbol between its counts.
      expect(
        tester.getSemantics(inRow('n-1', 'Catan')),
        matchesSemantics(
          label:
              'Catan\nTabletop\nNominated by Bo\n'
              "From Ada's games\nFor the whole event\nVoting\n"
              '2 for, 1 against, 1 interested',
        ),
      );
      // Under a heading, which counts the rows shown.
      expect(
        tester.getSemantics(find.text('Nominations')),
        matchesSemantics(label: 'Nominations', isHeader: true),
      );
      expect(find.text('1 nomination'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the heading counts every row', (tester) async {
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

    testWidgets("the viewer's own nomination, of their own game, says so", (
      tester,
    ) async {
      nominationsAnswer = (_) => [
        _nomination('n-1', title: 'Azul', by: 'att-me', from: 'o-2'),
      ];

      await showGames(tester);

      expect(inRow('n-1', 'Nominated by you'), findsOneWidget);
      expect(inRow('n-1', 'From your games'), findsOneWidget);
    });

    testWidgets('a nominator is named from the roster, else by their '
        'username, else as this person', (tester) async {
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

      expect(inRow('n-1', 'Nominated by Bo'), findsOneWidget);
      expect(inRow('n-2', 'Nominated by zed'), findsOneWidget);
      expect(inRow('n-3', 'Nominated by this person'), findsOneWidget);
      expect(inRow('n-3', "From this person's games"), findsOneWidget);
    });

    testWidgets('a nomination for a date names it', (tester) async {
      nominationsAnswer = (_) => [
        _nomination('n-1', occurrenceId: 'd-1'),
        _nomination('n-2', title: 'Azul', from: 'o-2'),
      ];

      await showGames(tester);

      expect(inRow('n-1', 'For Fri, Nov 6 · 7:00 PM'), findsOneWidget);
      expect(inRow('n-2', 'For the whole event'), findsOneWidget);
    });

    testWidgets('each status has its label', (tester) async {
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
        expect(inRow('n-${status.name}', label), findsOneWidget, reason: label);
      }
    });

    testWidgets('the Interested line says how the event counts it, and only '
        'where its policy is known', (tester) async {
      const lines = {
        InterestedWeight.asFor: 'Interested counts as For',
        InterestedWeight.asAgainst: 'Interested counts as Against',
        InterestedWeight.asAbstain: "Interested isn't counted",
      };
      nominationsAnswer = (_) => [_nomination('n-1')];

      for (final MapEntry(key: weight, value: line) in lines.entries) {
        await tester.pumpWidget(const SizedBox());
        await showGames(tester, detail: detailOf(policy: _policy(weight)));

        expect(inRow('n-1', line), findsOneWidget, reason: line);
      }

      // No policy the viewer may read, or a weight this client can't read.
      for (final detail in [
        detailOf(),
        detailOf(policy: _policy(InterestedWeight.unknown)),
      ]) {
        await tester.pumpWidget(const SizedBox());
        await showGames(tester, detail: detail);

        expect(row('n-1'), findsOneWidget);
        for (final line in lines.values) {
          expect(inRow('n-1', line), findsNothing, reason: line);
        }
      }
    });

    testWidgets('an open nomination says when voting closes; a decided one '
        'says nothing of it', (tester) async {
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
        findsOneWidget,
      );
      expect(inRow('n-2', 'Passed'), findsOneWidget);
      expect(
        find.descendant(
          of: row('n-2'),
          matching: find.textContaining('close', skipOffstage: false),
          skipOffstage: false,
        ),
        findsNothing,
      );
    });

    testWidgets('a passed deadline says it stays open until a host closes '
        'it', (tester) async {
      nominationsAnswer = (_) => [
        _nomination('n-1', deadline: DateTime(2026, 10, 22, 20)),
      ];

      await showGames(tester);

      expect(
        inRow(
          'n-1',
          'Was due to close Thu, Oct 22 · 8:00 PM. It stays open until a '
              'host closes the vote.',
        ),
        findsOneWidget,
      );
      // Still open: a deadline closes nothing on its own.
      expect(inRow('n-1', 'Voting'), findsOneWidget);
    });

    testWidgets('a paused nomination says who left and what it goes back '
        'to', (tester) async {
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          status: NominationStatus.paused,
          pausedFrom: NominationStatus.open,
        ),
      ];

      await showGames(tester);

      expect(inRow('n-1', 'Paused'), findsOneWidget);
      expect(
        inRow(
          'n-1',
          "Paused: Ada isn't coming. It goes back to Voting if they come "
              'back.',
        ),
        findsOneWidget,
      );
    });

    testWidgets("where voting is off, the row still says the viewer's vote, "
        "and when it doesn't count", (tester) async {
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

      await showGames(tester);

      expect(inRow('n-1', 'Your vote: For'), findsOneWidget);
      expect(inRow('n-2', "Your vote: Against. It doesn't count."), findsOne);
      // No vote of the viewer's, nothing to say.
      expect(
        find.descendant(
          of: row('n-3'),
          matching: find.textContaining('Your vote', skipOffstage: false),
          skipOffstage: false,
        ),
        findsNothing,
      );
      // Open: the control says it, chosen, and the line would say it twice.
      expect(
        find.descendant(
          of: row('n-4'),
          matching: find.textContaining('Your vote:', skipOffstage: false),
          skipOffstage: false,
        ),
        findsNothing,
      );
    });

    testWidgets('a paused nomination whose supplier left names whoever '
        'brings it', (tester) async {
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

      expect(inRow('n-1', 'From whoever brings it'), findsOneWidget);
      expect(
        inRow(
          'n-1',
          "Paused: whoever brings it isn't coming. It goes back to Awaiting "
              'approval if they come back.',
        ),
        findsOneWidget,
      );
    });

    testWidgets("a paused nomination of the viewer's own game says so, and "
        'one with nothing to go back to says Unknown', (tester) async {
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

      expect(
        inRow(
          'n-1',
          "Paused: you aren't coming. It goes back to Voting if you come "
              'back.',
        ),
        findsOneWidget,
      );
      expect(
        inRow(
          'n-2',
          "Paused: Ada isn't coming. It goes back to Unknown if they come "
              'back.',
        ),
        findsOneWidget,
      );
    });
  });

  group('states', () {
    testWidgets('while the first read is out, the section is a spinner under '
        'its heading', (tester) async {
      final read = Completer<List<EventNomination>>();
      nominationsAnswer = (_) => read.future;

      await showGames(tester);

      expect(find.text('Nominations'), findsOneWidget);
      expect(find.bySemanticsLabel('Loading nominations'), findsOneWidget);
      expect(scrollViewOf(tester).semanticChildCount, 2);

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
        find.text('Nominate a game from the games pool below.'),
        findsOneWidget,
      );
      // Nothing to count.
      expect(find.textContaining('nominations'), findsNothing);
    });

    testWidgets("none nominated, for a viewer who can't nominate, says so "
        'and points nowhere', (tester) async {
      // Only the hosts add games.
      await showGames(
        tester,
        detail: detailOf(
          policy: _policy(
            InterestedWeight.asFor,
          ).copyWith(gameAdditionMode: GameAdditionMode.hostOnly),
        ),
      );

      expect(find.text('Nothing nominated yet'), findsOneWidget);
      expect(
        find.text('Nominate a game from the games pool below.'),
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

    testWidgets('nominations show where the games are hidden', (tester) async {
      // A roster read and withheld, with no row of the viewer's: nobody to
      // read the pool for. The nominations are the event's.
      nominationsAnswer = (_) => [_nomination('n-1')];

      await showGames(
        tester,
        detail: detailOf(roster: const [], viewerGiven: false),
      );

      expect(find.text("The games aren't shown to you"), findsOneWidget);
      expect(row('n-1'), findsOneWidget);
      // Nobody named, and no pool to find the game in.
      expect(inRow('n-1', 'Nominated by this person'), findsOneWidget);
      expect(inRow('n-1', 'From whoever brings it'), findsOneWidget);
    });
  });

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

    testWidgets('Withdraw asks first and sends on confirm', (tester) async {
      nominationsAnswer = (_) => [mine()];

      await showGames(tester);
      await press(tester, withdraw('n-1'));
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
      // The answer takes the row's place, and the footer says so.
      expect(inRow('n-1', 'Withdrawn'), findsOneWidget);
      expect(withdraw('n-1'), findsNothing);
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
      await tester.ensureVisible(withdraw('n-1'));
      await tester.pump();
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
      expect(inRow('n-1', 'Voting'), findsOneWidget);
      // Back on Withdraw, which can be pressed again.
      expect(focus.hasPrimaryFocus, isTrue);
      expect(tester.widget<TextButton>(withdraw('n-1')).onPressed, isNotNull);
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
        expect(row(id), findsOneWidget, reason: id);
        expect(withdraw(id), findsNothing, reason: id);
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
        expect(
          withdraw('n-${status.name}'),
          built ? findsOneWidget : findsNothing,
          reason: status.name,
        );
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

      expect(row('n-1'), findsOneWidget);
      expect(withdraw('n-1'), findsNothing);
    });

    for (final status in [EventStatus.cancelled, EventStatus.archived]) {
      testWidgets("Withdraw isn't built on a ${status.name} event", (
        tester,
      ) async {
        nominationsAnswer = (_) => [mine()];

        await showGames(tester, detail: detailOf(status: status));

        expect(row('n-1'), findsOneWidget);
        expect(withdraw('n-1'), findsNothing);
      });
    }

    testWidgets('a withdrawal is dropped where the event was cancelled while '
        'it asked, and the footer says so', (tester) async {
      nominationsAnswer = (_) => [mine()];

      await showGames(tester);
      await press(tester, withdraw('n-1'));
      await animate(tester);

      // Cancelled while the dialog was open.
      cache.add(detailOf(status: EventStatus.cancelled));
      await settle(tester);
      await tester.tap(confirmWithdraw());
      await animate(tester);

      expect(remote.withdrawals, isEmpty);
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text(
            "Azul wasn't withdrawn: something changed on this event first.",
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Withdraw names its game to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [mine()];

      await showGames(tester);
      await tester.ensureVisible(withdraw('n-1'));
      await tester.pump();

      expect(
        tester.getSemantics(withdraw('n-1')),
        isSemantics(
          label: 'Withdraw Azul',
          isButton: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a withdrawal dropped by the re-check says so in the footer', (
      tester,
    ) async {
      nominationsAnswer = (_) => [mine()];

      await showGames(tester);
      await press(tester, withdraw('n-1'));
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
        find.descendant(
          of: outcome(),
          matching: find.text(
            "Azul wasn't withdrawn: something changed on this event first.",
          ),
        ),
        findsOneWidget,
      );
    });

    group('after a withdrawal, focus stays on its row', () {
      /// The row's lines, as one node.
      SemanticsNode lines(WidgetTester tester) =>
          tester.getSemantics(inRow('n-1', 'Azul'));

      testWidgets('from the keyboard', (tester) async {
        final handle = tester.ensureSemantics();
        final sent = Completer<EventNomination>();
        withdrawAnswer = (_) => sent.future;
        nominationsAnswer = (_) => [mine()];

        await showGames(tester);
        await tester.ensureVisible(withdraw('n-1'));
        await tester.pump();
        final focus = withdrawFocus(tester)..requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        // Keep it, then Withdraw.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);

        // Held while it is out, so it keeps focus (#607).
        expect(remote.withdrawals, hasLength(1));
        expect(focus.hasPrimaryFocus, isTrue);

        sent.complete(mine(status: NominationStatus.withdrawn));
        await animate(tester);

        expect(withdraw('n-1'), findsNothing);
        expect(
          lines(tester),
          isSemantics(isFocusable: true, isFocused: true),
        );
        expect(lines(tester).label, contains('Withdrawn'));

        // Tab goes on from the row, and the row is no stop of its own.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(lines(tester), isSemantics(isFocusable: false));
        handle.dispose();
      });

      testWidgets("from a screen reader's activation, with focus on nothing", (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        nominationsAnswer = (_) => [mine()];

        await showGames(tester);
        await tester.ensureVisible(withdraw('n-1'));
        await tester.pump();
        screenReaderTap(tester, 'Withdraw Azul');
        await animate(tester);
        screenReaderTap(tester, 'Withdraw');
        await animate(tester);

        expect(remote.withdrawals, hasLength(1));
        expect(lines(tester), isSemantics(isFocused: true));
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
        await press(tester, withdraw('n-1'));
        await animate(tester);
        await tester.tap(confirmWithdraw());
        await animate(tester);
        final elsewhere = Focus.of(
          tester.element(
            find.byKey(
              EventDetailScreen.tabKey(EventDetailTab.games),
              skipOffstage: false,
            ),
          ),
        )..requestFocus();
        await tester.pump();

        sent.complete(mine(status: NominationStatus.withdrawn));
        await animate(tester);

        expect(elsewhere.hasPrimaryFocus, isTrue);
        expect(lines(tester), isSemantics(isFocused: false));
        handle.dispose();
      });

      testWidgets('nowhere new when it is refused: Withdraw keeps it', (
        tester,
      ) async {
        withdrawAnswer = (_) =>
            throw const EventWriteRefusedException('no', statusCode: 403);
        nominationsAnswer = (_) => [mine()];

        await showGames(tester);
        await tester.ensureVisible(withdraw('n-1'));
        await tester.pump();
        final focus = withdrawFocus(tester)..requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);
        await tester.tap(confirmWithdraw());
        await animate(tester);

        expect(remote.withdrawals, hasLength(1));
        expect(
          find.descendant(
            of: outcome(),
            matching: find.text("You can't withdraw Azul."),
          ),
          findsOneWidget,
        );
        expect(focus.hasPrimaryFocus, isTrue);
        expect(
          tester.widget<TextButton>(withdraw('n-1')).onPressed,
          isNotNull,
        );
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

      await tester.pumpWidget(
        harness(detailOf(), offline: offline),
      );
      cache.add(detailOf());
      await settle(tester);
      await settle(tester);
      await tester.tap(
        find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
      );
      await animate(tester);
      await tester.ensureVisible(withdraw('n-1'));
      await tester.pump();

      expect(tester.widget<TextButton>(withdraw('n-1')).onPressed, isNull);
      expect(
        tester.getSemantics(withdraw('n-1')),
        isSemantics(hint: _onlineOnlyCopy, isEnabled: false),
      );
      expect(
        find.descendant(of: row('n-1'), matching: find.text(_onlineOnlyCopy)),
        findsOneWidget,
      );

      offline.value = false;
      await tester.pump();

      expect(
        find.descendant(of: row('n-1'), matching: find.text(_onlineOnlyCopy)),
        findsNothing,
      );
      expect(tester.widget<TextButton>(withdraw('n-1')).onPressed, isNotNull);
      handle.dispose();
    });
  });

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

    Finder approve(String id) => find.byKey(
      EventDetailScreen.nominationApproveKey(id),
      skipOffstage: false,
    );
    Finder reject(String id) => find.byKey(
      EventDetailScreen.nominationRejectKey(id),
      skipOffstage: false,
    );
    Finder closeVote(String id) => find.byKey(
      EventDetailScreen.nominationCloseVoteKey(id),
      skipOffstage: false,
    );
    Finder confirmDecision() =>
        find.byKey(EventDetailScreen.hostDecisionConfirmKey);
    Finder notYet() => find.byKey(EventDetailScreen.hostDecisionKeepKey);
    Finder inOutcome(String text) =>
        find.descendant(of: outcome(), matching: find.text(text));
    FocusNode focusOf(WidgetTester tester, Finder button) =>
        tester.widget<ButtonStyleButton>(button).focusNode!;
    VoidCallback? pressOf(WidgetTester tester, Finder button) =>
        tester.widget<TextButton>(button).onPressed;

    testWidgets('Approve asks first and sends on confirm', (tester) async {
      nominationsAnswer = (_) => [catan()];

      await showGames(tester, detail: as(host));
      await press(tester, approve('n-1'));
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
      // The answer takes the row's place, with neither decision left, and
      // the footer says so.
      expect(inRow('n-1', 'Approved'), findsOneWidget);
      expect(approve('n-1'), findsNothing);
      expect(reject('n-1'), findsNothing);
      expect(
        inOutcome('Catan is approved and in the lineup.'),
        findsOneWidget,
      );
    });

    testWidgets('Reject asks first, as a destructive action, and sends on '
        'confirm', (tester) async {
      nominationsAnswer = (_) => [catan()];

      await showGames(tester, detail: as(host));
      await press(tester, reject('n-1'));
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
      expect(inRow('n-1', 'Rejected'), findsOneWidget);
      expect(approve('n-1'), findsNothing);
      expect(reject('n-1'), findsNothing);
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
      await press(tester, closeVote('n-1'));
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
      expect(inRow('n-1', 'Passed'), findsOneWidget);
      expect(closeVote('n-1'), findsNothing);
      // The resolve's reasons, which no later read carries.
      expect(
        inOutcome('Catan passed: 2 for, 1 against. 3 of 4 counted.'),
        findsOneWidget,
      );
    });

    testWidgets("Close vote's dialog says how the event counts Interested, "
        'as the row does', (tester) async {
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
        // The row's line, where there is one.
        expect(
          line == null
              ? find.textContaining('Interested ')
              : inRow('n-1', line),
          line == null ? findsNothing : findsOneWidget,
          reason: weight.name,
        );

        await press(tester, closeVote('n-1'));
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
      for (final (button, title) in [
        (approve('n-1'), 'Approve Catan?'),
        (reject('n-1'), 'Reject Catan?'),
        (closeVote('n-2'), 'Close the vote on Azul?'),
      ]) {
        await tester.ensureVisible(button);
        await tester.pump();
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
      }
      expect(remote.approvals, isEmpty);
      expect(remote.rejections, isEmpty);
      expect(remote.resolutions, isEmpty);
      expect(outcome(), findsNothing);
      expect(inRow('n-1', 'Awaiting approval'), findsOneWidget);
      expect(inRow('n-2', 'Voting'), findsOneWidget);
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
        final id = 'n-${status.name}';
        final awaiting = status == NominationStatus.awaitingApproval;
        expect(row(id), findsOneWidget, reason: status.name);
        expect(
          approve(id),
          awaiting ? findsOneWidget : findsNothing,
          reason: status.name,
        );
        expect(
          reject(id),
          awaiting ? findsOneWidget : findsNothing,
          reason: status.name,
        );
        expect(
          closeVote(id),
          status == NominationStatus.open ? findsOneWidget : findsNothing,
          reason: status.name,
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
        expect(row(id), findsOneWidget, reason: id);
        expect(inRow(id, 'Paused'), findsOneWidget, reason: id);
        expect(approve(id), findsNothing, reason: id);
        expect(reject(id), findsNothing, reason: id);
        expect(closeVote(id), findsNothing, reason: id);
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

      expect(closeVote('n-1'), findsOneWidget);
      expect(approve('n-2'), findsNothing);
      expect(reject('n-2'), findsNothing);

      await press(tester, closeVote('n-1'));
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

      expect(closeVote('n-1'), findsOneWidget);
      expect(approve('n-2'), findsNothing);
      expect(reject('n-2'), findsNothing);

      await press(tester, closeVote('n-1'));
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

      expect(closeVote('n-1'), findsNothing);
      expect(approve('n-2'), findsNothing);
      expect(reject('n-2'), findsNothing);
    });

    testWidgets('each names its game to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      nominationsAnswer = (_) => [
        catan(),
        _nomination('n-2', title: 'Azul', from: 'o-2'),
      ];

      await showGames(tester, detail: as(host));

      for (final (button, label) in [
        (approve('n-1'), 'Approve Catan'),
        (reject('n-1'), 'Reject Catan'),
        (closeVote('n-2'), 'Close the vote on Azul'),
      ]) {
        await tester.ensureVisible(button);
        await tester.pump();
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
      handle.dispose();
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

        expect(row('n-1'), findsOneWidget);
        expect(row('n-2'), findsOneWidget);
        expect(approve('n-1'), findsNothing);
        expect(reject('n-1'), findsNothing);
        expect(closeVote('n-2'), findsNothing);
      });
    }

    testWidgets('a decision is dropped where the event was cancelled while '
        'it asked, and the footer says so', (tester) async {
      nominationsAnswer = (_) => [catan()];

      await showGames(tester, detail: as(host));
      await press(tester, approve('n-1'));
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

    testWidgets('a decision dropped by the re-check says so in the footer', (
      tester,
    ) async {
      nominationsAnswer = (_) => [catan()];

      await showGames(tester, detail: as(host));
      await press(tester, approve('n-1'));
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
      await press(tester, closeVote('n-1'));
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
      await press(tester, closeVote('n-1'));
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
      await press(tester, closeVote('n-1'));
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
      await press(tester, closeVote('n-1'));
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
      await tester.ensureVisible(approve('n-1'));
      await tester.pump();
      final focus = focusOf(tester, approve('n-1'))..requestFocus();
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
      expect(inRow('n-1', 'Approved'), findsOneWidget);
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
      heldRead = Completer<EventSnapshot>();
      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);

      for (final button in [approve('n-1'), reject('n-1'), closeVote('n-2')]) {
        expect(pressOf(tester, button), isNull, reason: '$button');
      }

      heldRead!.complete(as(host).snapshot);
      heldRead = null;
      await animate(tester);
      for (final button in [approve('n-1'), reject('n-1'), closeVote('n-2')]) {
        expect(pressOf(tester, button), isNotNull, reason: '$button');
      }

      await press(tester, approve('n-1'));
      await animate(tester);
      await tester.tap(confirmDecision());
      await animate(tester);

      expect(remote.approvals, hasLength(1));
      for (final button in [reject('n-1'), closeVote('n-2')]) {
        expect(pressOf(tester, button), isNull, reason: '$button');
      }

      sent.complete(catan(status: NominationStatus.approved));
      await animate(tester);

      expect(pressOf(tester, closeVote('n-2')), isNotNull);
    });

    testWidgets('disabled offline, saying why once under each row', (
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

      await tester.pumpWidget(harness(as(host), offline: offline));
      cache.add(as(host));
      await settle(tester);
      await settle(tester);
      await tester.tap(
        find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
      );
      await animate(tester);

      for (final button in [approve('n-1'), reject('n-1'), closeVote('n-2')]) {
        expect(pressOf(tester, button), isNull, reason: '$button');
        expect(
          tester.getSemantics(button),
          isSemantics(hint: _onlineOnlyCopy, isEnabled: false),
          reason: '$button',
        );
      }
      for (final id in ['n-1', 'n-2']) {
        expect(
          find.descendant(of: row(id), matching: find.text(_onlineOnlyCopy)),
          findsOneWidget,
          reason: id,
        );
      }

      offline.value = false;
      await tester.pump();

      expect(
        find.descendant(
          of: row('n-1'),
          matching: find.text(_onlineOnlyCopy),
        ),
        findsNothing,
      );
      for (final button in [approve('n-1'), reject('n-1'), closeVote('n-2')]) {
        expect(pressOf(tester, button), isNotNull, reason: '$button');
      }
      handle.dispose();
    });

    group('after a decision, focus stays on its row', () {
      /// The row's lines, as one node.
      SemanticsNode lines(WidgetTester tester) =>
          tester.getSemantics(inRow('n-1', 'Catan'));

      testWidgets('from the keyboard', (tester) async {
        final handle = tester.ensureSemantics();
        final sent = Completer<EventNomination>();
        approveAnswer = (_) => sent.future;
        nominationsAnswer = (_) => [catan()];

        await showGames(tester, detail: as(host));
        await tester.ensureVisible(approve('n-1'));
        await tester.pump();
        final focus = focusOf(tester, approve('n-1'))..requestFocus();
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

        expect(approve('n-1'), findsNothing);
        expect(
          lines(tester),
          isSemantics(isFocusable: true, isFocused: true),
        );
        expect(lines(tester).label, contains('Approved'));

        // Tab goes on from the row, and the row is no stop of its own.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(lines(tester), isSemantics(isFocusable: false));
        handle.dispose();
      });

      testWidgets("from a screen reader's activation, with focus on nothing", (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        nominationsAnswer = (_) => [catan(status: NominationStatus.open)];

        await showGames(tester, detail: as(host));
        await tester.ensureVisible(closeVote('n-1'));
        await tester.pump();
        screenReaderTap(tester, 'Close the vote on Catan');
        await animate(tester);
        screenReaderTap(tester, 'Close vote');
        await animate(tester);

        expect(remote.resolutions, hasLength(1));
        expect(lines(tester), isSemantics(isFocused: true));
        expect(lines(tester).label, contains('Passed'));
        handle.dispose();
      });

      testWidgets('nowhere new when it is refused: the button keeps it', (
        tester,
      ) async {
        rejectAnswer = (_) =>
            throw const EventWriteRefusedException('no', statusCode: 403);
        nominationsAnswer = (_) => [catan()];

        await showGames(tester, detail: as(host));
        await tester.ensureVisible(reject('n-1'));
        await tester.pump();
        final focus = focusOf(tester, reject('n-1'))..requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);
        await tester.tap(confirmDecision());
        await animate(tester);

        expect(remote.rejections, hasLength(1));
        expect(inOutcome("You can't decide on Catan."), findsOneWidget);
        expect(focus.hasPrimaryFocus, isTrue);
        expect(pressOf(tester, reject('n-1')), isNotNull);
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
      // The rows shown: two nominations, then the pool's two.
      expect(scrollViewOf(tester).semanticChildCount, 4);
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
      // The pool's rows alone.
      expect(scrollViewOf(tester).semanticChildCount, 2);

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

      /// The For choice of [id]'s vote, as focus finds it.
      FocusNode forOf(WidgetTester tester, String id) => Focus.of(
        tester.element(
          find.byKey(
            EventDetailScreen.nominationVoteKey(id, VoteType.forGame),
            skipOffstage: false,
          ),
        ),
      );

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

      /// Withdraws Azul from the keyboard: Withdraw, then the dialog's
      /// Withdraw, reached by Tab.
      Future<void> withdrawByKeyboard(WidgetTester tester) async {
        withdrawFocus(tester).requestFocus();
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

      testWidgets("a withdrawal hands focus to the next row's first control", (
        tester,
      ) async {
        await showVoting(tester, [azul, catan]);

        await withdrawByKeyboard(tester);

        expect(remote.withdrawals, hasLength(1));
        expect(rowsShown(tester), ['n-2']);
        expect(forOf(tester, 'n-2').hasPrimaryFocus, isTrue);
      });

      testWidgets("a withdrawal by a screen reader's activation, with focus "
          'on nothing, hands it on too', (tester) async {
        final handle = tester.ensureSemantics();
        await showVoting(tester, [azul, catan]);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();

        screenReaderTap(tester, 'Withdraw Azul');
        await animate(tester);
        screenReaderTap(tester, 'Withdraw');
        await animate(tester);

        expect(rowsShown(tester), ['n-2']);
        expect(forOf(tester, 'n-2').hasPrimaryFocus, isTrue);
        handle.dispose();
      });

      testWidgets('from the last row shown, to the one before', (
        tester,
      ) async {
        await showVoting(tester, [catan, azul]);

        await withdrawByKeyboard(tester);

        expect(rowsShown(tester), ['n-2']);
        expect(forOf(tester, 'n-2').hasPrimaryFocus, isTrue);
      });

      testWidgets("a vote under Not voted yet hands focus to the next row's "
          'first control', (tester) async {
        useViewSize(tester, const Size(800, 3200));
        nominationsAnswer = (_) => [catan, _nomination('n-3', title: 'Root')];
        nominationAnswer = (_) => catan.copyWith(
          votes: [_vote('att-me', VoteType.forGame)],
        );
        await showGames(tester);
        await filterBy(tester, [EventDetailScreen.nominationsNotVotedKey]);
        expect(rowsShown(tester), ['n-2', 'n-3']);

        forOf(tester, 'n-2').requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await animate(tester);

        expect(remote.votes, hasLength(1));
        expect(rowsShown(tester), ['n-3']);
        expect(forOf(tester, 'n-3').hasPrimaryFocus, isTrue);
      });

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

      testWidgets("a host's approval by a screen reader's activation, under "
          'Awaiting approval, hands focus to the next row (#518)', (
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
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();

        screenReaderTap(tester, 'Approve Catan');
        await animate(tester);
        screenReaderTap(tester, 'Approve');
        await animate(tester);

        expect(remote.approvals, hasLength(1));
        expect(rowsShown(tester), ['n-2']);
        expect(
          tester
              .widget<ButtonStyleButton>(
                find.byKey(EventDetailScreen.nominationApproveKey('n-2')),
              )
              .focusNode!
              .hasPrimaryFocus,
          isTrue,
        );
        handle.dispose();
      });

      testWidgets('from the only row shown, to Filters', (tester) async {
        await showVoting(tester, [azul]);
        // Last on Sort, where Flutter would put focus back on its own.
        tester.widget<ButtonStyleButton>(sort()).focusNode!.requestFocus();
        await tester.pump();

        await withdrawByKeyboard(tester);

        expect(find.text('No nominations match'), findsOneWidget);
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

  group('accessibility audit', () {
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

    testWidgets('Withdraw, beside who voted, and its dialog fit at 320dp and '
        '200% text', (tester) async {
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
      await tester.ensureVisible(withdraw('n-1'));
      await tester.pump();

      expect(tester.takeException(), isNull);
      for (final control in [
        withdraw('n-1'),
        find.byKey(EventDetailScreen.nominationVotersKey('n-1')),
      ]) {
        expect(tester.getRect(control).right, lessThanOrEqualTo(320));
      }

      await tester.tap(withdraw('n-1'));
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

    testWidgets("a host's Approve, Reject and Close vote, and their dialogs, "
        'fit at 320dp and 200% text (#518)', (tester) async {
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
      for (final (button, title) in [
        (
          find.byKey(EventDetailScreen.nominationApproveKey('n-1')),
          'Approve $_longTitle?',
        ),
        (
          find.byKey(EventDetailScreen.nominationRejectKey('n-1')),
          'Reject $_longTitle?',
        ),
        (
          find.byKey(
            EventDetailScreen.nominationCloseVoteKey('n-2'),
            skipOffstage: false,
          ),
          'Close the vote on $_longTitle?',
        ),
      ]) {
        await tester.scrollUntilVisible(
          button,
          100,
          scrollable: find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
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
      }
    });
  });
}

/// The page's one scroll view, whose count a screen reader reads.
CustomScrollView scrollViewOf(WidgetTester tester) =>
    tester.widget<CustomScrollView>(find.byType(CustomScrollView));
