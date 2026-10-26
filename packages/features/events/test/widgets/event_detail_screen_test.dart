import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';
import '../support/fake_event_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

const _refreshFailedCopy = "This may be out of date: we couldn't refresh it.";
const _errorCopy = "We couldn't load this event.";
const _errorBodyCopy =
    'Nothing about it could be shown. Trying again may work.';
const _inProgressCopy = 'Refreshing…';
const _offline = EventRemoteTransientException('offline');

Household _household(String id, String name) => Household(
  id: id,
  name: name,
  createdAt: kItemInstant,
  updatedAt: kItemInstant,
);

/// Event `e-1`, a Scheduled strategy night for friends unless a test says
/// otherwise.
Event _event({
  String title = 'Catan night',
  EventType type = EventType.strategyNight,
  EventStatus status = EventStatus.scheduled,
  Reach reach = Reach.friends,
  EventSchedulingMode schedulingMode = EventSchedulingMode.fixed,
  String? householdId,
  String? location,
  String? url,
  String? description,
}) =>
    item(
      'e-1',
      title: title,
      schedulingMode: schedulingMode,
      householdId: householdId,
      location: location,
    ).event.copyWith(
      type: type,
      status: status,
      reach: reach,
      url: url,
      description: description,
    );

/// Event `e-1` as the cache holds it.
EventDetail _detail({
  Event? event,
  List<EventOccurrence> occurrences = const [],
  List<EventAttendee>? attendees,
  EventAttendee? attendance,
}) => EventDetail(
  snapshot: EventSnapshot(
    event: event ?? _event(),
    occurrences: occurrences,
    attendees: attendees,
  ),
  attendance: attendance,
);

/// An account holder on the roster.
EventAttendee _member(
  String id, {
  String? displayName,
  String? username,
  EventRole? role = EventRole.participant,
  EventParticipationStatus status = EventParticipationStatus.attending,
}) => EventAttendee(
  id: id,
  eventId: 'e-1',
  userId: 'user-$id',
  displayName: displayName,
  username: username,
  role: role,
  status: status,
  createdAt: kItemInstant,
  updatedAt: kItemInstant,
);

/// A guest on the roster, who has no account.
EventAttendee _guest(String id, String name) => EventAttendee(
  id: id,
  eventId: 'e-1',
  guestName: name,
  role: EventRole.guest,
  status: EventParticipationStatus.invited,
  createdAt: kItemInstant,
  updatedAt: kItemInstant,
);

/// The current user's own row on the roster, holding [role].
EventAttendee _attending(EventRole? role) =>
    attendance(EventParticipationStatus.attending).copyWith(role: role);

