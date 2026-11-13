import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_filters/game_filters.dart' show GameFiltersLocalizations;
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';
import '../support/fake_event_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

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

/// A nomination of `e-1`'s Catan, open for votes, with [votes].
EventNomination _nomination(
  String id, {
  required List<EventNominationVote> votes,
}) => EventNomination(
  id: id,
  eventId: 'e-1',
  platformGameId: 'pg-$id',
  gameId: 'g-$id',
  title: 'Catan',
  platformName: 'Tabletop',
  status: NominationStatus.open,
  nominatedById: 'att-bo',
  suppliedFromId: 'o-1',
  votes: votes,
  createdAt: kItemInstant,
);

/// Who voted on a nomination (#517): each vote, its voter and its note, the
/// votes that don't count struck through, and counts alone where the roster
/// is withheld (#462).
void main() {
  final now = DateTime(2026, 10, 23, 18);

  late _MockEventRepository repository;
  late StreamController<EventDetail?> cache;

  /// What each nominations list read answers.
  late List<EventNomination> nominations;

  final me = _row('att-me', name: 'Me');
  final ada = _row('att-ada', name: 'Ada');
  final bo = _row('att-bo', name: 'Bo');
  final unnamed = _row('att-nn');

  /// Event `e-1` as the viewer sees it, with [roster] (the viewer, Ada, Bo
  /// and someone unnamed by default) on it.
  EventDetail detailOf({List<EventAttendee>? roster}) => EventDetail(
    snapshot: EventSnapshot(
      event: item(
        'e-1',
        title: 'Catan night',
      ).event.copyWith(status: EventStatus.scheduled),
      occurrences: const [],
      attendees: roster ?? [me, ada, bo, unnamed],
    ),
    attendance: me,
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
  });

  tearDown(() {
    unawaited(cache.close());
  });

  Widget harness(EventDetail detail) => MaterialApp(
    theme: BgeTheme.light(),
    locale: const Locale('en', 'US'),
    localizationsDelegates: const [
      ...EventsLocalizations.localizationsDelegates,
      // The Games tab's Filters, its sheet and its chips (#851).
      GameFiltersLocalizations.delegate,
    ],
    supportedLocales: EventsLocalizations.supportedLocales,
    home: EventDetailScreen(
      eventId: 'e-1',
      repository: repository,
      remote: FakeEventRemote.detail(
        (_) => detail.snapshot,
        pool: (_) => const [],
        nominations: (_) => nominations,
      ),
      onBack: (_) {},
      now: () => now,
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> animate(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  /// Shows [detail] (the viewer's, by default) on the Games tab in a
  /// phone's window, where the pop-up is a sheet, and opens who voted on
  /// `n-1`.
  Future<void> openVoters(
    WidgetTester tester, {
    EventDetail? detail,
    Size size = const Size(400, 900),
  }) async {
    useViewSize(tester, size);
    final shown = detail ?? detailOf();
    await tester.pumpWidget(harness(shown));
    cache.add(shown);
    await settle(tester);
    await settle(tester);
    await tester.tap(
      find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
    );
    await animate(tester);
    final open = find.byKey(EventDetailScreen.nominationVotersKey('n-1'));
    await tester.ensureVisible(open);
    await tester.pump();
    await tester.tap(open);
    await animate(tester);
  }

  /// The pop-up's own text, apart from the row under it.
  Finder inSheet(String text) => find.descendant(
    of: find.byType(BottomSheet),
    matching: find.text(text),
  );

  TextStyle? styleOf(WidgetTester tester, Finder text) =>
      tester.widget<Text>(text).style;

  testWidgets('who voted counts every vote, and lists each with its voter '
      'and its note', (tester) async {
    nominations = [
      _nomination(
        'n-1',
        votes: [
          _vote('att-ada', VoteType.forGame, comment: 'A classic'),
          _vote('att-bo', VoteType.against),
          _vote('att-nn', VoteType.interested),
          // Off the roster, as someone removed since it was read.
          _vote('att-zz', VoteType.against, eligible: false),
        ],
      ),
    ];

    await openVoters(tester);

    // The button counted them all, the one that doesn't count included.
    expect(find.text('Who voted (4)'), findsOneWidget);
    expect(inSheet('Who voted on Catan'), findsOneWidget);
    expect(inSheet('1 for · 1 against · 1 interested'), findsOneWidget);
    for (final line in [
      'Ada: For',
      'A classic',
      'Bo: Against',
      'This person: Interested',
      'This person: Against',
    ]) {
      expect(inSheet(line), findsOneWidget, reason: line);
    }
    // The note sits under its vote.
    expect(
      tester.getRect(inSheet('A classic')).top,
      greaterThanOrEqualTo(tester.getRect(inSheet('Ada: For')).bottom),
    );
    expect(
      styleOf(tester, inSheet('Ada: For'))?.decoration,
      isNot(TextDecoration.lineThrough),
    );
  });

  testWidgets("the viewer's own vote that doesn't count is struck through", (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    nominations = [
      _nomination(
        'n-1',
        votes: [
          _vote('att-me', VoteType.forGame, eligible: false),
          _vote('att-ada', VoteType.against),
        ],
      ),
    ];

    await openVoters(tester);

    // "You", as the section names the viewer, not their name.
    expect(inSheet('You: For'), findsOneWidget);
    expect(inSheet('Me: For'), findsNothing);
    expect(
      styleOf(tester, inSheet('You: For'))?.decoration,
      TextDecoration.lineThrough,
    );
    expect(
      tester.getSemantics(inSheet('You: For')),
      isSemantics(label: "You: For. Doesn't count."),
    );
    // Said once, above the list, for someone who sees the line.
    expect(
      inSheet(
        "Struck-through votes don't count: their voter has left, or this "
        "event doesn't count them yet.",
      ),
      findsOneWidget,
    );
    expect(
      styleOf(tester, inSheet('Ada: Against'))?.decoration,
      isNot(TextDecoration.lineThrough),
    );
    // Only the counting vote is in the tally.
    expect(inSheet('0 for · 1 against · 0 interested'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('with every vote counting, nothing explains a strike', (
    tester,
  ) async {
    nominations = [
      _nomination('n-1', votes: [_vote('att-ada', VoteType.forGame)]),
    ];

    await openVoters(tester);

    expect(inSheet('Ada: For'), findsOneWidget);
    expect(find.textContaining('Struck-through'), findsNothing);
  });

  testWidgets('who voted shows counts only where the roster is withheld', (
    tester,
  ) async {
    nominations = [
      _nomination(
        'n-1',
        votes: [
          _vote('att-ada', VoteType.forGame, comment: 'A classic'),
          _vote('att-me', VoteType.against),
          _vote('att-bo', VoteType.interested, eligible: false),
        ],
      ),
    ];

    // Read and withheld: the server sends no roster to this viewer.
    await openVoters(tester, detail: detailOf(roster: const []));

    expect(find.text('Who voted (3)'), findsOneWidget);
    expect(inSheet('1 for · 1 against · 0 interested'), findsOneWidget);
    expect(inSheet("Who voted isn't shown to you."), findsOneWidget);
    for (final line in [
      'This person: For',
      'You: Against',
      'A classic',
      'This person: Interested',
    ]) {
      expect(inSheet(line), findsNothing, reason: line);
    }
    // Who voted (3) beside a tally of 2 is explained, in words that draw on
    // no struck-through line, since none is drawn.
    final note = inSheet(
      "Some votes don't count: their voter has left, or this event doesn't "
      'count them yet.',
    );
    expect(note, findsOneWidget);
    expect(
      tester.getRect(note).bottom,
      lessThanOrEqualTo(
        tester.getRect(inSheet("Who voted isn't shown to you.")).top,
      ),
    );
    expect(find.textContaining('Struck-through'), findsNothing);
  });

  testWidgets('where the roster is withheld and every vote counts, no note '
      'is shown', (tester) async {
    nominations = [
      _nomination('n-1', votes: [_vote('att-ada', VoteType.forGame)]),
    ];

    await openVoters(tester, detail: detailOf(roster: const []));

    expect(inSheet("Who voted isn't shown to you."), findsOneWidget);
    expect(find.textContaining("don't count"), findsNothing);
  });

  testWidgets('who voted is not offered on a nomination with no votes', (
    tester,
  ) async {
    nominations = [_nomination('n-1', votes: const [])];
    final shown = detailOf();

    await tester.pumpWidget(harness(shown));
    cache.add(shown);
    await settle(tester);
    await settle(tester);
    await tester.tap(
      find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
    );
    await animate(tester);

    expect(
      find.byKey(EventDetailScreen.nominationRowKey('n-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(EventDetailScreen.nominationVotersKey('n-1')),
      findsNothing,
    );
  });

  group('accessibility audit', () {
    testWidgets('who voted fits at 320dp and 200% text, nothing clipped', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue =
          BgeTextScale.maxScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      nominations = [
        _nomination(
          'n-1',
          votes: [
            _vote(
              'att-ada',
              VoteType.forGame,
              comment: 'A classic. Bring snacks.',
            ),
            _vote('att-bo', VoteType.against),
            _vote('att-me', VoteType.interested, eligible: false),
          ],
        ),
      ];

      await openVoters(tester, size: const Size(320, 640));

      expect(tester.takeException(), isNull);
      const window = Rect.fromLTWH(0, 0, 320, 640);
      final sheet = tester.getRect(find.byType(BottomSheet));
      expect(window.intersect(sheet), sheet);
      const struckNote =
          "Struck-through votes don't count: their voter has left, or this "
          "event doesn't count them yet.";
      for (final line in [
        'Who voted on Catan',
        '1 for · 1 against · 0 interested',
        struckNote,
        'Ada: For',
        'A classic. Bring snacks.',
        'Bo: Against',
        'You: Interested',
      ]) {
        final text = inSheet(line);
        expect(text, findsOneWidget, reason: line);
        await tester.ensureVisible(text);
        await tester.pump();
        final rect = tester.getRect(text);
        // Whole, inside the sheet and on screen, every line of it.
        expect(window.intersect(rect), rect, reason: line);
        expect(
          tester.getRect(find.byType(BottomSheet)).intersect(rect),
          rect,
          reason: line,
        );
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: text, matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: line);
        expect(
          paragraph.size.height,
          paragraph.getMaxIntrinsicHeight(paragraph.size.width),
          reason: line,
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('who voted is named for its game, and hands focus back to '
        'its button as it closes', (tester) async {
      final handle = tester.ensureSemantics();
      nominations = [
        _nomination('n-1', votes: [_vote('att-ada', VoteType.forGame)]),
      ];

      await openVoters(tester);

      expect(
        tester.getSemantics(
          find.byKey(EventDetailScreen.nominationVotersKey('n-1')),
        ),
        isSemantics(label: 'Who voted on Catan: 1 vote', isButton: true),
      );
      expect(
        tester.getSemantics(inSheet('Who voted on Catan')),
        isSemantics(label: 'Who voted on Catan', isHeader: true),
      );

      await tester.tapAt(const Offset(10, 10));
      await animate(tester);

      expect(find.byType(BottomSheet), findsNothing);
      final label = find.descendant(
        of: find.byKey(EventDetailScreen.nominationVotersKey('n-1')),
        matching: find.byType(Text),
      );
      expect(Focus.of(tester.element(label)).hasPrimaryFocus, isTrue);
      handle.dispose();
    });
  });
}
