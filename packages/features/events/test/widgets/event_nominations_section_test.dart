import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
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
  /// and someone unnamed by default) and [policy] on it.
  EventDetail detailOf({
    List<EventAttendee>? roster,
    EventPolicy? policy,
    EventAttendee? viewer,
    bool viewerGiven = true,
  }) => EventDetail(
    snapshot: EventSnapshot(
      event: item(
        'e-1',
        title: 'Catan night',
      ).event.copyWith(status: EventStatus.scheduled),
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
  });

  tearDown(() {
    unawaited(cache.close());
  });

  Widget harness(EventDetail detail) {
    remote = FakeEventRemote.detail(
      (_) => detail.snapshot,
      pool: (_) => pool,
      nominations: (eventId) => nominationsAnswer(eventId),
    );
    return MaterialApp(
      theme: BgeTheme.light(),
      locale: const Locale('en', 'US'),
      localizationsDelegates: EventsLocalizations.localizationsDelegates,
      supportedLocales: EventsLocalizations.supportedLocales,
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
  });
}

/// The page's one scroll view, whose count a screen reader reads.
CustomScrollView scrollViewOf(WidgetTester tester) =>
    tester.widget<CustomScrollView>(find.byType(CustomScrollView));
