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
  /// and someone unnamed by default) and [policy] on it. Scheduled unless
  /// [status] says otherwise.
  EventDetail detailOf({
    List<EventAttendee>? roster,
    EventPolicy? policy,
    EventAttendee? viewer,
    bool viewerGiven = true,
    EventStatus status = EventStatus.scheduled,
  }) => EventDetail(
    snapshot: EventSnapshot(
      event: item(
        'e-1',
        title: 'Catan night',
      ).event.copyWith(status: status),
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
  });

  tearDown(() {
    unawaited(cache.close());
  });

  Widget harness(EventDetail detail, {ValueListenable<bool>? offline}) {
    remote = FakeEventRemote.detail(
      (_) => detail.snapshot,
      pool: (_) => pool,
      nominations: (eventId) => nominationsAnswer(eventId),
      nomination: (request) => nominationAnswer(request),
      voteCast: (_) {},
      withdrawn: (request) => withdrawAnswer(request),
    );
    return MaterialApp(
      theme: BgeTheme.light(),
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
  /// the reads that starts ended.
  Future<void> showGames(WidgetTester tester, {EventDetail? detail}) async {
    final shown = detail ?? detailOf();
    await tester.pumpWidget(harness(shown));
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

    group('a vote or withdrawal that takes its row out of the filter', () {
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
  });
}

/// The page's one scroll view, whose count a screen reader reads.
CustomScrollView scrollViewOf(WidgetTester tester) =>
    tester.widget<CustomScrollView>(find.byType(CustomScrollView));
