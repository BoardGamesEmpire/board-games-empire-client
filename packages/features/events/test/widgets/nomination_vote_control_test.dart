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
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';
import '../support/fake_event_remote.dart';
import '../support/kept_nominations.dart';

class _MockEventRepository extends Mock implements EventRepository {}

const _onlineOnlyCopy = "Available when you're online";
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
  String? comment,
}) => EventNominationVote(
  id: 'v-$attendeeId',
  attendeeId: attendeeId,
  voteType: type,
  eligible: eligible,
  comment: comment,
);

/// A nomination of `e-1`, by Bo from Ada's Catan (`o-1`), open for votes,
/// unless a test says otherwise.
EventNomination _nomination(
  String id, {
  String title = 'Catan',
  NominationStatus status = NominationStatus.open,
  List<EventNominationVote> votes = const [],
}) => EventNomination(
  id: id,
  eventId: 'e-1',
  platformGameId: 'pg-$id',
  gameId: 'g-$id',
  title: title,
  platformName: 'Tabletop',
  status: status,
  nominatedById: 'att-bo',
  suppliedFromId: 'o-1',
  votes: votes,
  createdAt: kItemInstant,
);

/// `e-1`'s policy, counting the votes of [eligibility].
EventPolicy _policy(VoteEligibility eligibility) => EventPolicy(
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
  voteEligibility: eligibility,
  interestedWeight: InterestedWeight.asAbstain,
  createdAt: kItemInstant,
  updatedAt: kItemInstant,
);