/// The event detail screen (#498): the four states of `EventDetailBloc`, the
/// header, the dates, who's coming and the games, and the refresh banner it
/// shares with the overview.
void main() {
  // Local, as the device's clock reads it.
  final now = DateTime(2026, 10, 23, 18);

  late _MockEventRepository repository;
  late StreamController<EventDetail?> cache;

  setUpAll(() {
    registerFallbackValue(_detail().snapshot);
    registerFallbackValue(EventAccessSource.read);
  });

  setUp(() {
    repository = _MockEventRepository();
    cache = StreamController<EventDetail?>.broadcast();
    when(() => repository.watchEvent(any())).thenAnswer((_) => cache.stream);
    when(() => repository.cacheEvent(any(), source: any(named: 'source')))
        .thenAnswer((_) async {});
    when(() => repository.lastWrite(any())).thenAnswer((_) async => 7);
    when(
      () => repository.forgetEvent(any(), lastWrite: any(named: 'lastWrite')),
    ).thenAnswer((_) async => true);
  });

  tearDown(() {
    unawaited(cache.close());
  });

  Widget harness({
    String eventId = 'e-1',
    EventRemoteDataSource? remote,
    Stream<List<Household>>? households,
    void Function(BuildContext context)? onBack,
    TextScaler textScaler = TextScaler.noScaling,
  }) => MaterialApp(
    theme: BgeTheme.light(),
    locale: const Locale('en', 'US'),
    localizationsDelegates: EventsLocalizations.localizationsDelegates,
    supportedLocales: EventsLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: EventDetailScreen(
      eventId: eventId,
      repository: repository,
      remote: remote,
      households: households,
      onBack: onBack,
      now: () => now,
    ),
  );

  /// Lets the cache's answer reach the bloc, and its state the screen.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  /// Shows [detail] as the cache's answer. No server, unless [remote] says.
  Future<void> show(
    WidgetTester tester,
    EventDetail detail, {
    EventRemoteDataSource? remote,
    Stream<List<Household>>? households,
  }) async {
    await tester.pumpWidget(harness(remote: remote, households: households));
    cache.add(detail);
    await settle(tester);
  }

  /// Answers each read from the completer it adds to [reads], so a test
  /// decides when, and how, each one ends.
  FakeEventRemote scripted(List<Completer<EventSnapshot>> reads) =>
      FakeEventRemote.detail((_) {
        final read = Completer<EventSnapshot>();
        reads.add(read);
        return read.future;
      });

  /// The text [finder] shows, for a `Text` with a key.
  String? textOf(WidgetTester tester, Finder finder) =>
      tester.widget<Text>(finder).data;

  Finder inSection(Key section, String text) =>
      find.descendant(of: find.byKey(section), matching: find.text(text));

  testWidgets('shows a spinner until the cache answers', (tester) async {
    await tester.pumpWidget(harness());

    expect(find.byKey(EventDetailScreen.loadingKey), findsOneWidget);
    expect(find.bySemanticsLabel('Loading this event'), findsOneWidget);
  });

  group('the header', () {
    testWidgets('shows the header', (tester) async {
      const link = 'https://example.com/catan-night';
      await show(
        tester,
        _detail(
          event: _event(
            householdId: 'h-1',
            location: 'The back room',
            url: link,
            description: 'Bring snacks.',
          ),
        ),
        households: Stream.value([_household('h-1', 'The Smiths')]),
      );

      expect(find.text('Catan night'), findsOneWidget);
      expect(find.text('Strategy night · Scheduled'), findsOneWidget);
      expect(find.text('The Smiths'), findsOneWidget);
      expect(find.text('Friends'), findsOneWidget);
      expect(find.text('The back room'), findsOneWidget);
      expect(find.text(link), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        link,
      );
      expect(find.text('Bring snacks.'), findsOneWidget);
    });

    testWidgets("the title is the page's heading", (tester) async {
      await show(tester, _detail());

      expect(
        tester.getSemantics(find.text('Catan night')),
        isSemantics(isHeader: true),
      );
    });

    testWidgets('reads type and status with a pause, not the symbol', (
      tester,
    ) async {
      await show(tester, _detail());

      expect(
        tester.getSemantics(find.text('Strategy night · Scheduled')).label,
        'Strategy night, Scheduled',
      );
    });

    testWidgets('leaves unknown values out', (tester) async {
      // Values a newer server sends. Not a guess at what they mean.
      await show(
        tester,
        _detail(
          event: _event(type: EventType.unknown, reach: Reach.unknown),
          attendance: _attending(EventRole.unknown),
        ),
      );

      expect(find.text('Scheduled'), findsOneWidget);
      expect(find.textContaining('·'), findsNothing);
      for (final reach in ['Friends', 'Friends of friends', 'Private']) {
        expect(find.text(reach), findsNothing);
      }
      expect(find.text('Public'), findsNothing);
      expect(find.byKey(EventDetailScreen.roleKey), findsNothing);

      cache.add(_detail(event: _event(status: EventStatus.unknown)));
      await settle(tester);

      expect(find.text('Strategy night'), findsOneWidget);
      expect(find.textContaining('·'), findsNothing);
    });

    testWidgets('names no household the cache does not hold', (tester) async {
      // A friend or a public reader isn't a member, so their households
      // don't name it (#498).
      await show(
        tester,
        _detail(event: _event(householdId: 'h-other')),
        households: Stream.value([_household('h-1', 'The Smiths')]),
      );

      expect(find.text('The Smiths'), findsNothing);
      expect(find.text('Catan night'), findsOneWidget);
    });

    testWidgets("shows the viewer's role", (tester) async {
      await show(tester, _detail(attendance: _attending(EventRole.host)));

      expect(
        textOf(tester, find.byKey(EventDetailScreen.roleKey)),
        "You're the host at this event",
      );

      cache.add(_detail());
      await settle(tester);
      expect(find.byKey(EventDetailScreen.roleKey), findsNothing);

      // On the roster with no role binding.
      cache.add(_detail(attendance: _attending(null)));
      await settle(tester);
      expect(find.byKey(EventDetailScreen.roleKey), findsNothing);
    });
  });

  group('the dates', () {
    testWidgets('shows each date with its status', (tester) async {
      await show(
        tester,
        _detail(
          event: _event(location: 'The hall'),
          occurrences: [
            confirmed(
              'o-1',
              DateTime(2026, 11, 6, 19, 30),
              end: DateTime(2026, 11, 6, 23),
              location: 'The back room',
            ).copyWith(label: 'Opening night'),
            confirmed(
              'o-2',
              DateTime(2026, 11, 13, 19, 30),
              sortOrder: 1,
            ).copyWith(status: OccurrenceStatus.proposed),
          ],
        ),
      );

      const dates = EventDetailScreen.datesKey;
      for (final text in [
        'Opening night',
        'Fri, Nov 6 · 7:30 PM',
        'until 11:00 PM',
        'Confirmed',
        'The back room',
        'Fri, Nov 13 · 7:30 PM',
        'Proposed',
      ]) {
        expect(inSection(dates, text), findsOneWidget, reason: text);
      }
      // The event's own place is the header's, and an occurrence's
      // overrides it for that date alone.
      expect(inSection(dates, 'The hall'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Fri, Nov 6 · 7:30 PM')).dy,
        lessThan(tester.getTopLeft(find.text('Fri, Nov 13 · 7:30 PM')).dy),
      );
    });

    testWidgets('a poll with no dates says one is being chosen', (
      tester,
    ) async {
      await show(
        tester,
        _detail(event: _event(schedulingMode: EventSchedulingMode.poll)),
      );

      expect(
        inSection(EventDetailScreen.datesKey, 'Date being chosen'),
        findsOneWidget,
      );

      cache.add(_detail());
      await settle(tester);

      expect(
        inSection(EventDetailScreen.datesKey, 'No date yet'),
        findsOneWidget,
      );
    });

    testWidgets("an end on the start's day is its time alone", (tester) async {
      await show(
        tester,
        _detail(
          occurrences: [
            confirmed(
              'o-1',
              DateTime(2026, 11, 6, 19),
              end: DateTime(2026, 11, 6, 23, 30),
            ),
          ],
        ),
      );

      expect(find.text('until 11:30 PM'), findsOneWidget);
    });

    testWidgets('an end on another day is its date and time', (tester) async {
      // A multi-day occurrence, or a night that runs past midnight: a bare
      // time would say it ends before it starts.
      await show(
        tester,
        _detail(
          occurrences: [
            confirmed(
              'o-1',
              DateTime(2026, 11, 6, 19),
              end: DateTime(2026, 11, 7, 2),
            ),
            confirmed(
              'o-2',
              DateTime(2026, 12, 31, 20),
              end: DateTime(2027, 1, 1, 1),
              sortOrder: 1,
            ),
          ],
        ),
      );

      expect(find.text('until Sat, Nov 7 · 2:00 AM'), findsOneWidget);
      expect(find.text('until Fri, Jan 1, 2027 · 1:00 AM'), findsOneWidget);
    });

    testWidgets('each date is one node for a screen reader', (tester) async {
      await show(
        tester,
        _detail(
          occurrences: [
            confirmed(
              'o-1',
              DateTime(2026, 11, 6, 19, 30),
              location: 'The back room',
            ),
          ],
        ),
      );

      final label = tester.getSemantics(find.text('Confirmed')).label;
      for (final part in ['Fri, Nov 6', '7:30 PM', 'Confirmed', 'back room']) {
        expect(label, contains(part));
      }
    });
  });

  group("who's coming", () {
    testWidgets('shows the three roster states', (tester) async {
      const attendees = EventDetailScreen.attendeesKey;

      await show(tester, _detail());
      expect(inSection(attendees, 'Not loaded yet.'), findsOneWidget);

      // Not that nobody is coming: this user may not see who is.
      cache.add(_detail(attendees: const []));
      await settle(tester);
      expect(
        inSection(attendees, "You can't see who's coming to this event."),
        findsOneWidget,
      );
      expect(find.text('Not loaded yet.'), findsNothing);

      cache.add(
        _detail(
          attendees: [
            _member(
              'att-1',
              displayName: 'Ana Ortiz',
              username: 'ana',
              role: EventRole.host,
            ),
            _member('att-2', username: 'carol', role: EventRole.coHost),
            _guest('att-3', 'Bob Guest'),
          ],
        ),
      );
      await settle(tester);

      expect(inSection(attendees, 'Ana Ortiz'), findsOneWidget);
      expect(find.text('ana'), findsNothing);
      expect(inSection(attendees, 'Host · Going'), findsOneWidget);
      expect(inSection(attendees, 'carol'), findsOneWidget);
      expect(inSection(attendees, 'Co-host · Going'), findsOneWidget);
      expect(inSection(attendees, 'Bob Guest'), findsOneWidget);
      expect(inSection(attendees, 'Guest · Invited'), findsOneWidget);
      expect(
        find.text("You can't see who's coming to this event."),
        findsNothing,
      );
    });

    testWidgets('a read that withholds the roster says so', (tester) async {
      // A friend's or a public reader's read, over an event with no cached
      // roster: the cache reads the empty roster back as null.
      await show(
        tester,
        _detail(),
        remote: FakeEventRemote.detail(
          (_) => _detail(attendees: const []).snapshot,
        ),
      );
      cache.add(_detail());
      await settle(tester);

      expect(
        inSection(
          EventDetailScreen.attendeesKey,
          "You can't see who's coming to this event.",
        ),
        findsOneWidget,
      );
      expect(find.text('Not loaded yet.'), findsNothing);
    });

    testWidgets('each attendee is one node for a screen reader', (
      tester,
    ) async {
      await show(
        tester,
        _detail(
          attendees: [
            _member('att-1', displayName: 'Ana Ortiz', role: EventRole.host),
          ],
        ),
      );

      final label = tester.getSemantics(find.text('Ana Ortiz')).label;
      expect(label, contains('Ana Ortiz'));
      expect(label, contains('Host, Going'));
    });

    testWidgets('leaves out an unknown role and answer', (tester) async {
      await show(
        tester,
        _detail(
          attendees: [
            _member(
              'att-1',
              displayName: 'Ana Ortiz',
              role: EventRole.unknown,
              status: EventParticipationStatus.maybe,
            ),
            _member(
              'att-2',
              displayName: 'Bea Lund',
              role: EventRole.spectator,
              status: EventParticipationStatus.unknown,
            ),
          ],
        ),
      );

      expect(find.text('Maybe'), findsOneWidget);
      expect(find.text('Spectator'), findsOneWidget);
    });
  });

  testWidgets('the games section says not yet', (tester) async {
    await show(tester, _detail());

    expect(
      inSection(
        EventDetailScreen.gamesKey,
        "This event's games will show here.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('section headings are headings', (tester) async {
    await show(tester, _detail());

    for (final heading in ['Dates', "Who's coming", 'Games']) {
      expect(
        tester.getSemantics(find.text(heading)),
        isSemantics(isHeader: true),
        reason: heading,
      );
    }
  });

  testWidgets('the sections follow the header in order', (tester) async {
    await show(tester, _detail());

    final tops = [
      for (final text in ['Catan night', 'Dates', "Who's coming", 'Games'])
        tester.getTopLeft(find.text(text)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(tops.toSet(), hasLength(4));
  });

  group('not found', () {
    FakeEventRemote gone() => FakeEventRemote.detail(
      (_) => throw const EventRemoteNotFoundException('gone'),
    );

    testWidgets('not found offers the way back', (tester) async {
      var backs = 0;
      await tester.pumpWidget(harness(remote: gone(), onBack: (_) => backs++));
      cache.add(_detail());
      await settle(tester);

      expect(find.byKey(EventDetailScreen.notFoundKey), findsOneWidget);
      expect(find.text("We couldn't find this event"), findsOneWidget);
      expect(
        find.text(
          'It may have been deleted, or you may no longer be able to see it.',
        ),
        findsOneWidget,
      );
      expect(find.text('Catan night'), findsNothing);

      await tester.tap(find.byKey(EventDetailScreen.notFoundBackKey));

      expect(backs, 1);
      expect(find.text('Back to events'), findsOneWidget);
    });

    testWidgets('offers no way back where the caller has none', (tester) async {
      await tester.pumpWidget(harness(remote: gone()));
      cache.add(_detail());
      await settle(tester);

      expect(find.byKey(EventDetailScreen.notFoundKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.notFoundBackKey), findsNothing);
    });
  });

  group('the error', () {
    testWidgets('the error offers a retry that reads again', (tester) async {
      final reads = <Completer<EventSnapshot>>[];
      final remote = scripted(reads);
      await tester.pumpWidget(harness(remote: remote));
      cache.add(null);
      await settle(tester);

      reads.single.completeError(_offline);
      await settle(tester);

      expect(find.byKey(EventDetailScreen.errorKey), findsOneWidget);
      expect(find.text(_errorCopy), findsOneWidget);
      expect(find.text(_errorBodyCopy), findsOneWidget);

      await tester.tap(find.byKey(EventDetailScreen.errorRetryKey));
      await settle(tester);

      expect(remote.detailRequests, ['e-1', 'e-1']);
      // The error stays up, saying the retry is running, rather than
      // giving way to a spinner.
      expect(find.byKey(EventDetailScreen.errorKey), findsOneWidget);
      expect(find.text(_inProgressCopy), findsOneWidget);
      await tester.tap(
        find.byKey(EventDetailScreen.errorRetryKey),
        warnIfMissed: false,
      );
      await settle(tester);
      expect(remote.detailRequests, hasLength(2), reason: 'disabled');

      reads.last.complete(_detail().snapshot);
      await settle(tester);
      cache.add(_detail());
      await settle(tester);

      expect(find.byKey(EventDetailScreen.errorKey), findsNothing);
      expect(find.text('Catan night'), findsOneWidget);
    });

    testWidgets('focuses the retry when it appears', (tester) async {
      // So a keyboard or switch user can act on the failure at once (#102).
      final semantics = tester.ensureSemantics();
      final reads = <Completer<EventSnapshot>>[];
      await tester.pumpWidget(harness(remote: scripted(reads)));
      cache.add(null);
      await settle(tester);
      reads.single.completeError(_offline);
      await settle(tester);

      expect(
        tester.getSemantics(find.byKey(EventDetailScreen.errorRetryKey)),
        isSemantics(label: 'Try again', isButton: true, isFocused: true),
      );
      semantics.dispose();
    });

    testWidgets('offers nothing to press without a server', (tester) async {
      await tester.pumpWidget(harness());
      cache.addError(StateError('no authenticated user'));
      await settle(tester);

      expect(find.byKey(EventDetailScreen.errorKey), findsOneWidget);
      expect(find.text(_errorCopy), findsOneWidget);
      expect(find.byKey(EventDetailScreen.errorRetryKey), findsNothing);
      expect(find.byType(ButtonStyleButton), findsNothing);
    });

    testWidgets('offers no retry once the cache has ended', (tester) async {
      // A session teardown while the first read runs. Nothing reads the
      // event again after it, so a retry would do nothing.
      await tester.pumpWidget(harness(remote: scripted([])));
      cache.add(null);
      await settle(tester);
      unawaited(cache.close());
      await settle(tester);

      expect(find.byKey(EventDetailScreen.errorKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.errorRetryKey), findsNothing);
    });
  });

  group('the refresh banner', () {
    testWidgets('a stale cache shows the banner and retries', (tester) async {
      final reads = <Completer<EventSnapshot>>[];
      final remote = scripted(reads);
      await show(tester, _detail(), remote: remote);
      expect(find.byKey(EventDetailScreen.refreshBannerKey), findsNothing);

      reads.single.completeError(_offline);
      await settle(tester);

      expect(find.byKey(EventDetailScreen.refreshBannerKey), findsOneWidget);
      expect(find.text(_refreshFailedCopy), findsOneWidget);
      // The cache stays on screen under it.
      expect(find.text('Catan night'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(EventDetailScreen.refreshBannerKey)).dy,
        lessThan(tester.getTopLeft(find.text('Catan night')).dy),
      );

      await tester.tap(find.byKey(EventDetailScreen.refreshRetryKey));
      await settle(tester);

      expect(remote.detailRequests, ['e-1', 'e-1']);
      // The banner's copy and its button's label.
      expect(find.text(_inProgressCopy), findsNWidgets(2));

      reads.last.complete(_detail().snapshot);
      await settle(tester);

      expect(find.byKey(EventDetailScreen.refreshBannerKey), findsNothing);
    });

    testWidgets('drops its retry once the cache has ended', (tester) async {
      // A session teardown under a stale event. The state is otherwise the
      // one already up, so the retry's going is what rebuilds the banner.
      final reads = <Completer<EventSnapshot>>[];
      await show(tester, _detail(), remote: scripted(reads));
      reads.single.completeError(_offline);
      await settle(tester);
      expect(find.byKey(EventDetailScreen.refreshRetryKey), findsOneWidget);

      unawaited(cache.close());
      await settle(tester);

      expect(find.byKey(EventDetailScreen.refreshBannerKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.refreshRetryKey), findsNothing);
    });

    testWidgets('is not shown for the read every open makes', (tester) async {
      // Not narrated: only a read the user asked for is.
      final reads = <Completer<EventSnapshot>>[];
      await show(tester, _detail(), remote: scripted(reads));

      expect(reads, hasLength(1));
      expect(find.byKey(EventDetailScreen.refreshBannerKey), findsNothing);
      expect(find.text(_inProgressCopy), findsNothing);
    });
  });

  testWidgets('a new id is a new event, not the old one under it', (
    tester,
  ) async {
    await show(tester, _detail());
    expect(find.text('Catan night'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: EventsLocalizations.localizationsDelegates,
        supportedLocales: EventsLocalizations.supportedLocales,
        home: EventDetailScreen(
          eventId: 'e-2',
          repository: repository,
          now: () => now,
        ),
      ),
    );
    await settle(tester);

    verify(() => repository.watchEvent('e-2')).called(1);
    expect(find.byKey(EventDetailScreen.loadingKey), findsOneWidget);
    expect(find.text('Catan night'), findsNothing);
  });

  testWidgets('lays out at 200% text on a narrow window', (tester) async {
    useViewSize(tester, const Size(320, 800));
    const title =
        'The very long annual strategy night with every expansion we own, '
        'snacks, and a tournament bracket for all of you to join';
    expect(title, hasLength(120));
    final link = 'https://example.com/${'a' * 180}';
    expect(link, hasLength(200));
    const household =
        'The Featherstonehaugh-Cholmondeley Household of '
        'Little Whinging';
    const member = 'Maximiliana Theodora Featherstonehaugh-Cholmondeley';

    // No server, so no banner: its retry overflows at this width, in
    // BgeInlineBanner itself, on every screen that shows it (#452).
    await tester.pumpWidget(
      harness(
        households: Stream.value([_household('h-1', household)]),
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      ),
    );
    cache.add(
      _detail(
        event: _event(
          title: title,
          type: EventType.competitivePlay,
          status: EventStatus.ongoing,
          reach: Reach.friendsOfFriends,
          householdId: 'h-1',
          location: 'The back room of the board game café on Privet Drive',
          url: link,
          description: 'Bring snacks, a pencil and a good mood. ' * 4,
        ),
        occurrences: [
          confirmed(
            'o-1',
            DateTime(2027, 12, 29, 19),
            end: DateTime(2027, 12, 30, 2),
            location: 'The upstairs room',
          ).copyWith(label: 'The first and longest evening'),
        ],
        attendees: [
          _member(
            'att-1',
            displayName: member,
            role: EventRole.coHost,
            status: EventParticipationStatus.notAttending,
          ),
        ],
        attendance: _attending(EventRole.organizer),
      ),
    );
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text(title), findsOneWidget);
    expect(find.text(link), findsOneWidget);
    expect(find.text(household), findsOneWidget);
    expect(find.text(member), findsOneWidget);
    expect(find.text('Competitive play · Happening now'), findsOneWidget);
    expect(find.text('Friends of friends'), findsOneWidget);
    expect(find.text('until Thu, Dec 30, 2027 · 2:00 AM'), findsOneWidget);
    expect(find.text('Co-host · Not going'), findsOneWidget);
    expect(
      textOf(tester, find.byKey(EventDetailScreen.roleKey)),
      "You're an organizer at this event",
    );
  });

  testWidgets('the error and not found lay out at 200% text on a narrow '
      'window', (tester) async {
    useViewSize(tester, const Size(320, 800));
    const scale = TextScaler.linear(BgeTextScale.maxScaleFactor);

    final reads = <Completer<EventSnapshot>>[];
    await tester.pumpWidget(
      harness(remote: scripted(reads), textScaler: scale),
    );
    cache.add(null);
    await settle(tester);
    reads.single.completeError(_offline);
    await settle(tester);
    expect(find.byKey(EventDetailScreen.errorKey), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The retry's in-progress label is the longer one. At this size the
    // page scrolls to reach it.
    await tester.ensureVisible(find.byKey(EventDetailScreen.errorRetryKey));
    await tester.pump();
    await tester.tap(find.byKey(EventDetailScreen.errorRetryKey));
    await settle(tester);
    expect(find.text(_inProgressCopy), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Another id, so a new bloc: with no server to ask, nothing cached is
    // not found.
    when(() => repository.watchEvent('e-2'))
        .thenAnswer((_) => Stream.value(null));
    await tester.pumpWidget(
      harness(eventId: 'e-2', onBack: (_) {}, textScaler: scale),
    );
    await settle(tester);
    expect(find.byKey(EventDetailScreen.notFoundKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
