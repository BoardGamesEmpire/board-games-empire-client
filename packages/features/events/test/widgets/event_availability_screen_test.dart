import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';
import '../support/fake_event_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

const _hiddenCopy = "You can't see this poll's answers.";
const _loadFailedCopy = "Couldn't load the poll's answers.";
const _unknownVoterCopy = 'Someone not on the list';
const _legendCopy =
    "A crossed-out answer doesn't count while that person isn't attending.";
const _inProgressCopy = 'Refreshing…';
const _offline = EventRemoteTransientException('offline');

const AvailabilityResponse _available = AvailabilityResponse.available;
const AvailabilityResponse _maybe = AvailabilityResponse.maybe;
const AvailabilityResponse _unavailable = AvailabilityResponse.unavailable;

/// How the page names the dates [_date] makes on the 6th and the 13th.
const _nov6 = 'Fri, Nov 6 · 7:00 PM';
const _nov13 = 'Fri, Nov 13 · 7:00 PM';

/// A person on `e-1`'s roster called [name]: an account holder, unless
/// [account] is false, which makes them a guest.
EventAttendee _person(
  String id,
  String name, {
  EventRole? role = EventRole.participant,
  EventParticipationStatus status = EventParticipationStatus.attending,
  bool account = true,
}) => EventAttendee(
  id: id,
  eventId: 'e-1',
  userId: account ? 'user-$id' : null,
  displayName: account ? name : null,
  guestName: account ? null : name,
  role: role,
  status: status,
  createdAt: kItemInstant,
  updatedAt: kItemInstant,
);

/// Date [id] of `e-1`, Proposed unless [status] says otherwise, on the
/// evening of November [day].
EventOccurrence _date(
  String id, {
  int day = 6,
  OccurrenceStatus status = OccurrenceStatus.proposed,
  String? label,
  int sortOrder = 0,
}) => confirmed(
  id,
  DateTime(2026, 11, day, 19),
  sortOrder: sortOrder,
).copyWith(eventId: 'e-1', status: status, label: label);

/// Event `e-1`, a poll unless [mode] says otherwise, holding [dates], with
/// [roster] on it and its first person as the viewer.
EventDetail _poll(
  List<EventOccurrence> dates, {
  List<EventAttendee>? roster,
  EventSchedulingMode mode = EventSchedulingMode.poll,
}) => EventDetail(
  snapshot: EventSnapshot(
    event: item('e-1', title: 'Catan night', schedulingMode: mode).event,
    occurrences: dates,
    attendees: roster,
  ),
  attendance: roster?.firstOrNull,
);

AvailabilityVoter _voter(
  String attendeeId,
  AvailabilityResponse response, {
  bool eligible = true,
}) => AvailabilityVoter(
  attendeeId: attendeeId,
  response: response,
  eligible: eligible,
);

/// Date [id]'s tallies, counted from those of its [voters] that count, as
/// the server counts them.
OccurrenceAvailability _tally(String id, List<AvailabilityVoter> voters) {
  int count(AvailabilityResponse response) => voters
      .where((voter) => voter.eligible && voter.response == response)
      .length;
  return OccurrenceAvailability(
    occurrenceId: id,
    available: count(_available),
    maybe: count(_maybe),
    unavailable: count(_unavailable),
    voters: voters,
  );
}

/// The roster most tests use. Bo is a spectator and Cy a guest with no
/// account, so neither votes. Di answered Not attending, so her vote is kept
/// but doesn't count.
final List<EventAttendee> _roster = [
  _person('att-me', 'Sam'),
  _person('att-2', 'Ada'),
  _person('att-3', 'Bo', role: EventRole.spectator),
  _person('att-4', 'Cy', role: EventRole.guest, account: false),
  _person('att-5', 'Di', status: EventParticipationStatus.notAttending),
];

/// Two Proposed dates, the 6th and the 13th, with a Confirmed date and a
/// Declined one among them, in the cache's order.
final List<EventOccurrence> _dates = [
  _date('o-1'),
  _date('o-c', day: 10, sortOrder: 1, status: OccurrenceStatus.confirmed),
  _date('o-2', day: 13, sortOrder: 2),
  _date('o-d', day: 20, sortOrder: 3, status: OccurrenceStatus.declined),
];

/// The summary most tests use: `att-x` voted, and the roster doesn't hold
/// them. The Confirmed date's votes aren't a Proposed date's.
final _summary = AvailabilitySummary(
  occurrences: [
    _tally('o-1', [
      _voter('att-me', _available),
      _voter('att-2', _maybe),
      _voter('att-5', _unavailable, eligible: false),
      _voter('att-x', _available),
    ]),
    _tally('o-c', [_voter('att-me', _available)]),
    _tally('o-2', [_voter('att-2', _unavailable)]),
  ],
);