/// Voting on a nomination (#517): the For / Against / Interested control on
/// each open row of the Games tab's Nominations section, the note that goes
/// with a vote, and the line that says when the viewer's vote won't count.
void main() {
  // Local, as the device's clock reads it.
  final now = DateTime(2026, 10, 23, 18);

  late _MockEventRepository repository;
  late StreamController<EventDetail?> cache;
  late FakeEventRemote remote;

  /// What the fake server answered writes and single reads with, which its
  /// list reads serve.
  final kept = KeptNominations();

  /// What each nominations list read answers.
  late FutureOr<List<EventNomination>> Function(String eventId)
  nominationsAnswer;

  /// What each read of one nomination answers: after a vote.
  late FutureOr<EventNomination> Function(NominationRequest request)
  nominationAnswer;

  /// What each vote answers.
  late FutureOr<void> Function(CastVoteRequest request) voteAnswer;

  /// What each read of the pool answers: Ada's Catan, by default.
  late FutureOr<List<OfferedGame>> Function(GamesPoolRequest request)
  poolAnswer;

  /// Holds the detail's reads open while a test sets it.
  Completer<EventSnapshot>? heldRead;

  final me = _row('att-me', name: 'Me');
  final ada = _row('att-ada', name: 'Ada');
  final bo = _row('att-bo', name: 'Bo');

  /// Event `e-1` as [viewer] (the viewer, a participant, by default) sees
  /// it, with [policy] on it, and Scheduled unless [status] says otherwise.
  EventDetail detailOf({
    EventAttendee? viewer,
    EventPolicy? policy,
    EventStatus status = EventStatus.scheduled,
  }) {
    final shown = viewer ?? me;
    return EventDetail(
      snapshot: EventSnapshot(
        event: item(
          'e-1',
          title: 'Catan night',
        ).event.copyWith(status: status),
        occurrences: const [],
        attendees: [shown, ada, bo],
        policy: policy,
      ),
      attendance: shown,
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
    nominationsAnswer = (_) => [_nomination('n-1')];
    nominationAnswer = (request) => _nomination(request.nominationId);
    voteAnswer = (_) {};
    poolAnswer = (_) => [_game('o-1', 'att-ada', 'Catan')];
    heldRead = null;
  });

  tearDown(() {
    unawaited(cache.close());
  });

  Widget harness(EventDetail detail, {ValueListenable<bool>? offline}) {
    remote = FakeEventRemote.detail(
      (_) => heldRead?.future ?? detail.snapshot,
      pool: (request) => poolAnswer(request),
      nominations: (eventId) async =>
          kept.over(await nominationsAnswer(eventId)),
      nomination: (request) async => kept.keep(await nominationAnswer(request)),
      voteCast: (request) => voteAnswer(request),
    );
    addTearDown(kept.clear);
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
  Future<void> showGames(
    WidgetTester tester, {
    EventDetail? detail,
    ValueListenable<bool>? offline,
  }) async {
    final shown = detail ?? detailOf();
    await tester.pumpWidget(harness(shown, offline: offline));
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

  Finder row(String id) =>
      find.byKey(EventDetailScreen.nominationRowKey(id), skipOffstage: false);
  Finder inRow(String id, String text) => find.descendant(
    of: row(id),
    matching: find.text(text, skipOffstage: false),
    skipOffstage: false,
  );
  Finder vote(String id, VoteType type) =>
      find.byKey(EventDetailScreen.nominationVoteKey(id, type));
  Finder note(String id) => find.byKey(EventDetailScreen.nominationNoteKey(id));
  Finder control(String id) => find.descendant(
    of: row(id),
    matching: find.byType(SegmentedButton<VoteType>),
  );
  Finder outcome() => find.byKey(EventDetailScreen.nominationsOutcomeKey);

  /// The button a vote's choice sits in.
  TextButton segment(WidgetTester tester, String id, VoteType type) =>
      tester.widget<TextButton>(
        find.ancestor(of: vote(id, type), matching: find.byType(TextButton)),
      );

  /// The votes the control shows as chosen.
  Set<VoteType> chosen(WidgetTester tester, String id) =>
      tester.widget<SegmentedButton<VoteType>>(control(id)).selected;

  Future<void> press(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  group('voting', () {
    testWidgets('tapping For sends a For vote', (tester) async {
      nominationAnswer = (request) => _nomination(
        request.nominationId,
        votes: [_vote('att-me', VoteType.forGame)],
      );

      await showGames(tester);

      expect(chosen(tester, 'n-1'), isEmpty);
      for (final type in [
        VoteType.forGame,
        VoteType.against,
        VoteType.interested,
      ]) {
        expect(vote('n-1', type), findsOneWidget, reason: type.name);
      }

      await press(tester, vote('n-1', VoteType.forGame));
      await animate(tester);

      expect(remote.votes, [
        (
          eventId: 'e-1',
          nominationId: 'n-1',
          voteType: VoteType.forGame,
          comment: null,
        ),
      ]);
      // Read back, the row shows the vote cast, and the footer says so.
      expect(chosen(tester, 'n-1'), {VoteType.forGame});
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text('Your vote on Catan is in.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('tapping the selected vote sends nothing', (tester) async {
      nominationsAnswer = (_) => [
        _nomination('n-1', votes: [_vote('att-me', VoteType.forGame)]),
      ];

      await showGames(tester);
      expect(chosen(tester, 'n-1'), {VoteType.forGame});

      await press(tester, vote('n-1', VoteType.forGame));
      await animate(tester);

      // A vote can't be taken back, so the control never clears.
      expect(remote.votes, isEmpty);
      expect(chosen(tester, 'n-1'), {VoteType.forGame});
      expect(outcome(), findsNothing);
    });

    testWidgets("the control isn't built for a guest", (tester) async {
      await showGames(
        tester,
        detail: detailOf(
          viewer: _row('att-me', name: 'Me', role: EventRole.guest),
        ),
      );

      expect(row('n-1'), findsOneWidget);
      expect(control('n-1'), findsNothing);
      expect(note('n-1'), findsNothing);
    });

    testWidgets("the control isn't built on a nomination that isn't open", (
      tester,
    ) async {
      nominationsAnswer = (_) => [
        _nomination('n-1', status: NominationStatus.awaitingApproval),
        _nomination('n-2', title: 'Azul', status: NominationStatus.paused),
        _nomination('n-3', title: 'Root', status: NominationStatus.passed),
      ];
      useViewSize(tester, const Size(800, 2400));

      await showGames(tester);

      for (final id in ['n-1', 'n-2', 'n-3']) {
        expect(row(id), findsOneWidget, reason: id);
        expect(control(id), findsNothing, reason: id);
        expect(note(id), findsNothing, reason: id);
      }
    });

    for (final status in [EventStatus.cancelled, EventStatus.archived]) {
      testWidgets("the control isn't built on a ${status.name} event", (
        tester,
      ) async {
        nominationsAnswer = (_) => [
          _nomination('n-1', votes: [_vote('att-me', VoteType.forGame)]),
        ];

        await showGames(tester, detail: detailOf(status: status));

        expect(row('n-1'), findsOneWidget);
        expect(control('n-1'), findsNothing);
        expect(note('n-1'), findsNothing);
      });
    }

    testWidgets('a vote is dropped where the event was cancelled while it '
        'waited, and the footer says so', (tester) async {
      await showGames(tester);
      // On screen before the read starts, so the press needs no frame.
      await tester.ensureVisible(control('n-1'));
      await tester.pump();
      final detail = blocOf<EventDetailBloc>(tester);
      heldRead = Completer<EventSnapshot>();

      // A read starts, and the press lands before a frame shows it.
      detail.add(const EventDetailRetryRequested());
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      expect((detail.state as EventDetailReady).reading, isTrue);
      await tester.tap(vote('n-1', VoteType.forGame));

      // Meanwhile a sync brings the event cancelled.
      final cancelled = detailOf(status: EventStatus.cancelled);
      cache.add(cancelled);
      await settle(tester);
      heldRead!.complete(cancelled.snapshot);
      heldRead = null;
      await animate(tester);

      expect(remote.votes, isEmpty);
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text(
            "Your vote on Catan wasn't sent: something changed on this event "
            'first.',
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the control is disabled offline with its reason', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      nominationsAnswer = (_) => [
        _nomination('n-1', votes: [_vote('att-me', VoteType.against)]),
      ];

      await showGames(tester, offline: offline);
      await tester.ensureVisible(control('n-1'));
      await tester.pump();

      for (final type in [
        VoteType.forGame,
        VoteType.against,
        VoteType.interested,
      ]) {
        expect(segment(tester, 'n-1', type).onPressed, isNull);
        expect(
          tester.getSemantics(vote('n-1', type)),
          isSemantics(
            hint: _onlineOnlyCopy,
            isButton: true,
            hasEnabledState: true,
            isEnabled: false,
          ),
          reason: type.name,
        );
      }
      // Shown, not cleared, while it can't be changed.
      expect(chosen(tester, 'n-1'), {VoteType.against});
      expect(
        tester.getSemantics(note('n-1')),
        isSemantics(hint: _onlineOnlyCopy, isEnabled: false),
      );
      // Drawn once for the row's controls.
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
      expect(segment(tester, 'n-1', VoteType.forGame).onPressed, isNotNull);
      handle.dispose();
    });

    testWidgets('the control is disabled while a detail read runs', (
      tester,
    ) async {
      await showGames(tester);
      heldRead = Completer<EventSnapshot>();

      blocOf<EventDetailBloc>(tester).add(const EventDetailRetryRequested());
      await settle(tester);

      expect(segment(tester, 'n-1', VoteType.forGame).onPressed, isNull);

      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);

      expect(segment(tester, 'n-1', VoteType.forGame).onPressed, isNotNull);
    });

    testWidgets('the pressed vote keeps focus while it is sent, and the '
        'others wait', (tester) async {
      final sent = Completer<void>();
      voteAnswer = (_) => sent.future;
      nominationAnswer = (request) => _nomination(
        request.nominationId,
        votes: [_vote('att-me', VoteType.against)],
      );

      await showGames(tester);
      await tester.ensureVisible(control('n-1'));
      await tester.pump();
      final focus = Focus.of(tester.element(vote('n-1', VoteType.against)))
        ..requestFocus();
      await tester.pump();
      expect(focus.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);

      expect(remote.votes.single.voteType, VoteType.against);
      // Held, not disabled: a disabled button can't keep focus (#607).
      expect(focus.hasPrimaryFocus, isTrue);
      expect(segment(tester, 'n-1', VoteType.forGame).onPressed, isNull);
      expect(segment(tester, 'n-1', VoteType.interested).onPressed, isNull);
      // Pressed again meanwhile, it sends nothing more.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(remote.votes, hasLength(1));

      sent.complete();
      await animate(tester);

      expect(chosen(tester, 'n-1'), {VoteType.against});
      expect(focus.hasPrimaryFocus, isTrue);
      expect(segment(tester, 'n-1', VoteType.forGame).onPressed, isNotNull);
    });

    testWidgets('a vote dropped by the re-check says so in the footer', (
      tester,
    ) async {
      await showGames(tester);
      // On screen before the read starts, so the press needs no frame.
      await tester.ensureVisible(control('n-1'));
      await tester.pump();
      final detail = blocOf<EventDetailBloc>(tester);
      heldRead = Completer<EventSnapshot>();

      // A read starts, and the press lands before a frame shows it.
      detail.add(const EventDetailRetryRequested());
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      expect((detail.state as EventDetailReady).reading, isTrue);
      await tester.tap(vote('n-1', VoteType.forGame));

      // Meanwhile a read of the nominations finds the vote closed.
      nominationsAnswer = (_) => [
        _nomination('n-1', status: NominationStatus.passed),
      ];
      blocOf<EventNominationsBloc>(
        tester,
      ).add(const EventNominationsRequested('e-1'));
      await settle(tester);
      heldRead!.complete(detailOf().snapshot);
      heldRead = null;
      await animate(tester);

      expect(remote.votes, isEmpty);
      expect(
        find.descendant(
          of: outcome(),
          matching: find.text(
            "Your vote on Catan wasn't sent: something changed on this event "
            'first.',
          ),
        ),
        findsOneWidget,
      );
    });
  });

  group('the note', () {
    testWidgets('a note is sent with the current vote', (tester) async {
      nominationsAnswer = (_) => [
        _nomination('n-1', votes: [_vote('att-me', VoteType.against)]),
      ];
      nominationAnswer = (request) => _nomination(
        request.nominationId,
        votes: [_vote('att-me', VoteType.against, comment: 'Too long')],
      );

      await showGames(tester);
      expect(inRow('n-1', 'Add a note'), findsOneWidget);

      await press(tester, note('n-1'));
      await animate(tester);
      // The app's one field, with no cap and no count: the server sets no
      // limit.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(BgeTextField),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(EventDetailScreen.nominationNoteFieldKey),
                matching: find.byType(TextField),
              ),
            )
            .maxLength,
        isNull,
      );
      expect(find.textContaining('/500'), findsNothing);

      await tester.enterText(
        find.byKey(EventDetailScreen.nominationNoteFieldKey),
        '  Too long  ',
      );
      await tester.pump();
      await tester.tap(find.byKey(EventDetailScreen.nominationNoteSaveKey));
      await animate(tester);

      // The vote as it stands, with the note, trimmed.
      expect(remote.votes, [
        (
          eventId: 'e-1',
          nominationId: 'n-1',
          voteType: VoteType.against,
          comment: 'Too long',
        ),
      ]);
      expect(inRow('n-1', 'Edit note'), findsOneWidget);
    });

    testWidgets('a long note, as another client can leave, is kept whole', (
      tester,
    ) async {
      final long = List.filled(60, 'Bring snacks.').join(' ');
      expect(long.length, greaterThan(500));
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          votes: [_vote('att-me', VoteType.forGame, comment: long)],
        ),
      ];

      await showGames(tester);
      await press(tester, note('n-1'));
      await animate(tester);

      final field = find.byKey(EventDetailScreen.nominationNoteFieldKey);
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: field, matching: find.byType(EditableText)),
            )
            .controller
            .text,
        long,
      );

      await tester.enterText(field, '$long And cups.');
      await tester.pump();
      await tester.tap(find.byKey(EventDetailScreen.nominationNoteSaveKey));
      await animate(tester);

      expect(remote.votes.single.comment, '$long And cups.');
    });

    testWidgets('a note waits for a vote', (tester) async {
      await showGames(tester);
      await tester.ensureVisible(note('n-1'));
      await tester.pump();

      expect(
        tester
            .widget<ButtonStyleButton>(
              find.ancestor(
                of: inRow('n-1', 'Add a note'),
                matching: find.byWidgetPredicate(
                  (widget) => widget is ButtonStyleButton,
                ),
              ),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('an unchanged note, or a cancelled one, sends nothing', (
      tester,
    ) async {
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          votes: [_vote('att-me', VoteType.forGame, comment: 'Yes please')],
        ),
      ];

      await showGames(tester);
      await press(tester, note('n-1'));
      await animate(tester);
      expect(find.text('Yes please'), findsWidgets);

      await tester.tap(find.byKey(EventDetailScreen.nominationNoteSaveKey));
      await animate(tester);
      await press(tester, note('n-1'));
      await animate(tester);
      await tester.tap(find.text('Cancel'));
      await animate(tester);

      expect(remote.votes, isEmpty);
      expect(outcome(), findsNothing);
    });

    testWidgets('the note dialog is named by its title, as iOS and macOS '
        'need (#762)', (tester) async {
      nominationsAnswer = (_) => [
        _nomination('n-1', votes: [_vote('att-me', VoteType.forGame)]),
      ];

      await showGames(tester);
      await press(tester, note('n-1'));
      await animate(tester);

      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect(dialog.semanticLabel, isNotNull);
      expect(dialog.semanticLabel, (dialog.title! as Text).data);
    });
  });

  group('the hint', () {
    testWidgets(
      "the hint says the viewer's vote won't count until they RSVP Attending",
      (tester) async {
        await showGames(
          tester,
          detail: detailOf(
            viewer: _row(
              'att-me',
              name: 'Me',
              status: EventParticipationStatus.maybe,
            ),
            policy: _policy(VoteEligibility.confirmedOnly),
          ),
        );

        // In the words of the RSVP control: "Are you coming?", "Going".
        const copy = "Your vote counts once you say you're going.";
        final hint = inRow('n-1', copy);
        expect(hint, findsOneWidget);
        // Above the control.
        expect(
          tester.getRect(hint).bottom,
          lessThanOrEqualTo(tester.getRect(control('n-1')).top),
        );
      },
    );

    testWidgets("the hint says the viewer's vote won't count until they "
        'offer a game', (tester) async {
      await showGames(
        tester,
        detail: detailOf(policy: _policy(VoteEligibility.poolParticipants)),
      );

      expect(
        inRow('n-1', 'Your vote counts once you offer a game.'),
        findsOneWidget,
      );
    });

    testWidgets('the offering hint waits for the pool to be read', (
      tester,
    ) async {
      final read = Completer<List<OfferedGame>>();
      poolAnswer = (_) => read.future;

      await showGames(
        tester,
        detail: detailOf(policy: _policy(VoteEligibility.poolParticipants)),
      );

      // The viewer may be offering games the pool hasn't said yet.
      expect(control('n-1'), findsOneWidget);
      expect(
        find.descendant(
          of: row('n-1'),
          matching: find.textContaining('Your vote counts'),
        ),
        findsNothing,
      );

      read.complete(const []);
      await animate(tester);

      expect(
        inRow('n-1', 'Your vote counts once you offer a game.'),
        findsOneWidget,
      );
    });

    testWidgets('no offering hint once the viewer offers a game', (
      tester,
    ) async {
      poolAnswer = (_) => [
        _game('o-1', 'att-ada', 'Catan'),
        _game('o-2', 'att-me', 'Azul'),
      ];

      await showGames(
        tester,
        detail: detailOf(policy: _policy(VoteEligibility.poolParticipants)),
      );

      expect(control('n-1'), findsOneWidget);
      expect(
        find.descendant(
          of: row('n-1'),
          matching: find.textContaining('Your vote counts'),
        ),
        findsNothing,
      );
    });

    testWidgets("a vote that doesn't count shows as chosen, under the hint, "
        'with no failure', (tester) async {
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          votes: [_vote('att-me', VoteType.against, eligible: false)],
        ),
      ];

      await showGames(
        tester,
        detail: detailOf(
          viewer: _row(
            'att-me',
            name: 'Me',
            status: EventParticipationStatus.maybe,
          ),
          policy: _policy(VoteEligibility.confirmedOnly),
        ),
      );

      // Theirs, and shown as cast, though it doesn't count yet.
      expect(chosen(tester, 'n-1'), {VoteType.against});
      const copy = "Your vote counts once you say you're going.";
      final hint = inRow('n-1', copy);
      expect(hint, findsOneWidget);
      expect(
        tester.getRect(hint).bottom,
        lessThanOrEqualTo(tester.getRect(control('n-1')).top),
      );
      // Nothing went wrong: no banner, and no failure in the row.
      expect(outcome(), findsNothing);
      for (final failure in ["wasn't sent", "Couldn't", "couldn't"]) {
        expect(
          find.descendant(
            of: row('n-1'),
            matching: find.textContaining(failure),
          ),
          findsNothing,
          reason: failure,
        );
      }
    });

    testWidgets('no hint where the vote counts', (tester) async {
      await showGames(
        tester,
        detail: detailOf(policy: _policy(VoteEligibility.confirmedOnly)),
      );

      expect(control('n-1'), findsOneWidget);
      expect(
        find.descendant(
          of: row('n-1'),
          matching: find.textContaining('Your vote counts'),
        ),
        findsNothing,
      );
    });
  });

  group('accessibility audit', () {
    testWidgets('the note dialog fits at 320dp and 200% text, nothing '
        'clipped', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          title: _longTitle,
          votes: [
            _vote(
              'att-me',
              VoteType.forGame,
              comment: List.filled(20, 'Bring snacks.').join(' '),
            ),
          ],
        ),
      ];

      await showGames(tester);
      await tester.scrollUntilVisible(
        note('n-1'),
        100,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await press(tester, note('n-1'));
      await animate(tester);

      expect(tester.takeException(), isNull);
      const window = Rect.fromLTWH(0, 0, 320, 640);
      final dialog = tester.getRect(find.byType(AlertDialog));
      expect(window.intersect(dialog), dialog);
      final field = find.byKey(EventDetailScreen.nominationNoteFieldKey);
      await tester.ensureVisible(field);
      await tester.pump();
      final fieldRect = tester.getRect(field);
      expect(dialog.intersect(fieldRect), fieldRect);
      for (final label in ['Cancel', 'Save note']) {
        final text = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(label),
        );
        expect(text, findsOneWidget, reason: label);
        final button = find.ancestor(
          of: text,
          matching: find.byType(TextButton),
        );
        final textRect = tester.getRect(text);
        final buttonRect = tester.getRect(button);
        // Whole, inside its button, inside the dialog, on screen.
        expect(buttonRect.intersect(textRect), textRect, reason: label);
        expect(dialog.intersect(buttonRect), buttonRect, reason: label);
        expect(window.intersect(buttonRect), buttonRect, reason: label);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('each choice names its game to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();

      await showGames(tester);
      await tester.ensureVisible(control('n-1'));
      await tester.pump();

      for (final (type, label) in [
        (VoteType.forGame, 'For Catan'),
        (VoteType.against, 'Against Catan'),
        (VoteType.interested, 'Interested in Catan'),
      ]) {
        expect(
          tester.getSemantics(vote('n-1', type)),
          isSemantics(
            label: label,
            isButton: true,
            isInMutuallyExclusiveGroup: true,
          ),
          reason: label,
        );
      }
      handle.dispose();
    });

    testWidgets('the vote control fits at 320dp and 200% text, its labels '
        'scaled down', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      nominationsAnswer = (_) => [
        _nomination(
          'n-1',
          title: _longTitle,
          votes: [_vote('att-me', VoteType.interested)],
        ),
      ];

      await showGames(
        tester,
        detail: detailOf(
          viewer: _row(
            'att-me',
            name: 'Me',
            status: EventParticipationStatus.maybe,
          ),
          policy: _policy(VoteEligibility.confirmedOnly),
        ),
      );
      expect(tester.takeException(), isNull);

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

      expect(tester.takeException(), isNull);
      expect(tester.getRect(control('n-1')).right, lessThanOrEqualTo(320));
      for (final type in [
        VoteType.forGame,
        VoteType.against,
        VoteType.interested,
      ]) {
        final label = find.descendant(
          of: vote('n-1', type),
          matching: find.byType(RichText),
        );
        final paragraph = tester.renderObject<RenderParagraph>(label);
        // One line, whole, and scaled to the segment rather than cut.
        expect(paragraph.didExceedMaxLines, isFalse, reason: type.name);
        expect(
          paragraph.size.height,
          paragraph.getMinIntrinsicHeight(double.infinity),
          reason: type.name,
        );
        final segmentRect = tester.getRect(
          find.ancestor(
            of: vote('n-1', type),
            matching: find.byType(TextButton),
          ),
        );
        final drawn = tester.getRect(label);
        expect(
          segmentRect.contains(drawn.topLeft) &&
              segmentRect.contains(drawn.bottomRight - const Offset(1, 1)),
          isTrue,
          reason: type.name,
        );
      }
      // The longest label, beside the chosen mark, had to shrink.
      final interested = find.descendant(
        of: vote('n-1', VoteType.interested),
        matching: find.byType(RichText),
      );
      expect(
        tester.getRect(interested).width,
        lessThan(tester.renderObject<RenderParagraph>(interested).size.width),
      );
    });
  });
}