/// Who answered an event's poll (#507): the page's rows and columns, each
/// cell's answer and how it reads, the states where it shows nothing, and
/// the grid at 320dp and 2.0 text.
void main() {
  // Local, as the device's clock reads it.
  final now = DateTime(2026, 10, 23, 18);

  setUpAll(() {
    registerFallbackValue(_poll(const []).snapshot);
    registerFallbackValue(EventAccessSource.read);
  });

  late _MockEventRepository repository;
  late StreamController<EventDetail?> cache;

  setUp(() {
    repository = _MockEventRepository();
    cache = StreamController<EventDetail?>.broadcast();
    when(() => repository.watchEvent(any())).thenAnswer((_) => cache.stream);
    when(() => repository.lastWrite(any())).thenAnswer((_) async => null);
  });

  tearDown(() {
    unawaited(cache.close());
  });

  /// [textScaler], when given, overrides the scale the view gives the app;
  /// `copyWith` keeps the view's when it is null.
  Widget harness({
    EventRemoteDataSource? remote,
    Future<bool> Function()? confirmSession,
    TextScaler? textScaler,
    bool boldText = false,
    ThemeData? theme,
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    locale: const Locale('en', 'US'),
    localizationsDelegates: EventsLocalizations.localizationsDelegates,
    supportedLocales: EventsLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: textScaler, boldText: boldText),
      child: child!,
    ),
    home: EventAvailabilityScreen(
      eventId: 'e-1',
      repository: repository,
      remote: remote,
      confirmSession: confirmSession,
      now: () => now,
    ),
  );

  /// A server whose poll reads answer from [summary], [_summary] by default.
  FakeEventRemote serving({
    FutureOr<AvailabilitySummary> Function(String eventId)? summary,
  }) => FakeEventRemote.detail(
    (_) => throw UnimplementedError('the page reads no event'),
    summary: summary ?? (_) => _summary,
  );

  /// Lets the cache's answer and the poll's read reach the page.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  /// Shows [detail] as the cache's answer, with [remote] as the server, on a
  /// page of its own: one shown before it goes first.
  Future<void> show(
    WidgetTester tester,
    EventDetail? detail, {
    EventRemoteDataSource? remote,
    Future<bool> Function()? confirmSession,
    TextScaler? textScaler,
    bool boldText = false,
  }) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      harness(
        remote: remote,
        confirmSession: confirmSession,
        textScaler: textScaler,
        boldText: boldText,
      ),
    );
    cache.add(detail);
    await settle(tester);
  }

  Finder name(String attendeeId) =>
      find.byKey(EventAvailabilityScreen.nameKey(attendeeId));

  Finder header(String occurrenceId) =>
      find.byKey(EventAvailabilityScreen.dateKey(occurrenceId));

  Finder cell(String attendeeId, String occurrenceId) =>
      find.byKey(EventAvailabilityScreen.cellKey(attendeeId, occurrenceId));

  /// The text [finder]'s cell shows.
  String? textIn(WidgetTester tester, Finder finder) => tester
      .widget<Text>(find.descendant(of: finder, matching: find.byType(Text)))
      .data;

  /// The cell's text style, for its marks.
  TextStyle? styleIn(WidgetTester tester, Finder finder) => tester
      .widget<Text>(find.descendant(of: finder, matching: find.byType(Text)))
      .style;

  /// The ids of [ids], sorted by where [finder] puts each along [axis].
  List<String> inOrder(
    WidgetTester tester,
    List<String> ids,
    Finder Function(String id) finder,
    Axis axis,
  ) {
    double at(String id) {
      final corner = tester.getTopLeft(finder(id));
      return axis == Axis.vertical ? corner.dy : corner.dx;
    }

    return [...ids]..sort((a, b) => at(a).compareTo(at(b)));
  }

  testWidgets('rows are the voting attendees, columns the proposed dates', (
    tester,
  ) async {
    await show(tester, _poll(_dates, roster: _roster), remote: serving());

    expect(find.text('Who answered'), findsOneWidget);
    expect(find.byKey(EventAvailabilityScreen.gridKey), findsOneWidget);

    // The roster's voters in its order, then the summary's others: Di's vote
    // is kept, and `att-x` isn't on the roster. Neither the spectator nor
    // the guest with no account votes.
    final rows = ['att-me', 'att-2', 'att-5', 'att-x'];
    for (final id in rows) {
      expect(name(id), findsOneWidget, reason: id);
    }
    expect(name('att-3'), findsNothing);
    expect(name('att-4'), findsNothing);
    expect(inOrder(tester, rows.reversed.toList(), name, Axis.vertical), rows);
    expect(
      [for (final id in rows) textIn(tester, name(id))],
      ['Sam', 'Ada', 'Di', _unknownVoterCopy],
    );

    // The Proposed dates in the cache's order, which is their sort order.
    // Neither the Confirmed date nor the Declined one is a column.
    expect(header('o-c'), findsNothing);
    expect(header('o-d'), findsNothing);
    expect(inOrder(tester, ['o-2', 'o-1'], header, Axis.horizontal), [
      'o-1',
      'o-2',
    ]);
    expect(textIn(tester, header('o-1')), _nov6);
    expect(textIn(tester, header('o-2')), _nov13);

    // Each person's answer, or a dash for none.
    for (final (attendeeId, occurrenceId, shown) in [
      ('att-me', 'o-1', 'Available'),
      ('att-me', 'o-2', '—'),
      ('att-2', 'o-1', 'Maybe'),
      ('att-2', 'o-2', 'Unavailable'),
      ('att-5', 'o-1', 'Unavailable'),
      ('att-5', 'o-2', '—'),
      ('att-x', 'o-1', 'Available'),
      ('att-x', 'o-2', '—'),
    ]) {
      expect(
        textIn(tester, cell(attendeeId, occurrenceId)),
        shown,
        reason: '$attendeeId on $occurrenceId',
      );
      // In its person's row and its date's column.
      final at = tester.getRect(cell(attendeeId, occurrenceId));
      expect(at.top, tester.getRect(name(attendeeId)).top);
      expect(at.height, tester.getRect(name(attendeeId)).height);
      expect(at.left, tester.getRect(header(occurrenceId)).left);
    }

    // The event it is about, as the page's heading.
    expect(find.text('Catan night'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("a vote that doesn't count is marked", (tester) async {
    await show(tester, _poll(_dates, roster: _roster), remote: serving());

    expect(
      styleIn(tester, cell('att-5', 'o-1'))?.decoration,
      TextDecoration.lineThrough,
    );
    expect(
      find.bySemanticsLabel("Di, $_nov6: Unavailable, doesn't count"),
      findsOneWidget,
    );

    // A vote that counts isn't struck through, nor is no vote.
    for (final (attendeeId, occurrenceId) in [
      ('att-2', 'o-2'),
      ('att-me', 'o-1'),
      ('att-5', 'o-2'),
    ]) {
      expect(
        styleIn(tester, cell(attendeeId, occurrenceId))?.decoration,
        isNot(TextDecoration.lineThrough),
        reason: '$attendeeId on $occurrenceId',
      );
    }
    expect(find.bySemanticsLabel(RegExp('Ada.*count')), findsNothing);
  });

  testWidgets('a line above the grid says what a struck-through answer '
      'means, while one shows', (tester) async {
    final legend = find.byKey(EventAvailabilityScreen.legendKey);
    final grid = find.byKey(EventAvailabilityScreen.gridKey);

    // Di's vote on the 6th doesn't count.
    await show(tester, _poll(_dates, roster: _roster), remote: serving());
    expect(find.text(_legendCopy), findsOneWidget);
    expect(legend, findsOneWidget);
    expect(
      tester.getRect(legend).bottom,
      lessThanOrEqualTo(tester.getRect(grid).top),
    );

    // Nothing struck through: every vote counts, and the one that doesn't
    // is on a date the grid doesn't show.
    await show(
      tester,
      _poll(_dates, roster: _roster),
      remote: serving(
        summary: (_) => AvailabilitySummary(
          occurrences: [
            _tally('o-1', [_voter('att-me', _available)]),
            _tally('o-c', [_voter('att-5', _unavailable, eligible: false)]),
          ],
        ),
      ),
    );
    expect(grid, findsOneWidget);
    expect(legend, findsNothing);
    expect(find.text(_legendCopy), findsNothing);
  });

  testWidgets("a voter the roster doesn't hold is named Someone not on the "
      'list', (tester) async {
    // Their vote counts, so the grid shows it as any other.
    await show(tester, _poll(_dates, roster: _roster), remote: serving());

    expect(textIn(tester, name('att-x')), _unknownVoterCopy);
    expect(textIn(tester, cell('att-x', 'o-1')), 'Available');
    expect(
      styleIn(tester, cell('att-x', 'o-1'))?.decoration,
      isNot(TextDecoration.lineThrough),
    );
    expect(
      find.bySemanticsLabel('$_unknownVoterCopy, $_nov6: Available'),
      findsOneWidget,
    );

    // Two of them are two rows, each named so.
    await show(
      tester,
      _poll(_dates, roster: _roster),
      remote: serving(
        summary: (_) => AvailabilitySummary(
          occurrences: [
            _tally('o-1', [
              _voter('att-x', _available),
              _voter('att-y', _maybe),
            ]),
          ],
        ),
      ),
    );
    expect(textIn(tester, name('att-x')), _unknownVoterCopy);
    expect(textIn(tester, name('att-y')), _unknownVoterCopy);
    expect(textIn(tester, cell('att-y', 'o-1')), 'Maybe');
  });

  testWidgets('each cell reads as name, date and answer', (tester) async {
    final semantics = tester.ensureSemantics();
    await show(tester, _poll(_dates, roster: _roster), remote: serving());

    // One node per cell, its label all a screen reader needs: a reader
    // moving cell by cell doesn't always say the row's or column's header.
    for (final label in [
      'Sam, $_nov6: Available',
      'Sam, $_nov13: No answer',
      'Ada, $_nov6: Maybe',
      'Ada, $_nov13: Unavailable',
      "Di, $_nov6: Unavailable, doesn't count",
      'Di, $_nov13: No answer',
      '$_unknownVoterCopy, $_nov6: Available',
      '$_unknownVoterCopy, $_nov13: No answer',
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      expect(
        tester.getSemantics(find.bySemanticsLabel(label)),
        isSemantics(label: label),
        reason: label,
      );
    }
    // The dash is for the eye alone.
    expect(find.bySemanticsLabel('—'), findsNothing);

    // The headers read too: each person, and each date.
    for (final label in [
      'Sam',
      'Ada',
      'Di',
      _unknownVoterCopy,
      _nov6,
      _nov13,
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }
    semantics.dispose();
  });

  testWidgets('a forbidden summary says so', (tester) async {
    await show(
      tester,
      _poll(_dates, roster: _roster),
      remote: serving(
        summary: (_) =>
            throw const EventRemoteForbiddenException('not for you'),
      ),
    );

    expect(find.text(_hiddenCopy), findsOneWidget);
    expect(find.byKey(EventAvailabilityScreen.hiddenKey), findsOneWidget);
    expect(find.byKey(EventAvailabilityScreen.gridKey), findsNothing);
    // The same read would be refused again.
    expect(find.byKey(EventAvailabilityScreen.retryKey), findsNothing);
  });

  testWidgets("it shows nowhere the poll can't be shown", (tester) async {
    Future<void> expectHidden(String reason) async {
      expect(find.text(_hiddenCopy), findsOneWidget, reason: reason);
      expect(
        find.byKey(EventAvailabilityScreen.gridKey),
        findsNothing,
        reason: reason,
      );
      expect(
        find.byKey(EventAvailabilityScreen.retryKey),
        findsNothing,
        reason: reason,
      );
    }

    // No server to ask, though the cache holds the event.
    await show(tester, _poll(_dates, roster: _roster));
    await expectHidden('no remote');

    final remote = serving();
    // A roster withheld from this viewer (#498), as the summary says, with
    // nothing or no roster cached, or as the cache says.
    final withheld = serving(
      summary: (_) =>
          const AvailabilitySummary(occurrences: [], rosterVisible: false),
    );
    await show(tester, null, remote: withheld);
    await expectHidden('no event, and no roster to read');
    await show(tester, _poll(_dates), remote: withheld);
    await expectHidden('no roster to read');
    await show(tester, _poll(_dates, roster: const []), remote: remote);
    await expectHidden('a withheld roster');

    // No poll: no Proposed date left, or not a poll at all.
    await show(
      tester,
      _poll([
        _date('o-c', status: OccurrenceStatus.confirmed),
      ], roster: _roster),
      remote: remote,
    );
    await expectHidden('no proposed date');
    await show(
      tester,
      _poll(_dates, roster: _roster, mode: EventSchedulingMode.fixed),
      remote: remote,
    );
    await expectHidden('not a poll');

    // The server has no such event, or no longer lets this viewer read it.
    await show(
      tester,
      _poll(_dates, roster: _roster),
      remote: serving(
        summary: (_) => throw const EventRemoteNotFoundException('gone'),
      ),
    );
    await expectHidden('a 404');
  });

  testWidgets('on a direct visit it refuses nothing before the event and '
      'its roster are cached', (tester) async {
    final read = Completer<AvailabilitySummary>();
    await show(
      tester,
      null,
      remote: FakeEventRemote.detail(
        (_) => Completer<EventSnapshot>().future,
        summary: (_) => read.future,
      ),
    );
    final loading = find.byKey(EventAvailabilityScreen.loadingKey);
    final hidden = find.byKey(EventAvailabilityScreen.hiddenKey);
    expect(loading, findsOneWidget);
    expect(hidden, findsNothing);

    // The read lands first, with the detail beneath still reading the event.
    read.complete(_summary);
    await settle(tester);
    expect(loading, findsOneWidget);
    expect(hidden, findsNothing);

    // A list's copy of the event, with no roster yet.
    cache.add(_poll(_dates));
    await settle(tester);
    expect(loading, findsOneWidget);
    expect(hidden, findsNothing);

    cache.add(_poll(_dates, roster: _roster));
    await settle(tester);
    expect(find.byKey(EventAvailabilityScreen.gridKey), findsOneWidget);
  });

  group('where the cache lacks the event or its roster', () {
    final cached = _poll(_dates, roster: _roster);

    /// A cache that delivers what the read writes.
    void writesThrough() {
      when(
        () => repository.cacheEvent(any(), source: any(named: 'source')),
      ).thenAnswer((invocation) async {
        cache.add(
          EventDetail(
            snapshot: invocation.positionalArguments.single as EventSnapshot,
            attendance: cached.attendance,
          ),
        );
      });
    }

    /// Opens the page on [detail], and answers the watch of the read the page
    /// starts: a real cache answers each watcher as it arrives.
    Future<void> open(
      WidgetTester tester,
      EventDetail? detail,
      EventRemoteDataSource remote,
    ) async {
      await show(tester, detail, remote: remote);
      cache.add(detail);
      await settle(tester);
    }

    for (final (what, detail) in [
      ('nothing cached', null),
      ("a list's copy with no roster", _poll(_dates)),
    ]) {
      testWidgets('a failed read of the event, with $what, offers a retry '
          'rather than spinning', (tester) async {
        writesThrough();
        var fails = true;
        final remote = FakeEventRemote.detail(
          (_) => fails ? throw _offline : cached.snapshot,
          summary: (_) => _summary,
        );
        await open(tester, detail, remote);

        expect(find.byKey(EventAvailabilityScreen.loadingKey), findsNothing);
        expect(find.text(_loadFailedCopy), findsOneWidget);
        expect(remote.detailRequests, ['e-1']);

        fails = false;
        await tester.tap(find.byKey(EventAvailabilityScreen.retryKey));
        await settle(tester);

        expect(remote.detailRequests, ['e-1', 'e-1']);
        expect(find.byKey(EventAvailabilityScreen.gridKey), findsOneWidget);
      });
    }

    testWidgets('a retry of the poll that finds the server back reads the '
        'event too, with one press', (tester) async {
      writesThrough();
      var fails = true;
      final remote = FakeEventRemote.detail(
        (_) => cached.snapshot,
        summary: (_) => fails ? throw _offline : _summary,
      );
      await show(tester, null, remote: remote);
      expect(find.text(_loadFailedCopy), findsOneWidget);

      fails = false;
      await tester.tap(find.byKey(EventAvailabilityScreen.retryKey));
      await settle(tester);
      cache.add(null);
      await settle(tester);

      expect(remote.detailRequests, ['e-1']);
      expect(find.byKey(EventAvailabilityScreen.gridKey), findsOneWidget);
    });

    testWidgets("a read answered 404 says the viewer can't see the answers", (
      tester,
    ) async {
      await open(
        tester,
        null,
        FakeEventRemote.detail(
          (_) => throw const EventRemoteNotFoundException('gone'),
          summary: (_) => _summary,
        ),
      );

      expect(find.byKey(EventAvailabilityScreen.hiddenKey), findsOneWidget);
      expect(find.byKey(EventAvailabilityScreen.loadingKey), findsNothing);
    });

    testWidgets("a read that withholds the roster says the viewer can't see "
        'the answers', (tester) async {
      // The cache keeps no rows for an empty roster, so it reads back as none.
      when(() => repository.cacheEvent(any(), source: any(named: 'source')))
          .thenAnswer((_) async => cache.add(_poll(_dates)));
      await open(
        tester,
        _poll(_dates),
        FakeEventRemote.detail(
          (_) => _poll(_dates, roster: const []).snapshot,
          summary: (_) => _summary,
        ),
      );

      expect(find.byKey(EventAvailabilityScreen.hiddenKey), findsOneWidget);
      expect(find.byKey(EventAvailabilityScreen.loadingKey), findsNothing);
    });

    testWidgets('a cache that holds the roster is not read again', (
      tester,
    ) async {
      final remote = serving();
      await open(tester, cached, remote);

      expect(find.byKey(EventAvailabilityScreen.gridKey), findsOneWidget);
      expect(remote.detailRequests, isEmpty);
    });
  });

  testWidgets('bold text draws the grid bold', (tester) async {
    await show(
      tester,
      _poll(_dates, roster: _roster),
      remote: serving(),
      boldText: true,
    );

    expect(styleIn(tester, name('att-2'))?.fontWeight, FontWeight.bold);
  });

  testWidgets('an event that leaves the cache under the grid takes the grid '
      'with it, rather than spinning', (tester) async {
    await show(tester, _poll(_dates, roster: _roster), remote: serving());
    final grid = find.byKey(EventAvailabilityScreen.gridKey);
    expect(grid, findsOneWidget);

    // A purge, a delete, or the detail beneath told the event is gone.
    cache.add(null);
    await settle(tester);
    expect(find.byKey(EventAvailabilityScreen.hiddenKey), findsOneWidget);
    expect(find.byKey(EventAvailabilityScreen.loadingKey), findsNothing);

    // A read that brings it back brings the grid back.
    cache.add(_poll(_dates, roster: _roster));
    await settle(tester);
    expect(grid, findsOneWidget);
  });

  testWidgets('a failed read offers its retry with nothing cached', (
    tester,
  ) async {
    await show(tester, null, remote: serving(summary: (_) => throw _offline));

    expect(find.byKey(EventAvailabilityScreen.retryKey), findsOneWidget);
    expect(find.byKey(EventAvailabilityScreen.hiddenKey), findsNothing);
  });

  testWidgets('dates past the room show a scrollbar, and the keyboard moves '
      'them', (tester) async {
    const window = Size(320, 640);
    useViewSize(tester, window);
    final dates = [
      for (var n = 1; n <= 6; n++) _date('o-$n', day: n, sortOrder: n),
    ];
    await show(
      tester,
      _poll(dates, roster: _roster),
      remote: serving(summary: (_) => _summary),
    );
    final bar = tester.widget<Scrollbar>(find.byType(Scrollbar).last);
    expect(bar.thumbVisibility, isTrue);
    final start = tester.getTopLeft(header('o-1')).dx;

    // The first stop after the page's own controls.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    var tabs = 1;
    while (primaryFocus?.debugLabel != 'Who answered dates' && tabs++ < 5) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    expect(primaryFocus?.debugLabel, 'Who answered dates');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final moved = tester.getTopLeft(header('o-1')).dx;
    expect(moved, lessThan(start));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(header('o-1')).dx, start);
  });

  testWidgets('dates that fit are no stop for the keyboard', (tester) async {
    useViewSize(tester, const Size(1200, 800));
    await show(
      tester,
      _poll([_date('o-1')], roster: _roster),
      remote: serving(summary: (_) => _summary),
    );

    for (var tab = 0; tab < 5; tab++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(primaryFocus?.debugLabel, isNot('Who answered dates'));
    }
  });

  testWidgets('it waits for the cache and the read, then shows the grid', (
    tester,
  ) async {
    final read = Completer<AvailabilitySummary>();
    final remote = serving(summary: (_) => read.future);
    await tester.pumpWidget(harness(remote: remote));
    await settle(tester);

    final loading = find.byKey(EventAvailabilityScreen.loadingKey);
    expect(loading, findsOneWidget);
    expect(remote.summaryRequests, ['e-1']);

    cache.add(_poll(_dates, roster: _roster));
    await settle(tester);
    expect(loading, findsOneWidget);

    read.complete(_summary);
    await settle(tester);
    expect(loading, findsNothing);
    expect(find.byKey(EventAvailabilityScreen.gridKey), findsOneWidget);
  });

  testWidgets('a failed read offers a retry, which reads again', (
    tester,
  ) async {
    var fails = true;
    final remote = serving(summary: (_) => fails ? throw _offline : _summary);
    await show(tester, _poll(_dates, roster: _roster), remote: remote);

    expect(find.text(_loadFailedCopy), findsOneWidget);
    expect(find.byKey(EventAvailabilityScreen.gridKey), findsNothing);
    final retry = find.byKey(EventAvailabilityScreen.retryKey);
    expect(
      find.descendant(of: retry, matching: find.text('Try again')),
      findsOneWidget,
    );

    fails = false;
    await tester.tap(retry);
    await settle(tester);

    expect(remote.summaryRequests, ['e-1', 'e-1']);
    expect(find.text(_loadFailedCopy), findsNothing);
    expect(find.byKey(EventAvailabilityScreen.gridKey), findsOneWidget);

    // A cache that can't be read says so too, with nothing to press: the
    // same watch would fail again.
    cache.addError(StateError('the database went away'));
    await settle(tester);
    expect(find.text(_loadFailedCopy), findsOneWidget);
    expect(find.byKey(EventAvailabilityScreen.gridKey), findsNothing);
    expect(retry, findsNothing);
  });

  testWidgets('a read the session check stops offers a retry too', (
    tester,
  ) async {
    // On web, a session that couldn't be confirmed sends nothing (#432),
    // offline among other things. The page mustn't wait on it for ever.
    var confirmed = false;
    final remote = serving();
    await show(
      tester,
      _poll(_dates, roster: _roster),
      remote: remote,
      confirmSession: () async => confirmed,
    );

    expect(remote.summaryRequests, isEmpty);
    expect(find.byKey(EventAvailabilityScreen.loadingKey), findsNothing);
    expect(find.text(_loadFailedCopy), findsOneWidget);

    confirmed = true;
    await tester.tap(find.byKey(EventAvailabilityScreen.retryKey));
    await settle(tester);

    expect(remote.summaryRequests, ['e-1']);
    expect(find.byKey(EventAvailabilityScreen.gridKey), findsOneWidget);
  });

  testWidgets('the retry keeps focus, and its page, while its read runs', (
    tester,
  ) async {
    EventRemoteException? fails = _offline;
    final reads = <Completer<AvailabilitySummary>>[];
    final remote = serving(
      summary: (_) {
        if (fails case final error?) throw error;
        final read = Completer<AvailabilitySummary>();
        reads.add(read);
        return read.future;
      },
    );
    await show(tester, _poll(_dates, roster: _roster), remote: remote);
    final retry = find.byKey(EventAvailabilityScreen.retryKey);
    final failed = find.byKey(EventAvailabilityScreen.failedKey);
    FocusNode retryFocus() => Focus.of(
      tester.element(
        find.descendant(of: retry, matching: find.byType(Text)).first,
      ),
    );
    Future<void> press() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
    }

    retryFocus().requestFocus();
    await tester.pump();
    expect(retryFocus().hasPrimaryFocus, isTrue);

    // Held.
    fails = null;
    await press();

    expect(reads, hasLength(1));
    expect(failed, findsOneWidget);
    expect(find.byKey(EventAvailabilityScreen.loadingKey), findsNothing);
    expect(retryFocus().hasPrimaryFocus, isTrue);
    // Under way, and not to be pressed again: a screen reader says so.
    expect(
      tester.getSemantics(retry),
      isSemantics(
        label: _inProgressCopy,
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        isFocusable: true,
        isFocused: true,
        hasTapAction: false,
      ),
    );
    await press();
    expect(remote.summaryRequests, hasLength(2));

    // Failed again: the same page, the retry offered again, focus kept.
    reads.single.completeError(_offline);
    await settle(tester);

    expect(failed, findsOneWidget);
    expect(retryFocus().hasPrimaryFocus, isTrue);
    expect(
      tester.getSemantics(retry),
      isSemantics(
        label: 'Try again',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocused: true,
        hasTapAction: true,
      ),
    );

    // And read: the grid takes the page's place.
    await press();
    expect(reads, hasLength(2));
    reads[1].complete(_summary);
    await settle(tester);

    expect(find.byKey(EventAvailabilityScreen.gridKey), findsOneWidget);
    expect(failed, findsNothing);
  });

  testWidgets('an event a reconcile moved is shown by its new id', (
    tester,
  ) async {
    // Opened from a detail that followed the move (#499), by the id the
    // route still carries.
    when(() => repository.reconciledEventId('e-1')).thenReturn('e-9');
    final remote = serving();
    await show(tester, _poll(_dates, roster: _roster), remote: remote);

    verify(() => repository.watchEvent('e-9')).called(1);
    verifyNever(() => repository.watchEvent('e-1'));
    expect(remote.summaryRequests, ['e-9']);
    expect(find.byKey(EventAvailabilityScreen.gridKey), findsOneWidget);
  });

  testWidgets('the grid scrolls both ways at 320dp and 2.0 text, and the '
      'names stay', (tester) async {
    const window = Rect.fromLTWH(0, 0, 320, 640);
    useViewSize(tester, window.size);
    final people = [
      for (var n = 1; n <= 8; n++) _person('att-$n', 'Person number $n'),
    ];
    final dates = [
      _date('o-1', label: 'The first and longest evening of the tournament'),
      for (var n = 2; n <= 4; n++)
        _date('o-$n', day: 6 + (n - 1) * 7, sortOrder: n),
    ];
    await show(
      tester,
      _poll(dates, roster: people),
      remote: serving(
        summary: (_) => AvailabilitySummary(
          occurrences: [
            for (final date in dates)
              _tally(date.id, [
                _voter('att-1', _unavailable),
                _voter('att-8', _available, eligible: false),
              ]),
          ],
        ),
      ),
      textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
    );
    expect(tester.takeException(), isNull);

    // Every row lines up with its name, the tallest of them included.
    for (final person in people) {
      for (final date in dates) {
        final at = tester.getRect(cell(person.id, date.id));
        final named = tester.getRect(name(person.id));
        expect(at.top, named.top, reason: '${person.id} on ${date.id}');
        expect(at.height, named.height, reason: '${person.id} on ${date.id}');
      }
    }

    // Each name, heading and answer drawn whole in its box, wrapped as it
    // was measured: a box too short cuts its text off, and nothing
    // overflows to say so.
    for (final (reason, box) in [
      for (final person in people) (person.id, name(person.id)),
      for (final date in dates) (date.id, header(date.id)),
      for (final date in dates) ('att-1 on ${date.id}', cell('att-1', date.id)),
    ]) {
      final text = find.descendant(of: box, matching: find.byType(RichText));
      final paragraph = tester.renderObject<RenderParagraph>(text);
      expect(
        paragraph.size.height,
        greaterThanOrEqualTo(
          paragraph.getMinIntrinsicHeight(paragraph.size.width),
        ),
        reason: reason,
      );
      final drawn = tester.getRect(text);
      final inside = tester.getRect(box).inflate(0.5);
      expect(
        inside.contains(drawn.topLeft) && inside.contains(drawn.bottomRight),
        isTrue,
        reason: '$reason: $drawn in $inside',
      );
    }
    // The names wrap here, so their rows are taller than an answer needs:
    // what the lining up above is about.
    final wrapped = tester.renderObject<RenderParagraph>(
      find.descendant(of: name('att-1'), matching: find.byType(RichText)),
    );
    expect(
      wrapped.size.height,
      greaterThan(wrapped.getMinIntrinsicHeight(double.infinity)),
    );

    // The first date shows whole beside the names; the last is off to the
    // side, and the last person below.
    final first = tester.getRect(name('att-1'));
    final opening = tester.getRect(cell('att-1', 'o-1'));
    expect(opening.left, first.right);
    expect(opening.right, lessThanOrEqualTo(window.right));
    expect(tester.getRect(header('o-4')).left, greaterThan(window.right));
    // The next date's start shows beside it, by a token's width at least,
    // so there is plainly more to the side.
    final grid = find.byKey(EventAvailabilityScreen.gridKey);
    final peek = BgeTokens.of(tester.element(grid)).spaceXl;
    expect(
      tester.getRect(grid).right - tester.getRect(header('o-2')).left,
      greaterThanOrEqualTo(peek),
    );
    expect(tester.getRect(name('att-8')).top, greaterThan(window.bottom));

    // Sideways, from the part of the first date's heading on screen: the
    // long label makes the headings taller than the window here, and the
    // line above the grid starts them below it. A drag that starts off
    // screen would do nothing, and say nothing.
    await tester.ensureVisible(header('o-1'));
    await tester.pumpAndSettle();
    final named = tester.getRect(name('att-1'));
    final sideways = window.intersect(tester.getRect(header('o-1'))).center;
    expect(window.contains(sideways), isTrue);
    await tester.dragFrom(sideways, Offset(-window.width * 4, 0));
    await tester.pumpAndSettle();

    // At the end, the last date shows whole too.
    final last = tester.getRect(cell('att-1', 'o-4'));
    expect(last.right, lessThanOrEqualTo(window.right));
    expect(last.left, greaterThanOrEqualTo(first.right));
    expect(tester.getRect(header('o-4')).left, last.left);
    // The names didn't move, and the first date scrolled away from beside
    // them.
    expect(tester.getRect(name('att-1')), named);
    expect(tester.getRect(cell('att-1', 'o-1')).right, lessThan(first.right));

    // Down the page, from the middle of the window: rows and names move
    // together.
    await tester.dragFrom(window.center, Offset(0, -window.height * 4));
    await tester.pumpAndSettle();
    final lastRow = tester.getRect(name('att-8'));
    expect(window.intersect(lastRow), lastRow);
    expect(lastRow.left, first.left);
    expect(tester.getRect(cell('att-8', 'o-4')).top, lastRow.top);
    // Still scrolled sideways, and the dates that passed behind the names
    // don't cover them.
    expect(tester.getRect(cell('att-8', 'o-1')).right, lessThan(first.right));
    expect(find.text('Person number 8').hitTestable(), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        "Person number 8, Fri, Nov 27 · 7:00 PM: Available, doesn't count",
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  group('accessibility audit', () {
    Widget build(ThemeData theme, {bool remote = true}) =>
        harness(remote: remote ? serving() : null, theme: theme);

    // Eight people on four dates, one with a long label: taller and wider
    // than the narrow window at 2.0 text.
    final people = [
      for (var n = 1; n <= 8; n++) _person('att-$n', 'Person number $n'),
    ];
    final dates = [
      _date('o-1', label: 'The first and longest evening of the tournament'),
      for (var n = 2; n <= 4; n++)
        _date('o-$n', day: 6 + (n - 1) * 7, sortOrder: n),
    ];
    final bigSummary = AvailabilitySummary(
      occurrences: [
        for (final date in dates)
          _tally(date.id, [
            _voter('att-1', _unavailable),
            _voter('att-8', _available, eligible: false),
          ]),
      ],
    );

    // The harness gets no cache answer until the arrange gives one, so
    // each state is reached by what the cache and the server say.
    Future<void> feed(WidgetTester tester, EventDetail? detail) async {
      cache.add(detail);
      await settle(tester);
    }

    // Nothing has answered yet: the spinner never settles.
    auditScreen(
      'loading',
      build: build,
      arrange: (tester) async {
        await settle(tester);
        expect(find.byKey(EventAvailabilityScreen.loadingKey), findsOneWidget);
      },
      settle: false,
    );

    auditScreen(
      'ready',
      build: build,
      arrange: (tester) async {
        await feed(tester, _poll(_dates, roster: _roster));
        expect(find.byKey(EventAvailabilityScreen.gridKey), findsOneWidget);
        expect(find.byKey(EventAvailabilityScreen.legendKey), findsOneWidget);
      },
    );

    auditScreen(
      'ready, scrolled to the end',
      build: (theme) => harness(
        remote: serving(summary: (_) => bigSummary),
        theme: theme,
      ),
      arrange: (tester) async {
        await feed(tester, _poll(dates, roster: people));
        expect(find.byKey(EventAvailabilityScreen.gridKey), findsOneWidget);
        // Down the page (at the narrow window; the wider one fits)...
        await scrollPageToEnd(tester);
        // ...and along the dates, at both.
        final sideways = tester
            .stateList<ScrollableState>(find.byType(Scrollable))
            .firstWhere((state) => state.position.axis == Axis.horizontal)
            .position;
        sideways.jumpTo(sideways.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(sideways.maxScrollExtent, greaterThan(0));
        expect(sideways.pixels, sideways.maxScrollExtent);
      },
    );

    auditScreen(
      'hidden',
      build: build,
      arrange: (tester) async {
        await feed(tester, _poll(_dates, roster: _roster, mode: .fixed));
        expect(find.byKey(EventAvailabilityScreen.hiddenKey), findsOneWidget);
      },
    );

    auditScreen(
      'failure',
      build: (theme) => harness(
        remote: serving(summary: (_) => throw _offline),
        theme: theme,
      ),
      arrange: (tester) async {
        await feed(tester, _poll(_dates, roster: _roster));
        expect(find.text(_loadFailedCopy), findsOneWidget);
        expect(find.byKey(EventAvailabilityScreen.retryKey), findsOneWidget);
      },
    );
  });
}
