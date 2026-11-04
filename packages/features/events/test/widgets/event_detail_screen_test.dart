import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/event_date_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
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

const _refreshFailedCopy = "This may be out of date: we couldn't refresh it.";
const _errorCopy = "We couldn't load this event.";
const _errorBodyCopy =
    'Nothing about it could be shown. Trying again may work.';
const _inProgressCopy = 'Refreshing…';
const _onlineOnlyCopy = "Available when you're online";
const _offline = EventRemoteTransientException('offline');
const _notFoundCopy = "We couldn't find this event";
const _deleteBodyCopy =
    "This can't be undone. Everyone on the event loses it, and they won't be "
    'told.';
const _deletedCopy = 'Event deleted';
const _goneCopy = 'This event was already deleted.';
const _refusedCopy = "You can't delete this event.";
const _failedCopy =
    'An error occurred while deleting this event. You may need to try again.';
const _failedUnexpectedCopy =
    "Something went wrong, and the event wasn't deleted.";
const _confirmBodyCopy =
    'A confirmed date can be cancelled, but not set back to proposed.';
const _cancelRemoveBodyCopy =
    "It's cancelled first, so everyone who answered is told, then removed. "
    "This can't be undone.";
const _dateChangedCopy =
    'This date changed meanwhile. Check it below before trying again.';
const _dateGoneCopy = "This date isn't on the event any more.";
const _dateRefusedCopy = "You can't change this date.";
const _dateCancelledRemoveUnconfirmedCopy =
    "The date was cancelled. If it's still below, you can remove it now.";
const _dateFailedCopy =
    'An error occurred while saving this change. You may need to try again.';
const _dateAddFailedCopy =
    'An error occurred while adding this date. Check the dates below before '
    'adding it again.';
const _dateFailedUnexpectedCopy =
    'Something went wrong. Check the date below before trying again.';
const _confirmedNotAllDeclinedCopy =
    'The date was confirmed, but some of the other dates may not have been '
    'declined. Any still proposed below can be declined from their menus.';
const _declineOthersCopy = 'Also decline the other proposed dates';
const _pollChangedCopy = "This date isn't open for answers any more.";
const _pollRefusedCopy = "You can't answer for this date.";
const _pollFailedCopy =
    'An error occurred while sending your answer. You may need to try again.';
const _pollLoadFailedCopy = "Couldn't load the poll's answers.";
const _pollHiddenCopy = "You can't see this poll's answers.";
const _pollNotCountingCopy =
    "Your answers don't count while you're not attending.";
const _cancelBodyCopy =
    'Everyone on the event is told, with your reason if you give one. You '
    'can reopen it later.';
const _reopenBodyCopy =
    'Everyone on the event is told. Dates cancelled with it stay cancelled.';
const _cancelledNoteCopy = 'This event was cancelled.';
const _statusGoneCopy = 'This event was deleted.';
const _statusRefusedCopy = "You can't change this event's status any more.";
const _statusChangedCopy =
    'This event changed before that went through. Check it below before '
    'trying again.';
const _statusFailedCopy =
    "An error occurred, and the event's status may not have changed. You may "
    'need to try again.';
const _statusFailedUnexpectedCopy =
    "Something went wrong, and the event's status didn't change.";

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

/// A confirmed date of `e-1` ahead of the test's clock, so that the event
/// reads Scheduled: the screen works the status out from the dates (#502).
EventOccurrence _ahead() =>
    confirmed('o-1', DateTime(2026, 11, 6, 19)).copyWith(eventId: 'e-1');

/// The event detail screen (#498): the four states of `EventDetailBloc`, the
/// header, the dates, who's coming and the games, and the refresh banner it
/// shares with the overview. Then Delete (#501), from the menu to the screen
/// leaving, the event's status writes (#502), the dates' menus and dialogs
/// (#506), and the poll on the dates (#507).
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
    when(() => repository.removeDeletedEvent(any()))
        .thenAnswer((_) async => true);
  });

  tearDown(() {
    unawaited(cache.close());
  });

  Widget harness({
    String eventId = 'e-1',
    EventRemoteDataSource? remote,
    Stream<List<Household>>? households,
    Future<HouseholdRole?> Function(String householdId)? householdRole,
    void Function(BuildContext context)? onBack,
    void Function(BuildContext context)? onWhoAnswered,
    Future<bool> Function()? confirmSession,
    TextScaler textScaler = TextScaler.noScaling,
    ValueListenable<bool>? offline,
  }) => MaterialApp(
    theme: BgeTheme.light(),
    locale: const Locale('en', 'US'),
    localizationsDelegates: EventsLocalizations.localizationsDelegates,
    supportedLocales: EventsLocalizations.supportedLocales,
    builder: (context, child) {
      final app = MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      );
      if (offline == null) return app;
      // As the shell hosts it, above the navigator, so menus and dialogs
      // read it too.
      return ValueListenableBuilder<bool>(
        valueListenable: offline,
        child: app,
        builder: (context, isOffline, app) => BgeConnectivityScope(
          offline: isOffline,
          noticeShowing: isOffline,
          onlineOnlyReason: _onlineOnlyCopy,
          child: app!,
        ),
      );
    },
    home: EventDetailScreen(
      eventId: eventId,
      repository: repository,
      remote: remote,
      households: households,
      householdRole: householdRole,
      onBack: onBack,
      onWhoAnswered: onWhoAnswered,
      confirmSession: confirmSession,
      now: () => now,
    ),
  );

  /// Lets the cache's answer reach the bloc, and its state the screen.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  /// Shows [detail] as the cache's answer. No server, unless [remote] says,
  /// and no way back, unless [onBack] does.
  Future<void> show(
    WidgetTester tester,
    EventDetail detail, {
    EventRemoteDataSource? remote,
    Stream<List<Household>>? households,
    Future<HouseholdRole?> Function(String householdId)? householdRole,
    void Function(BuildContext context)? onBack,
    void Function(BuildContext context)? onWhoAnswered,
    Future<bool> Function()? confirmSession,
    TextScaler textScaler = TextScaler.noScaling,
    ValueListenable<bool>? offline,
  }) async {
    await tester.pumpWidget(
      harness(
        remote: remote,
        households: households,
        householdRole: householdRole,
        onBack: onBack,
        onWhoAnswered: onWhoAnswered,
        confirmSession: confirmSession,
        textScaler: textScaler,
        offline: offline,
      ),
    );
    cache.add(detail);
    await settle(tester);
  }

  /// Answers each read from the completer it adds to [reads], so a test
  /// decides when, and how, each one ends. Deletes answer from [deleted],
  /// and succeed without one.
  FakeEventRemote scripted(
    List<Completer<EventSnapshot>> reads, {
    FutureOr<void> Function(String id)? deleted,
  }) => FakeEventRemote.detail((_) {
    final read = Completer<EventSnapshot>();
    reads.add(read);
    return read.future;
  }, deleted: deleted ?? (_) {});

  /// The text [finder] shows, for a `Text` with a key.
  String? textOf(WidgetTester tester, Finder finder) =>
      tester.widget<Text>(finder).data;

  Finder inSection(Key section, String text) =>
      find.descendant(of: find.byKey(section), matching: find.text(text));

  /// Fixed pumps, not pumpAndSettle: a retry's spinner never settles. A
  /// menu item's press lands after the frame its tap ends in, so a frame
  /// for that, then long enough for a dialog or a snackbar to finish
  /// moving.
  Future<void> animate(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Finder outcome() => find.byKey(EventDetailScreen.actionOutcomeKey);

  Finder inOutcome(String text) =>
      find.descendant(of: outcome(), matching: find.text(text));

  BgeBannerTone toneOf(WidgetTester tester) =>
      tester.widget<BgeInlineBanner>(outcome()).tone;

  /// The screen's detail bloc. The provider is inside the screen, so the
  /// lookup starts from a widget it builds.
  EventDetailBloc blocOf(WidgetTester tester) => BlocProvider.of(
    tester.element(
      find
          .descendant(
            of: find.byType(EventDetailScreen),
            matching: find.byType(Scaffold),
          )
          .first,
    ),
  );

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
          occurrences: [_ahead()],
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
      await show(tester, _detail(occurrences: [_ahead()]));

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
          occurrences: [_ahead()],
          attendance: _attending(EventRole.unknown),
        ),
      );

      expect(find.text('Scheduled'), findsOneWidget);
      // The only separator is the date's own, under the dates.
      expect(find.textContaining('·'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(EventDetailScreen.datesKey),
          matching: find.textContaining('·'),
        ),
        findsOneWidget,
      );
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
    testWidgets('says a proposed date has passed', (tester) async {
      await show(
        tester,
        _detail(
          occurrences: [
            confirmed(
              'o-1',
              now.subtract(const Duration(days: 1)),
            ).copyWith(status: OccurrenceStatus.proposed),
          ],
        ),
      );

      const dates = EventDetailScreen.datesKey;
      expect(inSection(dates, 'Date passed'), findsOneWidget);
      expect(inSection(dates, 'Proposed'), findsNothing);
    });

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

  group('delete (#501)', () {
    var backs = 0;

    setUp(() => backs = 0);

    /// The way back the screen leaves by. It records the call and doesn't
    /// pop, so the page stays up for the test to look at.
    void back(BuildContext _) => backs++;

    /// Event `e-1`, which the viewer hosts.
    EventDetail hosted({String title = 'Catan night'}) => _detail(
      event: _event(title: title),
      attendance: _attending(EventRole.host),
    );

    /// A server whose reads answer at once, and whose deletes answer from
    /// [deleted] and succeed without one.
    FakeEventRemote answering({FutureOr<void> Function(String id)? deleted}) =>
        FakeEventRemote.detail(
          (_) => _detail().snapshot,
          deleted: deleted ?? (_) {},
        );

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(EventDetailScreen.moreActionsKey));
      await animate(tester);
    }

    MenuItemButton deleteItem(WidgetTester tester) =>
        tester.widget(find.byKey(EventDetailScreen.deleteKey));

    Future<void> openDialog(WidgetTester tester) async {
      await openMenu(tester);
      await tester.tap(find.byKey(EventDetailScreen.deleteKey));
      await animate(tester);
    }

    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(find.byKey(EventDetailScreen.deleteConfirmKey));
      await animate(tester);
    }

    testWidgets('the host gets a More actions menu holding Delete', (
      tester,
    ) async {
      await show(tester, hosted(), remote: answering(), onBack: back);

      expect(find.byTooltip('More actions'), findsOneWidget);
      await openMenu(tester);

      expect(find.byKey(EventDetailScreen.deleteKey), findsOneWidget);
      expect(find.text('Delete event'), findsOneWidget);
    });

    testWidgets('a participant gets no menu', (tester) async {
      await show(
        tester,
        _detail(attendance: _attending(EventRole.participant)),
        remote: answering(),
        onBack: back,
      );

      expect(find.byKey(EventDetailScreen.moreActionsKey), findsNothing);
    });

    testWidgets("a household admin who doesn't host gets no Delete", (
      tester,
    ) async {
      // An owner or admin deletes only an event they host. They may cancel
      // it, so the menu is there for that (#502).
      await show(
        tester,
        _detail(
          event: _event(householdId: 'h-1'),
          attendance: _attending(EventRole.participant),
        ),
        remote: answering(),
        householdRole: (_) async => HouseholdRole.householdAdmin,
        onBack: back,
      );
      await settle(tester);
      await openMenu(tester);

      expect(find.byKey(EventDetailScreen.cancelKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.deleteKey), findsNothing);
    });

    testWidgets('no remote, no menu', (tester) async {
      // The delete goes straight to the server, never through the queue.
      await show(tester, hosted(), onBack: back);

      expect(find.byKey(EventDetailScreen.moreActionsKey), findsNothing);
    });

    testWidgets('no way back, no menu', (tester) async {
      // Once the event is gone, a screen that can't leave has nowhere to go.
      await show(tester, hosted(), remote: answering());

      expect(find.byKey(EventDetailScreen.moreActionsKey), findsNothing);
    });

    testWidgets('Delete waits for the read', (tester) async {
      // The read's answer, landing after the delete, would cache the event
      // again.
      final reads = <Completer<EventSnapshot>>[];
      await show(tester, hosted(), remote: scripted(reads), onBack: back);
      await openMenu(tester);

      expect(deleteItem(tester).onPressed, isNull);

      reads.single.complete(_detail().snapshot);
      await settle(tester);

      expect(deleteItem(tester).onPressed, isNotNull);
    });

    testWidgets("the dialog says it can't be undone and nobody is told", (
      tester,
    ) async {
      final remote = answering();
      await show(tester, hosted(), remote: remote, onBack: back);
      await openDialog(tester);

      expect(find.text('Delete Catan night?'), findsOneWidget);
      expect(find.text(_deleteBodyCopy), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(EventDetailScreen.deleteConfirmKey))
            .style
            ?.foregroundColor
            ?.resolve(const {}),
        BgeTheme.light().colorScheme.error,
      );

      await tester.tap(find.text('Keep event'));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.deleteRequests, isEmpty);
      expect(backs, 0);
    });

    testWidgets('confirming deletes, shows Event deleted and leaves', (
      tester,
    ) async {
      final remote = answering();
      await show(tester, hosted(), remote: remote, onBack: back);
      await openDialog(tester);
      await confirm(tester);

      expect(remote.deleteRequests, ['e-1']);
      expect(backs, 1);
      expect(find.text(_deletedCopy), findsOneWidget);
      verify(() => repository.removeDeletedEvent('e-1')).called(1);
    });

    testWidgets('a done after the user has left pops nothing more', (
      tester,
    ) async {
      // Busy shows nothing, so a user waiting on a slow DELETE may press
      // back first. The route stays mounted for its exit, and a done landing
      // then must not leave again, which would pop the route below.
      final deleting = Completer<void>();
      final remote = answering(deleted: (_) => deleting.future);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: BgeTheme.light(),
          localizationsDelegates: EventsLocalizations.localizationsDelegates,
          supportedLocales: EventsLocalizations.supportedLocales,
          home: const Scaffold(body: Text('Home')),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => EventDetailScreen(
              eventId: 'e-1',
              repository: repository,
              remote: remote,
              // The app's pops too.
              onBack: (context) {
                back(context);
                Navigator.of(context).pop();
              },
              now: () => now,
            ),
          ),
        ),
      );
      await animate(tester);
      cache.add(hosted());
      await settle(tester);
      await openDialog(tester);
      await confirm(tester);
      expect(remote.deleteRequests, ['e-1']);

      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(EventDetailScreen), findsOneWidget, reason: 'exiting');

      deleting.complete();
      await animate(tester);

      expect(tester.takeException(), isNull);
      expect(backs, 0);
      expect(find.text('Home'), findsOneWidget);
      // The event is deleted all the same, and the snackbar says so.
      expect(find.text(_deletedCopy), findsOneWidget);
    });

    testWidgets('a done under another route stays, and falls to not found', (
      tester,
    ) async {
      // The screen is still in the stack, not leaving: active, though not
      // current. The app's way back pops whichever route is on top, which
      // here is another screen's, so the screen doesn't ask for it.
      final deleting = Completer<void>();
      await show(
        tester,
        hosted(),
        remote: answering(deleted: (_) => deleting.future),
        onBack: back,
      );
      await openDialog(tester);
      await confirm(tester);

      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Above')),
              ),
            ),
      );
      await animate(tester);
      deleting.complete();
      await animate(tester);

      expect(backs, 0);
      expect(find.text('Above'), findsOneWidget);
      // The event is deleted all the same, and the snackbar says so.
      expect(find.text(_deletedCopy), findsOneWidget);

      // The removal's null, which a covered screen doesn't hold off.
      cache.add(null);
      await settle(tester);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await animate(tester);

      expect(find.text(_notFoundCopy), findsOneWidget);
      expect(find.text('Catan night'), findsNothing);
    });

    testWidgets('a done under another route falls to not found after a failed '
        'read', (tester) async {
      // The detail derives the couldn't-load page from the removal's null
      // where its last read failed, and its retry would read an event the
      // server has just deleted.
      final reads = <Completer<EventSnapshot>>[];
      final deleting = Completer<void>();
      await show(
        tester,
        hosted(),
        remote: scripted(reads, deleted: (_) => deleting.future),
        onBack: back,
      );
      reads.single.completeError(_offline);
      await settle(tester);
      await openDialog(tester);
      await confirm(tester);
      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Above')),
              ),
            ),
      );
      await animate(tester);
      deleting.complete();
      await animate(tester);

      cache.add(null);
      await settle(tester);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await animate(tester);

      expect(find.byKey(EventDetailScreen.notFoundKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.errorKey), findsNothing);
      expect(backs, 0);
    });

    testWidgets('the page holds its last frame while it leaves', (
      tester,
    ) async {
      // The route's exit keeps the page mounted, and the removal's null
      // would otherwise draw not found under it.
      await show(tester, hosted(), remote: answering(), onBack: back);
      await openDialog(tester);
      await confirm(tester);

      cache.add(null);
      await settle(tester);

      expect(find.text('Catan night'), findsOneWidget);
      expect(find.text(_notFoundCopy), findsNothing);
    });

    testWidgets('Delete stays disabled once the delete is done', (
      tester,
    ) async {
      // The page is still up after done, under the exit or an onBack that
      // didn't pop, and a second press would send a second DELETE.
      final remote = answering();
      await show(tester, hosted(), remote: remote, onBack: back);
      await openDialog(tester);
      await confirm(tester);

      await openMenu(tester);

      expect(deleteItem(tester).onPressed, isNull);
      expect(remote.deleteRequests, hasLength(1));
    });

    testWidgets('a refusal shows a banner and reads the detail again', (
      tester,
    ) async {
      // The viewer's role may have changed on another device.
      final remote = answering(
        deleted: (_) =>
            throw const EventWriteRefusedException('no', statusCode: 403),
      );
      await show(tester, hosted(), remote: remote, onBack: back);
      expect(remote.detailRequests, ['e-1']);
      await openDialog(tester);
      await confirm(tester);

      expect(inOutcome(_refusedCopy), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.warning);
      expect(remote.detailRequests, ['e-1', 'e-1']);
      expect(backs, 0);
      expect(
        tester.getTopLeft(outcome()).dy,
        lessThan(tester.getTopLeft(find.text('Catan night')).dy),
      );

      await tester.tap(inOutcome('Dismiss'));
      await settle(tester);

      expect(outcome(), findsNothing);
    });

    testWidgets('a transient failure shows the failure banner and reads '
        'nothing', (tester) async {
      final remote = answering(deleted: (_) => throw _offline);
      await show(tester, hosted(), remote: remote, onBack: back);
      await openDialog(tester);
      await confirm(tester);

      expect(inOutcome(_failedCopy), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.error);
      expect(remote.detailRequests, ['e-1']);
      expect(backs, 0);
      // Pressing Delete again is safe: a second DELETE of a deleted event
      // answers 404.
      await openMenu(tester);
      expect(deleteItem(tester).onPressed, isNotNull);
    });

    testWidgets('any other failure says something went wrong', (tester) async {
      // Not the connection: the server answered, and refused the request.
      // The same press would be refused again.
      final remote = answering(
        deleted: (_) => throw const EventRemotePermanentException(
          'bad request',
          statusCode: 400,
        ),
      );
      await show(tester, hosted(), remote: remote, onBack: back);
      await openDialog(tester);
      await confirm(tester);

      expect(inOutcome(_failedUnexpectedCopy), findsOneWidget);
      expect(find.text(_failedCopy), findsNothing);
      expect(toneOf(tester), BgeBannerTone.error);
      expect(backs, 0);
    });

    testWidgets('a gone delete falls to not found', (tester) async {
      final remote = answering(
        deleted: (_) => throw const EventRemoteNotFoundException('gone'),
      );
      await show(tester, hosted(), remote: remote, onBack: back);
      await openDialog(tester);
      await confirm(tester);

      // Until the removal's null reaches the screen.
      expect(inOutcome(_goneCopy), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.success);
      verify(() => repository.removeDeletedEvent('e-1')).called(1);
      verifyNever(
        () => repository.forgetEvent(any(), lastWrite: any(named: 'lastWrite')),
      );

      cache.add(null);
      await settle(tester);

      expect(find.text(_notFoundCopy), findsOneWidget);
      expect(backs, 0);
    });

    testWidgets('a gone delete the cache keeps still shows its updates', (
      tester,
    ) async {
      // The sync queue owns the event, so the removal is declined and the
      // cache goes on emitting it. The gone outcome alone is no not found.
      when(() => repository.removeDeletedEvent(any()))
          .thenAnswer((_) async => false);
      final remote = answering(
        deleted: (_) => throw const EventRemoteNotFoundException('gone'),
      );
      await show(tester, hosted(), remote: remote, onBack: back);
      await openDialog(tester);
      await confirm(tester);
      expect(inOutcome(_goneCopy), findsOneWidget);

      cache.add(hosted(title: 'Catan night, moved'));
      await settle(tester);

      expect(find.text(_notFoundCopy), findsNothing);
      expect(find.text('Catan night, moved'), findsOneWidget);
      expect(backs, 0);
    });

    testWidgets('a gone delete after a failed read falls to not found', (
      tester,
    ) async {
      // The detail derives the couldn't-load page from the removal's null
      // where its last read failed, and its retry would read an event the
      // server has just said is gone.
      final reads = <Completer<EventSnapshot>>[];
      final remote = scripted(
        reads,
        deleted: (_) => throw const EventRemoteNotFoundException('gone'),
      );
      await show(tester, hosted(), remote: remote, onBack: back);
      reads.single.completeError(_offline);
      await settle(tester);
      await openDialog(tester);
      await confirm(tester);
      expect(inOutcome(_goneCopy), findsOneWidget);

      cache.add(null);
      await settle(tester);

      expect(find.byKey(EventDetailScreen.notFoundKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.errorKey), findsNothing);
      expect(reads, hasLength(1));
      expect(backs, 0);
    });

    testWidgets('a read started while the dialog was open holds the delete '
        'back until it ends', (tester) async {
      final reads = <Completer<EventSnapshot>>[];
      final remote = scripted(reads);
      await show(tester, hosted(), remote: remote, onBack: back);
      // A failed read leaves a retry to offer, and Delete enabled.
      reads.single.completeError(_offline);
      await settle(tester);
      await openDialog(tester);

      blocOf(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      expect(reads, hasLength(2));

      await confirm(tester);
      expect(remote.deleteRequests, isEmpty);

      reads[1].complete(hosted().snapshot);
      await settle(tester);
      expect(remote.deleteRequests, ['e-1']);
    });

    testWidgets('a delete held back for a read that finds the event gone is '
        'not sent', (tester) async {
      final reads = <Completer<EventSnapshot>>[];
      final remote = scripted(reads);
      await show(tester, hosted(), remote: remote, onBack: back);
      reads.single.completeError(_offline);
      await settle(tester);
      await openDialog(tester);

      blocOf(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await confirm(tester);
      reads[1].completeError(const EventRemoteNotFoundException('gone'));
      await settle(tester);

      expect(remote.deleteRequests, isEmpty);
      expect(find.byKey(EventDetailScreen.notFoundKey), findsOneWidget);
    });

    testWidgets("the refresh banner's retry waits for the delete", (
      tester,
    ) async {
      // A retry pressed while the DELETE is out starts the read that Delete
      // waits for, from the other side.
      final reads = <Completer<EventSnapshot>>[];
      final deleting = Completer<void>();
      final remote = scripted(reads, deleted: (_) => deleting.future);
      await show(tester, hosted(), remote: remote, onBack: back);
      reads.single.completeError(_offline);
      await settle(tester);
      expect(find.byKey(EventDetailScreen.refreshRetryKey), findsOneWidget);

      await openDialog(tester);
      await confirm(tester);

      expect(remote.deleteRequests, ['e-1']);
      expect(find.byKey(EventDetailScreen.refreshBannerKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.refreshRetryKey), findsNothing);

      deleting.complete();
      await animate(tester);

      expect(backs, 1);
      expect(find.byKey(EventDetailScreen.refreshRetryKey), findsNothing);
      expect(reads, hasLength(1));
    });

    testWidgets('sends the id of the event it shows', (tester) async {
      // An event created here opens on its local id, and the detail follows
      // the reconcile to the server's (#499). Only the followed copy offers
      // Delete, and the server knows it by the server's id.
      final moved = StreamController<EventDetail?>.broadcast();
      addTearDown(moved.close);
      when(() => repository.watchEvent('srv-1'))
          .thenAnswer((_) => moved.stream);
      final remote = answering();
      await show(
        tester,
        _detail(
          event: _event().copyWith(isLocalOnly: true),
          attendance: _attending(EventRole.host),
        ),
        remote: remote,
        onBack: back,
      );
      expect(find.byKey(EventDetailScreen.moreActionsKey), findsNothing);

      when(() => repository.reconciledEventId('e-1')).thenReturn('srv-1');
      cache.add(null);
      await settle(tester);
      moved.add(
        _detail(
          event: _event().copyWith(id: 'srv-1'),
          attendance: _attending(EventRole.host),
        ),
      );
      await settle(tester);
      await openDialog(tester);
      await confirm(tester);

      // Not e-1, the id the screen was opened on.
      expect(remote.deleteRequests, ['srv-1']);
    });

    testWidgets('the dialog fits a long title at 2.0', (tester) async {
      useViewSize(tester, const Size(320, 640));
      const title =
          'The very long annual strategy night with every expansion we own, '
          'snacks, and a tournament bracket for all of you to join';
      expect(title, hasLength(120));
      await show(
        tester,
        hosted(title: title),
        remote: answering(),
        onBack: back,
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );
      await openDialog(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Delete $title?'), findsOneWidget);
      // The title and body scroll, and the buttons stay on screen.
      expect(
        tester.getRect(find.byKey(EventDetailScreen.deleteConfirmKey)).bottom,
        lessThanOrEqualTo(640),
      );
    });
  });

  group('status writes', () {
    var backs = 0;

    /// What the cache holds: the detail a test shows, then each status
    /// write's row over it.
    late EventDetail cached;

    setUpAll(() => registerFallbackValue(_event()));

    setUp(() {
      backs = 0;
      // The row alone, beside the cached dates and roster, and the watch
      // delivers it, as the repository does (#502).
      when(() => repository.cacheEventRow(any()))
          .thenAnswer((invocation) async {
            final row = invocation.positionalArguments.single as Event;
            cached = EventDetail(
              snapshot: EventSnapshot(
                event: row,
                occurrences: cached.snapshot.occurrences,
                attendees: cached.snapshot.attendees,
              ),
              attendance: cached.attendance,
            );
            cache.add(cached);
            return true;
          });
    });

    /// The way back, which records the call: no status write leaves.
    void back(BuildContext _) => backs++;

    /// The date of `e-1` on the evening of [day] of [month].
    EventOccurrence dated(
      int month,
      int day, {
      OccurrenceStatus status = OccurrenceStatus.confirmed,
    }) => confirmed(
      'o-1',
      DateTime(2026, month, day, 19),
      end: DateTime(2026, month, day, 23),
    ).copyWith(eventId: 'e-1', status: status);

    /// Event `e-1` reading [status], to a viewer holding [role] on it, or
    /// not attending where it is null. Scheduled and completed by its one
    /// confirmed date, ahead of the clock or ended before it. Cancelled and
    /// archived by the cached status, over the date the cancel called off
    /// or one that ended.
    EventDetail viewed(
      EventStatus status, {
      EventRole? role = EventRole.host,
      String? householdId,
      String? reason,
    }) {
      final (stored, date) = switch (status) {
        EventStatus.scheduled => (status, dated(11, 6)),
        // Cached before its date ended: the screen works it out.
        EventStatus.completed => (EventStatus.scheduled, dated(10, 20)),
        EventStatus.cancelled => (
          status,
          dated(11, 6, status: OccurrenceStatus.cancelled),
        ),
        EventStatus.archived => (status, dated(10, 20)),
        _ => throw ArgumentError.value(status),
      };
      return _detail(
        event: _event(status: stored, householdId: householdId).copyWith(
          cancelReason: reason,
          cancelledAt: status == EventStatus.cancelled
              ? DateTime.utc(2026, 10, 22)
              : null,
        ),
        occurrences: [date],
        attendance: role == null ? null : _attending(role),
      );
    }

    /// The row the server answers [request] with, from what the cache
    /// holds.
    Event answer(EventStatusRequest request) {
      final event = cached.snapshot.event;
      return switch (request.call) {
        'cancel' => event.copyWith(
          status: EventStatus.cancelled,
          cancelReason: request.reason == '' ? null : request.reason,
          cancelledAt: now.toUtc(),
        ),
        'reopen' => event.copyWith(
          status: EventStatus.scheduled,
          cancelReason: null,
          cancelledAt: null,
        ),
        'archive' => event.copyWith(status: EventStatus.archived),
        'unarchive' => event.copyWith(status: EventStatus.completed),
        final call => throw ArgumentError.value(call),
      };
    }

    /// A server whose reads serve what the cache holds, and whose status
    /// writes answer from [written], by default with the row each leads to.
    FakeEventRemote answering({
      FutureOr<Event> Function(EventStatusRequest request)? written,
    }) => FakeEventRemote.detail(
      (_) => cached.snapshot,
      deleted: (_) {},
      statusWritten: written ?? answer,
    );

    /// Shows [detail] with a way back, from [remote], or [answering]'s.
    Future<void> showStatus(
      WidgetTester tester,
      EventDetail detail, {
      EventRemoteDataSource? remote,
      Future<HouseholdRole?> Function(String householdId)? householdRole,
      TextScaler textScaler = TextScaler.noScaling,
      ValueListenable<bool>? offline,
    }) async {
      cached = detail;
      await show(
        tester,
        detail,
        remote: remote ?? answering(),
        householdRole: householdRole,
        onBack: back,
        textScaler: textScaler,
        offline: offline,
      );
      // The household role's lookup.
      await settle(tester);
    }

    Future<void> toggleMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(EventDetailScreen.moreActionsKey));
      await animate(tester);
    }

    /// The open menu's items, by label, in order.
    List<String> offered(WidgetTester tester) => [
      for (final item in tester.widgetList<MenuItemButton>(
        find.byType(MenuItemButton),
      ))
        (item.child! as BgeOnlineOnlyLabel).label,
    ];

    MenuItemButton itemOf(WidgetTester tester, Key key) =>
        tester.widget(find.byKey(key));

    /// Picks [key] from the menu, and lets its dialog open where it has
    /// one. The press lands after the tap's frame, which [animate] waits
    /// for.
    Future<void> choose(WidgetTester tester, Key key) async {
      await toggleMenu(tester);
      await tester.tap(find.byKey(key));
      await animate(tester);
    }

    testWidgets('a host sees Cancel on a scheduled event, and Reopen and '
        'Archive on a cancelled one', (tester) async {
      await showStatus(tester, viewed(EventStatus.scheduled));
      await toggleMenu(tester);

      expect(offered(tester), ['Cancel event', 'Delete event']);
      expect(itemOf(tester, EventDetailScreen.cancelKey).onPressed, isNotNull);
      await toggleMenu(tester);

      cache.add(viewed(EventStatus.cancelled));
      await settle(tester);
      await toggleMenu(tester);

      expect(offered(tester), [
        'Reopen event',
        'Archive event',
        'Delete event',
      ]);
      for (final key in [
        EventDetailScreen.reopenKey,
        EventDetailScreen.archiveKey,
      ]) {
        expect(itemOf(tester, key).onPressed, isNotNull);
      }
    });

    testWidgets('a co-host sees Archive on a completed event', (tester) async {
      await showStatus(
        tester,
        viewed(EventStatus.completed, role: EventRole.coHost),
      );

      // Cached as Scheduled, which its date has ended since.
      expect(find.text('Strategy night · Completed'), findsOneWidget);
      await toggleMenu(tester);
      // No Delete, which the host alone holds.
      expect(offered(tester), ['Cancel event', 'Archive event']);
    });

    testWidgets("a household admin who doesn't attend sees Cancel and no "
        'Archive', (tester) async {
      await showStatus(
        tester,
        viewed(EventStatus.completed, role: null, householdId: 'h-1'),
        householdRole: (_) async => HouseholdRole.householdAdmin,
      );
      await toggleMenu(tester);

      expect(offered(tester), ['Cancel event']);
    });

    testWidgets('an archived event offers Unarchive and no Reopen', (
      tester,
    ) async {
      await showStatus(tester, viewed(EventStatus.archived));

      expect(find.text('Strategy night · Archived'), findsOneWidget);
      await toggleMenu(tester);
      expect(offered(tester), ['Unarchive event', 'Delete event']);
      await toggleMenu(tester);

      // A household admin holds cancel alone, which an archived event
      // doesn't offer, so there is no menu to open on nothing.
      cache.add(viewed(EventStatus.archived, role: null, householdId: 'h-1'));
      await settle(tester);
      expect(find.byKey(EventDetailScreen.moreActionsKey), findsNothing);
    });

    testWidgets('Cancel sends the trimmed reason after the dialog, and the '
        'banner says Event cancelled', (tester) async {
      final remote = answering();
      await showStatus(tester, viewed(EventStatus.scheduled), remote: remote);
      await choose(tester, EventDetailScreen.cancelKey);

      expect(find.text('Cancel Catan night?'), findsOneWidget);
      expect(find.text(_cancelBodyCopy), findsOneWidget);
      expect(find.text('Reason (optional)'), findsOneWidget);
      await tester.enterText(
        find.byKey(EventDetailScreen.cancelReasonKey),
        '  The venue flooded.  ',
      );
      await tester.pumpAndSettle();
      expect(remote.statusRequests, isEmpty);

      await tester.tap(find.byKey(EventDetailScreen.cancelConfirmKey));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.statusRequests, [
        (call: 'cancel', id: 'e-1', reason: 'The venue flooded.'),
      ]);
      expect(inOutcome('Event cancelled'), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.success);
      // The row is cached, and the read brings the dates it called off.
      verify(() => repository.cacheEventRow(any())).called(1);
      expect(remote.detailRequests, ['e-1', 'e-1']);
      expect(find.text(_cancelledNoteCopy), findsOneWidget);
      expect(find.text('Reason: The venue flooded.'), findsOneWidget);
      expect(backs, 0);
    });

    testWidgets('Reopen asks first, and Keep cancelled sends nothing', (
      tester,
    ) async {
      final remote = answering();
      await showStatus(tester, viewed(EventStatus.cancelled), remote: remote);
      await choose(tester, EventDetailScreen.reopenKey);

      expect(find.text('Reopen Catan night?'), findsOneWidget);
      expect(find.text(_reopenBodyCopy), findsOneWidget);
      await tester.tap(find.text('Keep cancelled'));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.statusRequests, isEmpty);
      expect(outcome(), findsNothing);

      await choose(tester, EventDetailScreen.reopenKey);
      await tester.tap(find.byKey(EventDetailScreen.reopenConfirmKey));
      await animate(tester);

      expect(remote.statusRequests, [
        (call: 'reopen', id: 'e-1', reason: null),
      ]);
      expect(inOutcome('Event reopened'), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.success);
      expect(find.text(_cancelledNoteCopy), findsNothing);
    });

    testWidgets('Archive sends with no dialog, and the screen stays and '
        'reads Archived with Unarchive offered', (tester) async {
      final remote = answering();
      await showStatus(tester, viewed(EventStatus.completed), remote: remote);
      await choose(tester, EventDetailScreen.archiveKey);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.statusRequests, [
        (call: 'archive', id: 'e-1', reason: null),
      ]);
      expect(inOutcome('Event archived'), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.success);
      // No action leaves the screen (#502). The read after it serves the
      // archived event.
      expect(backs, 0);
      expect(remote.detailRequests, ['e-1', 'e-1']);
      expect(find.byKey(EventDetailScreen.notFoundKey), findsNothing);
      expect(find.text('Strategy night · Archived'), findsOneWidget);

      await toggleMenu(tester);
      expect(offered(tester), ['Unarchive event', 'Delete event']);
      await tester.tap(find.byKey(EventDetailScreen.unarchiveKey));
      await animate(tester);

      expect(remote.statusRequests.last, (
        call: 'unarchive',
        id: 'e-1',
        reason: null,
      ));
      expect(inOutcome('Event unarchived'), findsOneWidget);
      expect(find.text('Strategy night · Completed'), findsOneWidget);
      expect(backs, 0);
    });

    testWidgets('the controls wait for a running read', (tester) async {
      // The read's answer, landing after the write, would cache the event
      // as it was.
      final reads = <Completer<EventSnapshot>>[];
      await showStatus(
        tester,
        viewed(EventStatus.cancelled),
        remote: scripted(reads),
      );
      await toggleMenu(tester);

      for (final (key, label) in [
        (EventDetailScreen.reopenKey, 'Reopen event'),
        (EventDetailScreen.archiveKey, 'Archive event'),
      ]) {
        expect(itemOf(tester, key).onPressed, isNull, reason: label);
        // Disabled, not hidden, and still named.
        expect(
          tester.getSemantics(find.byKey(key)),
          matchesSemantics(label: label, hasEnabledState: true),
          reason: label,
        );
      }

      reads.single.complete(cached.snapshot);
      await settle(tester);

      for (final key in [
        EventDetailScreen.reopenKey,
        EventDetailScreen.archiveKey,
      ]) {
        expect(itemOf(tester, key).onPressed, isNotNull);
      }
    });

    testWidgets('the controls wait for a request already out', (tester) async {
      final archiving = Completer<Event>();
      final remote = answering(written: (_) => archiving.future);
      await showStatus(tester, viewed(EventStatus.cancelled), remote: remote);
      await choose(tester, EventDetailScreen.archiveKey);
      expect(remote.statusRequests, hasLength(1));

      await toggleMenu(tester);
      for (final key in [
        EventDetailScreen.reopenKey,
        EventDetailScreen.archiveKey,
        EventDetailScreen.deleteKey,
      ]) {
        expect(itemOf(tester, key).onPressed, isNull);
      }
      await toggleMenu(tester);

      archiving.complete(answer(remote.statusRequests.single));
      await animate(tester);

      expect(inOutcome('Event archived'), findsOneWidget);
      expect(remote.statusRequests, hasLength(1));
    });

    testWidgets('offline: every status control is disabled and names why', (
      tester,
    ) async {
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);

      /// A menu item's one node: both lines in its label, not enabled, no
      /// actions.
      Matcher gatedItem(String label) => matchesSemantics(
        label: '$label\n$_onlineOnlyCopy',
        hasEnabledState: true,
      );

      // Opened from a link while offline: the read fails, and the cache
      // shows the event as it was last read.
      await showStatus(
        tester,
        viewed(EventStatus.archived),
        remote: FakeEventRemote.detail((_) => throw _offline),
        offline: offline,
      );
      expect(find.text('Strategy night · Archived'), findsOneWidget);

      for (final (detail, items) in [
        (
          viewed(EventStatus.archived),
          [(EventDetailScreen.unarchiveKey, 'Unarchive event')],
        ),
        (
          viewed(EventStatus.scheduled),
          [(EventDetailScreen.cancelKey, 'Cancel event')],
        ),
        (
          viewed(EventStatus.cancelled),
          [
            (EventDetailScreen.reopenKey, 'Reopen event'),
            (EventDetailScreen.archiveKey, 'Archive event'),
          ],
        ),
      ]) {
        cache.add(detail);
        await settle(tester);
        await toggleMenu(tester);
        for (final (key, label) in items) {
          expect(itemOf(tester, key).onPressed, isNull, reason: label);
          expect(
            tester.getSemantics(find.byKey(key)),
            gatedItem(label),
            reason: label,
          );
        }
        await toggleMenu(tester);
      }

      offline.value = false;
      await tester.pump();
      await toggleMenu(tester);

      expect(find.text(_onlineOnlyCopy), findsNothing);
      for (final key in [
        EventDetailScreen.reopenKey,
        EventDetailScreen.archiveKey,
      ]) {
        expect(itemOf(tester, key).onPressed, isNotNull);
      }
    });

    testWidgets('the delete dialog offers Cancel event instead to a host of a '
        "live event, and it opens Cancel's dialog", (tester) async {
      final remote = answering();
      await showStatus(tester, viewed(EventStatus.scheduled), remote: remote);
      await choose(tester, EventDetailScreen.deleteKey);

      expect(find.text('Delete Catan night?'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(EventDetailScreen.cancelInsteadKey),
                matching: find.byType(Text),
              ),
            )
            .data,
        'Cancel event instead',
      );

      await tester.tap(find.byKey(EventDetailScreen.cancelInsteadKey));
      await animate(tester);

      expect(find.text('Delete Catan night?'), findsNothing);
      expect(find.text('Cancel Catan night?'), findsOneWidget);
      await tester.tap(find.byKey(EventDetailScreen.cancelConfirmKey));
      await animate(tester);

      expect(remote.deleteRequests, isEmpty);
      expect(remote.statusRequests, [(call: 'cancel', id: 'e-1', reason: '')]);
      expect(inOutcome('Event cancelled'), findsOneWidget);
      expect(backs, 0);
    });

    testWidgets('not on a cancelled event', (tester) async {
      await showStatus(tester, viewed(EventStatus.cancelled));
      await choose(tester, EventDetailScreen.deleteKey);

      expect(find.text('Delete Catan night?'), findsOneWidget);
      expect(find.byKey(EventDetailScreen.cancelInsteadKey), findsNothing);
      await tester.tap(find.text('Keep event'));
      await animate(tester);

      // Nor on an archived one.
      cache.add(viewed(EventStatus.archived));
      await settle(tester);
      await choose(tester, EventDetailScreen.deleteKey);

      expect(find.text('Delete Catan night?'), findsOneWidget);
      expect(find.byKey(EventDetailScreen.cancelInsteadKey), findsNothing);
    });

    testWidgets("the delete dialog's three buttons fit at 320dp and 2.0 "
        'text', (tester) async {
      useViewSize(tester, const Size(320, 640));
      await showStatus(
        tester,
        viewed(EventStatus.scheduled),
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );
      await choose(tester, EventDetailScreen.deleteKey);

      expect(tester.takeException(), isNull);
      final dialog = tester.getRect(find.byType(AlertDialog));
      for (final label in ['Keep event', 'Cancel event instead', 'Delete']) {
        final text = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(label),
        );
        expect(text, findsOneWidget, reason: label);
        final button = find.ancestor(
          of: text,
          matching: find.byType(TextButton),
        );
        // Whole, inside its button, inside the dialog, on screen.
        final textRect = tester.getRect(text);
        final buttonRect = tester.getRect(button);
        expect(
          buttonRect.intersect(textRect),
          textRect,
          reason: '$label within its button',
        );
        expect(
          dialog.intersect(buttonRect),
          buttonRect,
          reason: '$label within the dialog',
        );
        expect(buttonRect.bottom, lessThanOrEqualTo(640), reason: label);
      }
    });

    testWidgets('the note, a long reason and the status dialogs fit at 320dp '
        'and 2.0 text', (tester) async {
      useViewSize(tester, const Size(320, 640));
      final reason = 'The venue flooded, and the trains are off. ' * 6;
      await showStatus(
        tester,
        viewed(EventStatus.cancelled, reason: reason),
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );

      expect(tester.takeException(), isNull);
      expect(find.text(_cancelledNoteCopy), findsOneWidget);
      expect(find.text('Reason: $reason'), findsOneWidget);

      // Each dialog's title and body scroll, and its buttons stay on screen.
      await choose(tester, EventDetailScreen.reopenKey);
      expect(tester.takeException(), isNull);
      expect(find.text('Reopen Catan night?'), findsOneWidget);
      expect(
        tester.getRect(find.byKey(EventDetailScreen.reopenConfirmKey)).bottom,
        lessThanOrEqualTo(640),
      );
      await tester.tap(find.text('Keep cancelled'));
      await animate(tester);

      cache.add(viewed(EventStatus.scheduled));
      await settle(tester);
      await choose(tester, EventDetailScreen.cancelKey);
      expect(tester.takeException(), isNull);
      expect(find.text('Cancel Catan night?'), findsOneWidget);
      expect(
        tester.getRect(find.byKey(EventDetailScreen.cancelConfirmKey)).bottom,
        lessThanOrEqualTo(640),
      );
    });

    testWidgets('a cancelled event shows the note and its reason', (
      tester,
    ) async {
      await showStatus(
        tester,
        viewed(EventStatus.cancelled, reason: 'The venue flooded.'),
      );

      expect(find.text('Strategy night · Cancelled'), findsOneWidget);
      expect(find.text(_cancelledNoteCopy), findsOneWidget);
      const reason = 'Reason: The venue flooded.';
      expect(find.text(reason), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(reason)).dy,
        greaterThan(tester.getTopLeft(find.text(_cancelledNoteCopy)).dy),
      );
      // Read as one, the note and why.
      expect(
        tester.getSemantics(find.text(_cancelledNoteCopy)).label,
        '$_cancelledNoteCopy\n$reason',
      );

      cache.add(viewed(EventStatus.scheduled));
      await settle(tester);

      expect(find.text(_cancelledNoteCopy), findsNothing);
      expect(find.textContaining('Reason:'), findsNothing);
    });

    testWidgets('no reason line for a blank reason', (tester) async {
      await showStatus(tester, viewed(EventStatus.cancelled));

      expect(find.text(_cancelledNoteCopy), findsOneWidget);
      expect(find.textContaining('Reason:'), findsNothing);

      cache.add(viewed(EventStatus.cancelled, reason: '   '));
      await settle(tester);

      expect(find.text(_cancelledNoteCopy), findsOneWidget);
      expect(find.textContaining('Reason:'), findsNothing);
    });

    testWidgets('an archived event that was cancelled keeps its note and '
        'reason', (tester) async {
      // The server's archive keeps the cancel's time and reason.
      final archived = viewed(
        EventStatus.archived,
        reason: 'The venue flooded.',
      );
      EventDetail cancelledThenArchived(List<EventOccurrence> occurrences) =>
          _detail(
            event: archived.snapshot.event.copyWith(
              cancelledAt: DateTime.utc(2026, 10, 22),
            ),
            occurrences: occurrences,
            attendance: archived.attendance,
          );
      const reason = 'Reason: The venue flooded.';

      await showStatus(
        tester,
        cancelledThenArchived([
          dated(11, 6, status: OccurrenceStatus.cancelled),
        ]),
      );

      expect(find.text('Strategy night · Archived'), findsOneWidget);
      expect(find.text(_cancelledNoteCopy), findsOneWidget);
      expect(find.text(reason), findsOneWidget);

      // With no dates, the header is the only place the reason shows.
      cache.add(cancelledThenArchived(const []));
      await settle(tester);

      expect(find.text(_cancelledNoteCopy), findsOneWidget);
      expect(find.text(reason), findsOneWidget);

      // Archived without a cancel: nothing to say of one.
      cache.add(viewed(EventStatus.archived));
      await settle(tester);

      expect(find.text('Strategy night · Archived'), findsOneWidget);
      expect(find.text(_cancelledNoteCopy), findsNothing);
      expect(find.textContaining('Reason:'), findsNothing);
    });

    testWidgets('a 400 shows the changed copy and reads again', (tester) async {
      // Archived on another device, say: the cached status was stale.
      final remote = answering(
        written: (_) => throw const EventWriteConflictException(
          'already archived',
          statusCode: 400,
        ),
      );
      await showStatus(tester, viewed(EventStatus.completed), remote: remote);
      expect(remote.detailRequests, ['e-1']);
      await choose(tester, EventDetailScreen.archiveKey);

      expect(inOutcome(_statusChangedCopy), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.warning);
      expect(remote.detailRequests, ['e-1', 'e-1']);
      verifyNever(() => repository.cacheEventRow(any()));
    });

    testWidgets('a cancel retried after its answer was lost says Event '
        'cancelled and shows the first reason', (tester) async {
      var lost = true;
      final remote = answering(
        written: (request) {
          if (lost) {
            lost = false;
            throw _offline;
          }
          // Cancelled by the first, whose reason the server kept.
          return cached.snapshot.event.copyWith(
            status: EventStatus.cancelled,
            cancelReason: 'The venue flooded.',
            cancelledAt: now.toUtc(),
          );
        },
      );
      await showStatus(tester, viewed(EventStatus.scheduled), remote: remote);

      Future<void> cancelWith(String reason) async {
        await choose(tester, EventDetailScreen.cancelKey);
        await tester.enterText(
          find.byKey(EventDetailScreen.cancelReasonKey),
          reason,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(EventDetailScreen.cancelConfirmKey));
        await animate(tester);
      }

      await cancelWith('The venue flooded.');
      expect(inOutcome(_statusFailedCopy), findsOneWidget);

      // Still offered, since the answer said nothing of what happened.
      await cancelWith('Rain.');

      expect(remote.statusRequests.map((request) => request.reason), [
        'The venue flooded.',
        'Rain.',
      ]);
      expect(inOutcome('Event cancelled'), findsOneWidget);
      expect(find.text('Reason: The venue flooded.'), findsOneWidget);
      expect(find.text('Reason: Rain.'), findsNothing);
    });

    testWidgets('a cancel whose event was cancelled while its dialog was open '
        'sends nothing, and says the event changed', (tester) async {
      final remote = answering();
      await showStatus(tester, viewed(EventStatus.scheduled), remote: remote);
      await choose(tester, EventDetailScreen.cancelKey);
      await tester.enterText(
        find.byKey(EventDetailScreen.cancelReasonKey),
        'Rain.',
      );
      await tester.pump();

      // From another device, through a sync.
      cache.add(viewed(EventStatus.cancelled));
      await settle(tester);
      await tester.tap(find.byKey(EventDetailScreen.cancelConfirmKey));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.statusRequests, isEmpty);
      // The banner is a live region, so a screen reader hears why nothing
      // happened. The page already shows the event as cached, so nothing
      // is read again.
      expect(inOutcome(_statusChangedCopy), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.warning);
      expect(remote.detailRequests, ['e-1']);
    });

    testWidgets('a reopen whose role a sync took while its dialog was open '
        'sends nothing, and says the event changed', (tester) async {
      final remote = answering();
      await showStatus(tester, viewed(EventStatus.cancelled), remote: remote);
      await choose(tester, EventDetailScreen.reopenKey);

      cache.add(viewed(EventStatus.cancelled, role: EventRole.participant));
      await settle(tester);
      await tester.tap(find.byKey(EventDetailScreen.reopenConfirmKey));
      await animate(tester);

      expect(remote.statusRequests, isEmpty);
      expect(inOutcome(_statusChangedCopy), findsOneWidget);
    });

    group('each end has its copy and tone', () {
      final ends = [
        (
          name: 'a gone event',
          thrown: const EventRemoteNotFoundException('gone') as Object,
          copy: _statusGoneCopy,
          tone: BgeBannerTone.warning,
          rereads: true,
        ),
        (
          name: 'a refusal',
          thrown: const EventWriteRefusedException('no', statusCode: 403),
          copy: _statusRefusedCopy,
          tone: BgeBannerTone.warning,
          rereads: true,
        ),
        (
          name: 'a transient failure',
          thrown: _offline,
          copy: _statusFailedCopy,
          tone: BgeBannerTone.error,
          rereads: false,
        ),
        (
          name: 'any other failure',
          thrown: const EventRemotePermanentException(
            'broken',
            statusCode: 500,
          ),
          copy: _statusFailedUnexpectedCopy,
          tone: BgeBannerTone.error,
          rereads: true,
        ),
      ];

      for (final end in ends) {
        testWidgets('${end.name}: ${end.copy}', (tester) async {
          final remote = answering(written: (_) => throw end.thrown);
          await showStatus(
            tester,
            viewed(EventStatus.completed),
            remote: remote,
          );
          await choose(tester, EventDetailScreen.archiveKey);

          expect(inOutcome(end.copy), findsOneWidget);
          expect(toneOf(tester), end.tone);
          expect(remote.detailRequests, hasLength(end.rereads ? 2 : 1));
          expect(backs, 0);
        });
      }
    });
  });

  group('dates (#506)', () {
    setUpAll(() {
      registerFallbackValue(confirmed('o-fallback', kItemInstant));
    });

    setUp(() {
      when(() => repository.cacheOccurrence(any()))
          .thenAnswer((_) async => true);
      when(
        () => repository.removeCachedOccurrence(
          eventId: any(named: 'eventId'),
          occurrenceId: any(named: 'occurrenceId'),
        ),
      ).thenAnswer((_) async => true);
    });

    /// Event `e-1`, a poll the viewer hosts unless a test says otherwise,
    /// holding [occurrences].
    EventDetail hosted(
      List<EventOccurrence> occurrences, {
      EventSchedulingMode schedulingMode = EventSchedulingMode.poll,
      EventRole role = EventRole.host,
    }) => _detail(
      event: _event(schedulingMode: schedulingMode),
      occurrences: occurrences,
      attendance: _attending(role),
    );

    /// Date [id] of `e-1`, Proposed unless [status] says otherwise, on the
    /// evening of November [day].
    EventOccurrence date(
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

    /// A server whose reads answer at once, and whose date writes answer
    /// from [written]: by default with the date they named, or a new one.
    FakeEventRemote answering({
      FutureOr<EventOccurrence?> Function(EventDateRequest request)? written,
    }) => FakeEventRemote.detail(
      (_) => _detail().snapshot,
      dateWritten: written ?? (request) => date(request.occurrenceId ?? 'o-9'),
    );

    void back(BuildContext _) {}

    Finder menuOf(String id) => find.byKey(EventDetailScreen.dateMenuKey(id));

    Finder itemOf(String id, EventAction action) =>
        find.byKey(EventDetailScreen.dateActionKey(id, action));

    VoidCallback? addOf(WidgetTester tester) => tester
        .widget<ButtonStyleButton>(find.byKey(EventDetailScreen.addDateKey))
        .onPressed;

    Future<void> toggleMenu(WidgetTester tester, String id) async {
      await tester.tap(menuOf(id));
      await animate(tester);
    }

    /// Picks [action] from date [id]'s menu, and lets its dialog open.
    Future<void> choose(
      WidgetTester tester,
      String id,
      EventAction action,
    ) async {
      await toggleMenu(tester, id);
      await tester.tap(itemOf(id, action));
      await animate(tester);
    }

    Future<void> submit(WidgetTester tester) async {
      await tester.tap(find.byKey(EventDateDialogKeys.submit));
      await animate(tester);
    }

    /// Asks for [action] through its dialog: on date [id], or a date added to
    /// start when the pickers open, today at the clock's time.
    Future<void> perform(
      WidgetTester tester,
      EventAction action, {
      String id = 'o-1',
    }) async {
      if (action == EventAction.addDate) {
        await tester.tap(find.byKey(EventDetailScreen.addDateKey));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(EventDateDialogKeys.start));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      } else {
        await choose(tester, id, action);
        // Save waits for a change.
        if (action == EventAction.editDate) {
          await tester.enterText(
            find.byKey(EventDateDialogKeys.label),
            'Saturday',
          );
          await tester.pump();
        }
      }
      await submit(tester);
    }

    testWidgets("a host sees each date's menu with the actions its status "
        'allows', (tester) async {
      await show(
        tester,
        hosted([
          date('o-1'),
          date('o-2', day: 13, status: OccurrenceStatus.confirmed),
          date('o-3', day: 20, status: OccurrenceStatus.cancelled),
        ]),
        remote: answering(),
        onBack: back,
      );

      // Every date has one, so it names its date.
      expect(
        find.byTooltip('Actions for Fri, Nov 6 · 7:00 PM'),
        findsOneWidget,
      );
      final offered = {
        'o-1': ['Confirm', 'Edit', 'Decline', 'Remove'],
        'o-2': ['Edit', 'Cancel date', 'Remove'],
        'o-3': ['Edit', 'Remove'],
      };
      for (final MapEntry(key: id, value: items) in offered.entries) {
        await toggleMenu(tester, id);
        // Only the open menu builds its items.
        final shown = tester.widgetList<MenuItemButton>(
          find.byType(MenuItemButton),
        );
        expect(
          [for (final item in shown) (item.child! as BgeOnlineOnlyLabel).label],
          items,
          reason: id,
        );
        expect(shown.every((item) => item.onPressed != null), isTrue);
        await toggleMenu(tester, id);
      }
      expect(itemOf('o-1', EventAction.confirmDate), findsNothing);

      // A poll takes as many dates as the host likes.
      expect(find.byKey(EventDetailScreen.addDateKey), findsOneWidget);
      expect(find.text('Add a date'), findsOneWidget);
      expect(addOf(tester), isNotNull);

      // A fixed event holds one.
      cache.add(
        hosted([
          date('o-1', status: OccurrenceStatus.confirmed),
        ], schedulingMode: EventSchedulingMode.fixed),
      );
      await settle(tester);
      expect(find.byKey(EventDetailScreen.addDateKey), findsNothing);
      expect(menuOf('o-1'), findsOneWidget);
    });

    testWidgets('a proposed date that has passed offers only Edit and Remove', (
      tester,
    ) async {
      await show(
        tester,
        hosted([
          confirmed(
            'o-1',
            now.subtract(const Duration(days: 1)),
          ).copyWith(eventId: 'e-1', status: OccurrenceStatus.proposed),
        ]),
        remote: answering(),
        onBack: back,
      );

      await toggleMenu(tester, 'o-1');
      expect(
        [
          for (final item in tester.widgetList<MenuItemButton>(
            find.byType(MenuItemButton),
          ))
            (item.child! as BgeOnlineOnlyLabel).label,
        ],
        ['Edit', 'Remove'],
      );
    });

    testWidgets('a participant sees no menu and no Add a date', (tester) async {
      await show(
        tester,
        hosted([date('o-1')], role: EventRole.participant),
        remote: answering(),
        onBack: back,
      );

      expect(find.text('Fri, Nov 6 · 7:00 PM'), findsOneWidget);
      expect(menuOf('o-1'), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(find.byKey(EventDetailScreen.addDateKey), findsNothing);
    });

    testWidgets('a host with no server sees no date controls', (tester) async {
      // A date write goes straight to the server, never through the queue.
      await show(tester, hosted([date('o-1')]), onBack: back);

      expect(find.text('Fri, Nov 6 · 7:00 PM'), findsOneWidget);
      expect(menuOf('o-1'), findsNothing);
      expect(find.byKey(EventDetailScreen.addDateKey), findsNothing);
    });

    testWidgets('Add a date adds through the bloc and shows Date added', (
      tester,
    ) async {
      useViewSize(tester, const Size(400, 800));
      final remote = answering();
      await show(
        tester,
        hosted([date('o-1', sortOrder: 3)]),
        remote: remote,
        onBack: back,
      );

      await perform(tester, EventAction.addDate);

      expect(remote.dateRequests, [
        (
          call: 'add',
          eventId: 'e-1',
          occurrenceId: null,
          draft: EventOccurrenceDraft(startDate: now.toUtc()),
          // After the event's last date.
          sortOrder: 4,
          update: null,
          reason: null,
        ),
      ]);
      verify(() => repository.cacheOccurrence(any())).called(1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(inOutcome('Date added'), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.success);
      // The server derives the event's status from its dates.
      expect(remote.detailRequests, ['e-1', 'e-1']);
    });

    testWidgets('confirming asks first, then confirms', (tester) async {
      final remote = answering();
      await show(
        tester,
        hosted([date('o-1', label: 'Saturday')]),
        remote: remote,
        onBack: back,
      );
      await choose(tester, 'o-1', EventAction.confirmDate);

      expect(find.text('Confirm Saturday?'), findsOneWidget);
      expect(find.text(_confirmBodyCopy), findsOneWidget);

      await tester.tap(find.byKey(EventDateDialogKeys.dismiss));
      await animate(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.dateRequests, isEmpty);

      await choose(tester, 'o-1', EventAction.confirmDate);
      await submit(tester);

      expect(
        remote.dateRequests.map((r) => (r.call, r.eventId, r.occurrenceId)),
        [('confirm', 'e-1', 'o-1')],
      );
      expect(inOutcome('Date confirmed'), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.success);
    });

    testWidgets('removing a confirmed date asks once and cancels then '
        'removes', (tester) async {
      final remote = answering();
      await show(
        tester,
        hosted([
          date('o-1', status: OccurrenceStatus.confirmed, label: 'Saturday'),
        ]),
        remote: remote,
        onBack: back,
      );
      await choose(tester, 'o-1', EventAction.removeDate);

      expect(find.text('Remove Saturday?'), findsOneWidget);
      expect(find.text(_cancelRemoveBodyCopy), findsOneWidget);
      await tester.enterText(
        find.byKey(EventDateDialogKeys.reason),
        '  The venue flooded.  ',
      );
      await submit(tester);

      // The server removes a Confirmed date only once it is cancelled
      // (#446), and the reason goes with the cancel.
      expect(
        remote.dateRequests.map((r) => (r.call, r.occurrenceId, r.reason)),
        [('cancel', 'o-1', 'The venue flooded.'), ('remove', 'o-1', null)],
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(inOutcome('Date removed'), findsOneWidget);
      verify(
        () => repository.removeCachedOccurrence(
          eventId: 'e-1',
          occurrenceId: 'o-1',
        ),
      ).called(1);
    });

    testWidgets('a cancel with no reason sends none', (tester) async {
      final remote = answering();
      await show(
        tester,
        hosted([date('o-1', status: OccurrenceStatus.confirmed)]),
        remote: remote,
        onBack: back,
      );
      await choose(tester, 'o-1', EventAction.cancelDate);
      await tester.enterText(find.byKey(EventDateDialogKeys.reason), '   ');
      await submit(tester);

      // Blank, which the remote leaves out of the body (#506).
      expect(
        remote.dateRequests.map((r) => (r.call, r.occurrenceId, r.reason)),
        [('cancel', 'o-1', '')],
      );
      expect(inOutcome('Date cancelled'), findsOneWidget);
    });

    testWidgets('a changed answer shows its banner and re-reads', (
      tester,
    ) async {
      final remote = answering(
        written: (_) =>
            throw const EventWriteConflictException('moved', statusCode: 400),
      );
      await show(tester, hosted([date('o-1')]), remote: remote, onBack: back);
      expect(remote.detailRequests, ['e-1']);
      await perform(tester, EventAction.confirmDate);

      expect(inOutcome(_dateChangedCopy), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.warning);
      expect(remote.detailRequests, ['e-1', 'e-1']);
      verifyNever(() => repository.cacheOccurrence(any()));
    });

    group('each end has its copy and tone', () {
      const transient = EventRemoteTransientException('offline');
      const permanent = EventRemotePermanentException(
        'broken',
        statusCode: 500,
      );
      final ends = [
        (
          name: 'an edit done',
          action: EventAction.editDate,
          status: OccurrenceStatus.proposed,
          thrown: null as Object?,
          on: null as String?,
          session: true,
          copy: 'Date saved',
          tone: BgeBannerTone.success,
        ),
        (
          name: 'a decline done',
          action: EventAction.declineDate,
          status: OccurrenceStatus.proposed,
          thrown: null,
          on: null,
          session: true,
          copy: 'Date declined',
          tone: BgeBannerTone.success,
        ),
        (
          name: 'a cancel done',
          action: EventAction.cancelDate,
          status: OccurrenceStatus.confirmed,
          thrown: null,
          on: null,
          session: true,
          copy: 'Date cancelled',
          tone: BgeBannerTone.success,
        ),
        (
          name: "a proposed date's remove done",
          action: EventAction.removeDate,
          status: OccurrenceStatus.proposed,
          thrown: null,
          on: null,
          session: true,
          copy: 'Date removed',
          tone: BgeBannerTone.success,
        ),
        (
          name: 'a gone date',
          action: EventAction.confirmDate,
          status: OccurrenceStatus.proposed,
          thrown: const EventRemoteNotFoundException('gone') as Object?,
          on: null,
          session: true,
          copy: _dateGoneCopy,
          tone: BgeBannerTone.warning,
        ),
        (
          // What the remove asked for, as a second press after a lost
          // answer finds it.
          name: 'a gone remove',
          action: EventAction.removeDate,
          status: OccurrenceStatus.proposed,
          thrown: const EventRemoteNotFoundException('gone') as Object?,
          on: null,
          session: true,
          copy: _dateGoneCopy,
          tone: BgeBannerTone.success,
        ),
        (
          name: 'a refusal',
          action: EventAction.confirmDate,
          status: OccurrenceStatus.proposed,
          thrown: const EventWriteRefusedException('no', statusCode: 403),
          on: null,
          session: true,
          copy: _dateRefusedCopy,
          tone: BgeBannerTone.warning,
        ),
        (
          name: 'a cancel then remove whose remove failed',
          action: EventAction.removeDate,
          status: OccurrenceStatus.confirmed,
          thrown: transient,
          on: 'remove',
          session: true,
          copy: _dateCancelledRemoveUnconfirmedCopy,
          tone: BgeBannerTone.warning,
        ),
        (
          name: 'a transient failure',
          action: EventAction.confirmDate,
          status: OccurrenceStatus.proposed,
          thrown: transient,
          on: null,
          session: true,
          copy: _dateFailedCopy,
          tone: BgeBannerTone.error,
        ),
        (
          name: 'any other failure',
          action: EventAction.confirmDate,
          status: OccurrenceStatus.proposed,
          thrown: permanent,
          on: null,
          session: true,
          copy: _dateFailedUnexpectedCopy,
          tone: BgeBannerTone.error,
        ),
        (
          name: 'a transient failure of an add',
          action: EventAction.addDate,
          status: OccurrenceStatus.proposed,
          thrown: transient,
          on: null,
          session: true,
          copy: _dateAddFailedCopy,
          tone: BgeBannerTone.error,
        ),
        (
          name: 'any other failure of an add',
          action: EventAction.addDate,
          status: OccurrenceStatus.proposed,
          thrown: permanent,
          on: null,
          session: true,
          copy: _dateAddFailedCopy,
          tone: BgeBannerTone.error,
        ),
        (
          // Nothing was sent, so there is no date to check.
          name: 'an add the session stopped',
          action: EventAction.addDate,
          status: OccurrenceStatus.proposed,
          thrown: null,
          on: null,
          session: false,
          copy: _dateFailedUnexpectedCopy,
          tone: BgeBannerTone.error,
        ),
      ];

      for (final end in ends) {
        testWidgets('${end.name}: ${end.copy}', (tester) async {
          useViewSize(tester, const Size(400, 800));
          var session = true;
          final remote = answering(
            written: (request) {
              final thrown = end.thrown;
              if (thrown != null && (end.on ?? request.call) == request.call) {
                throw thrown;
              }
              return date(request.occurrenceId ?? 'o-9');
            },
          );
          await show(
            tester,
            hosted([date('o-1', status: end.status)]),
            remote: remote,
            onBack: back,
            confirmSession: () async => session,
          );
          session = end.session;

          await perform(tester, end.action);

          expect(inOutcome(end.copy), findsOneWidget);
          expect(toneOf(tester), end.tone);
        });
      }
    });

    testWidgets('a date action waits for a running read', (tester) async {
      // The read's answer, landing after the write, would put the date back
      // as it was (#589).
      final reads = <Completer<EventSnapshot>>[];
      final remote = FakeEventRemote.detail((_) {
        final read = Completer<EventSnapshot>();
        reads.add(read);
        return read.future;
      }, dateWritten: (request) => date('o-1'));
      await show(tester, hosted([date('o-1')]), remote: remote, onBack: back);

      // The open's read is running.
      expect(addOf(tester), isNull);
      await toggleMenu(tester, 'o-1');
      expect(
        tester
            .widget<MenuItemButton>(itemOf('o-1', EventAction.confirmDate))
            .onPressed,
        isNull,
      );
      await toggleMenu(tester, 'o-1');

      // A failed read leaves a retry to offer, and the dates enabled.
      reads.single.completeError(_offline);
      await settle(tester);
      expect(addOf(tester), isNotNull);
      await choose(tester, 'o-1', EventAction.confirmDate);

      blocOf(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      expect(reads, hasLength(2));
      await submit(tester);

      expect(remote.dateRequests, isEmpty);

      // Held back for the read to end, not dropped: an add or edit would
      // lose what was typed.
      reads[1].complete(hosted([date('o-1')]).snapshot);
      await settle(tester);
      expect(remote.dateRequests.map((r) => r.call), ['confirm']);
    });

    testWidgets('a date action held back for a read that finds the event '
        'gone is not sent', (tester) async {
      final reads = <Completer<EventSnapshot>>[];
      final remote = FakeEventRemote.detail((_) {
        final read = Completer<EventSnapshot>();
        reads.add(read);
        return read.future;
      }, dateWritten: (request) => date('o-1'));
      await show(tester, hosted([date('o-1')]), remote: remote, onBack: back);
      reads.single.completeError(_offline);
      await settle(tester);
      await choose(tester, 'o-1', EventAction.confirmDate);

      blocOf(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      await submit(tester);
      reads[1].completeError(const EventRemoteNotFoundException('gone'));
      await settle(tester);

      expect(remote.dateRequests, isEmpty);
      expect(find.byKey(EventDetailScreen.notFoundKey), findsOneWidget);
    });

    for (final action in [EventAction.editDate, EventAction.removeDate]) {
      testWidgets('${action.name} is not sent for an event cancelled while '
          'its dialog was open', (tester) async {
        // The server still takes both on a cancelled event (backend#956).
        final remote = answering();
        await show(tester, hosted([date('o-1')]), remote: remote, onBack: back);
        await choose(tester, 'o-1', action);
        if (action == EventAction.editDate) {
          await tester.enterText(
            find.byKey(EventDateDialogKeys.label),
            'Saturday',
          );
          await tester.pump();
        }

        // A sync lands the event cancelled under the dialog.
        cache.add(
          _detail(
            event: _event(
              schedulingMode: EventSchedulingMode.poll,
              status: EventStatus.cancelled,
            ),
            occurrences: [date('o-1')],
            attendance: _attending(EventRole.host),
          ),
        );
        await settle(tester);
        await submit(tester);

        expect(remote.dateRequests, isEmpty);
        expect(menuOf('o-1'), findsNothing);
      });
    }

    for (final action in [
      EventAction.confirmDate,
      EventAction.declineDate,
      EventAction.cancelDate,
    ]) {
      testWidgets('${action.name} is not sent for a host made an organizer '
          'while its dialog was open', (tester) async {
        // The server still takes all three from an organizer
        // (backend#979).
        final status = action == EventAction.cancelDate
            ? OccurrenceStatus.confirmed
            : OccurrenceStatus.proposed;
        final remote = answering();
        await show(
          tester,
          hosted([date('o-1', status: status)]),
          remote: remote,
          onBack: back,
        );
        await choose(tester, 'o-1', action);

        // A sync lands the viewer's new role under the dialog.
        cache.add(
          hosted([date('o-1', status: status)], role: EventRole.organizer),
        );
        await settle(tester);
        await submit(tester);

        expect(remote.dateRequests, isEmpty);
      });
    }

    testWidgets('nothing on the dates may be pressed while a write is out', (
      tester,
    ) async {
      final writing = Completer<EventOccurrence?>();
      final remote = answering(written: (_) => writing.future);
      await show(tester, hosted([date('o-1')]), remote: remote, onBack: back);
      await perform(tester, EventAction.confirmDate);
      expect(remote.dateRequests, hasLength(1));

      expect(addOf(tester), isNull);
      await toggleMenu(tester, 'o-1');
      expect(
        tester
            .widget<MenuItemButton>(itemOf('o-1', EventAction.removeDate))
            .onPressed,
        isNull,
      );
      await toggleMenu(tester, 'o-1');

      writing.complete(date('o-1', status: OccurrenceStatus.confirmed));
      await animate(tester);

      expect(inOutcome('Date confirmed'), findsOneWidget);
      expect(addOf(tester), isNotNull);
    });

    testWidgets('a date action after a reconcile sends the server id', (
      tester,
    ) async {
      // An event created here opens on its local id, and the detail follows
      // the reconcile to the server's (#499). Only the followed copy offers
      // the dates' actions, and the server knows it by the server's id.
      final moved = StreamController<EventDetail?>.broadcast();
      addTearDown(moved.close);
      when(() => repository.watchEvent('srv-1'))
          .thenAnswer((_) => moved.stream);
      final remote = answering();
      await show(
        tester,
        _detail(
          event: _event(schedulingMode: EventSchedulingMode.poll)
              .copyWith(isLocalOnly: true),
          occurrences: [date('o-1')],
          attendance: _attending(EventRole.host),
        ),
        remote: remote,
        onBack: back,
      );
      expect(menuOf('o-1'), findsNothing);
      expect(find.byKey(EventDetailScreen.addDateKey), findsNothing);

      when(() => repository.reconciledEventId('e-1')).thenReturn('srv-1');
      cache.add(null);
      await settle(tester);
      moved.add(
        _detail(
          event: _event(schedulingMode: EventSchedulingMode.poll)
              .copyWith(id: 'srv-1'),
          occurrences: [date('o-2').copyWith(eventId: 'srv-1')],
          attendance: _attending(EventRole.host),
        ),
      );
      await settle(tester);
      await perform(tester, EventAction.confirmDate, id: 'o-2');

      // Not e-1, the id the screen was opened on.
      expect(
        remote.dateRequests.map((r) => (r.call, r.eventId, r.occurrenceId)),
        [('confirm', 'srv-1', 'o-2')],
      );
    });

    testWidgets('a cancelled date shows its reason', (tester) async {
      await show(
        tester,
        _detail(
          occurrences: [
            date('o-1', status: OccurrenceStatus.cancelled).copyWith(
              cancelReason: 'The venue flooded.',
              location: 'The back room',
            ),
          ],
        ),
      );

      final reason = inSection(
        EventDetailScreen.datesKey,
        'Reason: The venue flooded.',
      );
      expect(reason, findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Cancelled')).dy,
        lessThan(tester.getTopLeft(reason).dy),
      );
      // Quiet, as its venue is.
      expect(
        tester.widget<Text>(reason).style?.color,
        BgeTheme.light().colorScheme.onSurfaceVariant,
      );
      // Read with the rest of the date.
      expect(
        tester.getSemantics(find.text('Cancelled')).label,
        contains('Reason: The venue flooded.'),
      );
    });

    testWidgets('the menu is held to the screen at 320dp and 2.0 text', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 640));
      await show(
        tester,
        hosted([
          date(
            'o-1',
            status: OccurrenceStatus.confirmed,
            label: 'The first and longest evening of the whole tournament',
          ),
        ]),
        remote: answering(),
        onBack: back,
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );
      expect(tester.takeException(), isNull);
      // At this size the page scrolls to reach the date.
      await tester.ensureVisible(menuOf('o-1'));
      await tester.pump();
      await toggleMenu(tester, 'o-1');

      expect(tester.takeException(), isNull);
      const window = Rect.fromLTWH(0, 0, 320, 640);
      for (final action in [
        EventAction.editDate,
        EventAction.cancelDate,
        EventAction.removeDate,
      ]) {
        final rect = tester.getRect(itemOf('o-1', action));
        expect(window.intersect(rect), rect, reason: action.name);
      }
    });
  });

  group('poll (#507)', () {
    const available = AvailabilityResponse.available;
    const maybe = AvailabilityResponse.maybe;
    const unavailable = AvailabilityResponse.unavailable;
    const responses = [available, maybe, unavailable];
    const window = Rect.fromLTWH(0, 0, 320, 640);
    const longLabel = 'The first and longest evening of the whole tournament';

    setUpAll(() {
      registerFallbackValue(confirmed('o-fallback', kItemInstant));
    });

    setUp(() {
      when(() => repository.cacheOccurrence(any()))
          .thenAnswer((_) async => true);
    });

    /// Date [id] of `e-1`, Proposed unless [status] says otherwise, on the
    /// evening of November [day].
    EventOccurrence date(
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

    /// The viewer's own row on `e-1`, `att-me`, holding [role] and answered
    /// [status].
    EventAttendee me({
      EventRole role = EventRole.participant,
      EventParticipationStatus status = EventParticipationStatus.attending,
    }) => attendance(status).copyWith(eventId: 'e-1', role: role);

    /// Poll event `e-1`, Scheduled unless [status] says otherwise, holding
    /// [occurrences], with [viewer] (an attending participant by default) on
    /// it and [attendees] on the roster.
    EventDetail poll(
      List<EventOccurrence> occurrences, {
      EventAttendee? viewer,
      List<EventAttendee>? attendees,
      EventStatus status = EventStatus.scheduled,
    }) => _detail(
      event: _event(schedulingMode: EventSchedulingMode.poll, status: status),
      occurrences: occurrences,
      attendees: attendees,
      attendance: viewer ?? me(),
    );

    AvailabilityVoter voter(
      String attendeeId,
      AvailabilityResponse response, {
      bool eligible = true,
    }) => AvailabilityVoter(
      attendeeId: attendeeId,
      response: response,
      eligible: eligible,
    );

    /// Date [id]'s tallies, counted from those of its [voters] that count,
    /// as the server counts them.
    OccurrenceAvailability tally(String id, List<AvailabilityVoter> voters) {
      int count(AvailabilityResponse response) => voters
          .where((voter) => voter.eligible && voter.response == response)
          .length;
      return OccurrenceAvailability(
        occurrenceId: id,
        available: count(available),
        maybe: count(maybe),
        unavailable: count(unavailable),
        voters: voters,
      );
    }

    AvailabilitySummary summaryOf(List<OccurrenceAvailability> occurrences) =>
        AvailabilitySummary(occurrences: occurrences);

    AvailabilityVote voteOf(EventVoteRequest request) => AvailabilityVote(
      id: 'v-1',
      occurrenceId: request.occurrenceId,
      attendeeId: 'att-me',
      response: request.response,
      createdAt: kItemInstant,
      updatedAt: kItemInstant,
    );

    /// A server whose reads answer at once from [read], whose votes answer
    /// from [voted] (done, by default), whose poll reads answer from
    /// [summary] (by default, the viewer's answers it took and nobody
    /// else's), whose date writes answer from [written] (with the date they
    /// named, by default), and whose deletes answer from [deleted] (done, by
    /// default).
    FakeEventRemote serving({
      FutureOr<EventSnapshot> Function(String id)? read,
      FutureOr<AvailabilityVote> Function(EventVoteRequest request)? voted,
      FutureOr<AvailabilitySummary> Function(String eventId)? summary,
      FutureOr<EventOccurrence?> Function(EventDateRequest request)? written,
      FutureOr<void> Function(String id)? deleted,
    }) {
      final held = <String, AvailabilityResponse>{};
      return FakeEventRemote.detail(
        read ?? (_) => _detail().snapshot,
        voted: (request) async {
          final vote = await (voted ?? voteOf)(request);
          held[request.occurrenceId] = vote.response;
          return vote;
        },
        summary:
            summary ??
            (_) => summaryOf([
              for (final MapEntry(key: id, value: response) in held.entries)
                tally(id, [voter('att-me', response)]),
            ]),
        dateWritten:
            written ?? (request) => date(request.occurrenceId ?? 'o-9'),
        deleted: deleted ?? (_) {},
      );
    }

    void back(BuildContext _) {}

    Finder answer(String id, AvailabilityResponse response) =>
        find.byKey(EventDetailScreen.pollAnswerKey(id, response));

    ChoiceChip chipOf(
      WidgetTester tester,
      String id,
      AvailabilityResponse response,
    ) => tester.widget<ChoiceChip>(answer(id, response));

    /// The answer date [id]'s chips show as chosen, or null for none.
    AvailabilityResponse? chosen(WidgetTester tester, String id) {
      for (final response in responses) {
        if (chipOf(tester, id, response).selected) return response;
      }
      return null;
    }

    Future<void> reveal(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
    }

    Future<void> tapAnswer(
      WidgetTester tester,
      String id,
      AvailabilityResponse response,
    ) async {
      await reveal(tester, answer(id, response));
      await tester.tap(answer(id, response));
      await tester.pump();
    }

    String? talliesOf(WidgetTester tester, String id) =>
        textOf(tester, find.byKey(EventDetailScreen.pollTalliesKey(id)));

    String? leaderOf(WidgetTester tester, String id) {
      final leader = find.byKey(EventDetailScreen.pollLeaderKey(id));
      return leader.evaluate().isEmpty ? null : textOf(tester, leader);
    }

    Finder pollOutcome() => find.byKey(EventDetailScreen.pollOutcomeKey);

    Finder inPollOutcome(String text) =>
        find.descendant(of: pollOutcome(), matching: find.text(text));

    BgeBannerTone pollToneOf(WidgetTester tester) =>
        tester.widget<BgeInlineBanner>(pollOutcome()).tone;

    Finder inDates(String text) => inSection(EventDetailScreen.datesKey, text);

    /// Expects [finder] wholly inside a 320 by 640 window once scrolled to,
    /// and hit by a tap there.
    Future<void> expectReachable(
      WidgetTester tester,
      Finder finder, {
      String? reason,
    }) async {
      await reveal(tester, finder);
      final rect = tester.getRect(finder);
      expect(window.intersect(rect), rect, reason: reason);
      expect(finder.hitTestable(), findsOneWidget, reason: reason);
    }

    testWidgets('a participant answers a proposed date, and the chip shows '
        'it at once', (tester) async {
      final vote = Completer<AvailabilityVote>();
      var summary = summaryOf(const []);
      final remote = serving(
        voted: (_) => vote.future,
        summary: (_) => summary,
      );
      await show(
        tester,
        poll([date('o-1'), date('o-2', day: 13, sortOrder: 1)]),
        remote: remote,
        onBack: back,
      );
      expect(chosen(tester, 'o-1'), isNull);
      expect(chosen(tester, 'o-2'), isNull);
      // Attending, so their answers count.
      expect(inDates(_pollNotCountingCopy), findsNothing);

      await tapAnswer(tester, 'o-1', maybe);

      // Before the server has answered.
      expect(remote.voteRequests, [
        (eventId: 'e-1', occurrenceId: 'o-1', response: maybe),
      ]);
      expect(chosen(tester, 'o-1'), maybe);
      expect(chosen(tester, 'o-2'), isNull);

      // Once it has, the poll is read again, and holds the answer.
      summary = summaryOf([
        tally('o-1', [voter('att-me', maybe)]),
      ]);
      final reads = remote.summaryRequests.length;
      vote.complete(voteOf(remote.voteRequests.single));
      await settle(tester);

      expect(remote.summaryRequests, hasLength(reads + 1));
      expect(chosen(tester, 'o-1'), maybe);
      expect(talliesOf(tester, 'o-1'), '0 available · 1 maybe · 0 unavailable');
      // Done isn't announced.
      expect(pollOutcome(), findsNothing);
    });

    testWidgets("tallies, the leader and who hasn't answered show from the "
        'summary', (tester) async {
      final roster = [
        me(),
        _member('att-2', displayName: 'Ada'),
        // Neither a spectator nor a guest with no account votes, and the
        // vote of someone not attending doesn't count.
        _member('att-3', displayName: 'Bo', role: EventRole.spectator),
        _guest('att-4', 'Cy'),
        _member(
          'att-5',
          displayName: 'Di',
          status: EventParticipationStatus.notAttending,
        ),
      ];
      var summary = summaryOf([
        tally('o-1', [voter('att-me', available), voter('att-2', available)]),
        tally('o-2', [
          voter('att-me', available),
          voter('att-5', unavailable, eligible: false),
        ]),
        tally('o-4', [voter('att-me', unavailable)]),
      ]);
      final dates = [
        date('o-1'),
        date('o-2', day: 13, sortOrder: 1),
        // The summary doesn't list it.
        date('o-3', day: 20, sortOrder: 2),
        date('o-4', day: 27, sortOrder: 3, status: OccurrenceStatus.confirmed),
      ];
      await show(
        tester,
        poll(dates, attendees: roster),
        remote: serving(summary: (_) => summary),
        onBack: back,
      );

      expect(talliesOf(tester, 'o-1'), '2 available · 0 maybe · 0 unavailable');
      expect(talliesOf(tester, 'o-2'), '1 available · 0 maybe · 0 unavailable');
      expect(find.byKey(EventDetailScreen.pollTalliesKey('o-3')), findsNothing);
      // A confirmed date has no poll.
      expect(find.byKey(EventDetailScreen.pollTalliesKey('o-4')), findsNothing);
      expect(answer('o-4', available), findsNothing);

      expect(leaderOf(tester, 'o-1'), 'Most available');
      expect(leaderOf(tester, 'o-2'), isNull);
      expect(leaderOf(tester, 'o-3'), isNull);

      // Ada hasn't answered o-2. Everyone who votes answered o-1, and o-3
      // has no tallies to count against.
      final awaiting = inDates("1 person hasn't answered");
      expect(awaiting, findsOneWidget);
      expect(inDates("2 people haven't answered"), findsNothing);
      expect(
        tester.getTopLeft(awaiting).dy,
        greaterThan(
          tester
              .getTopLeft(find.byKey(EventDetailScreen.pollTalliesKey('o-2')))
              .dy,
        ),
      );
      expect(
        tester.getTopLeft(awaiting).dy,
        lessThan(tester.getTopLeft(answer('o-3', available)).dy),
      );

      // The viewer's own answer, from the summary.
      expect(chosen(tester, 'o-1'), available);
      expect(chosen(tester, 'o-3'), isNull);
      // A participant confirms nothing.
      expect(
        find.byKey(EventDetailScreen.confirmLeaderKey('o-1')),
        findsNothing,
      );

      // Level on Available and on Unavailable: tied, and no single leader.
      summary = summaryOf([
        tally('o-1', [voter('att-me', available), voter('att-2', maybe)]),
        tally('o-2', [voter('att-me', available), voter('att-2', maybe)]),
        tally('o-3', const []),
      ]);
      blocOf(tester).add(const EventDetailRetryRequested());
      await settle(tester);

      expect(leaderOf(tester, 'o-1'), 'Tied for most available');
      expect(leaderOf(tester, 'o-2'), 'Tied for most available');
      expect(leaderOf(tester, 'o-3'), isNull);
      expect(inDates("2 people haven't answered"), findsOneWidget);
      expect(inDates("1 person hasn't answered"), findsNothing);
    });

    testWidgets('each answer, and Confirm this date, names its date', (
      tester,
    ) async {
      await show(
        tester,
        poll([
          date('o-1', label: 'Saturday'),
          date('o-2', day: 13, sortOrder: 1, label: 'Sunday'),
        ], viewer: me(role: EventRole.host)),
        remote: serving(
          summary: (_) => summaryOf([
            tally('o-1', [voter('att-me', available)]),
          ]),
        ),
        onBack: back,
      );

      // The group, and each answer in it: a screen reader doesn't always
      // say a group's name with each of its children.
      expect(find.bySemanticsLabel('Your answer for Saturday'), findsOneWidget);
      expect(find.bySemanticsLabel('Your answer for Sunday'), findsOneWidget);
      for (final (label, selected) in [
        ('Available for Saturday', true),
        ('Maybe for Saturday', false),
        ('Unavailable for Saturday', false),
        ('Available for Sunday', false),
        ('Maybe for Sunday', false),
        ('Unavailable for Sunday', false),
      ]) {
        expect(
          tester.getSemantics(find.bySemanticsLabel(label)),
          isSemantics(
            label: label,
            isButton: true,
            hasSelectedState: true,
            isSelected: selected,
            isEnabled: true,
          ),
          reason: label,
        );
      }

      // Read without the dot between the tallies.
      expect(
        find.bySemanticsLabel(
          RegExp('1 available, 0 maybe, 0 unavailable\nMost available'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(
          find.bySemanticsLabel('Confirm this date, Saturday'),
        ),
        isSemantics(isButton: true, isEnabled: true),
      );
    });

    testWidgets('a spectator sees the tallies but no chips', (tester) async {
      await show(
        tester,
        poll([date('o-1')], viewer: me(role: EventRole.spectator)),
        remote: serving(
          summary: (_) => summaryOf([
            tally('o-1', [voter('att-2', available)]),
          ]),
        ),
        onBack: back,
      );

      expect(talliesOf(tester, 'o-1'), '1 available · 0 maybe · 0 unavailable');
      expect(leaderOf(tester, 'o-1'), 'Most available');
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Your answer for')), findsNothing);
    });

    testWidgets('a viewer not attending sees the note, and can still answer', (
      tester,
    ) async {
      final remote = serving();
      await show(
        tester,
        poll([
          date('o-1'),
        ], viewer: me(status: EventParticipationStatus.notAttending)),
        remote: remote,
        onBack: back,
      );

      final note = inDates(_pollNotCountingCopy);
      expect(note, findsOneWidget);
      // Above the dates.
      expect(
        tester.getTopLeft(note).dy,
        lessThan(tester.getTopLeft(find.text('Fri, Nov 6 · 7:00 PM')).dy),
      );

      await tapAnswer(tester, 'o-1', available);

      expect(remote.voteRequests, [
        (eventId: 'e-1', occurrenceId: 'o-1', response: available),
      ]);
      expect(chosen(tester, 'o-1'), available);
    });

    testWidgets('a cancelled poll event shows tallies but no chips', (
      tester,
    ) async {
      await show(
        tester,
        poll(
          [date('o-1'), date('o-2', day: 13, sortOrder: 1)],
          viewer: me(
            role: EventRole.host,
            status: EventParticipationStatus.notAttending,
          ),
          status: EventStatus.cancelled,
        ),
        remote: serving(
          summary: (_) => summaryOf([
            tally('o-1', [voter('att-2', available)]),
          ]),
        ),
        onBack: back,
      );

      expect(talliesOf(tester, 'o-1'), '1 available · 0 maybe · 0 unavailable');
      expect(leaderOf(tester, 'o-1'), 'Most available');
      expect(find.byType(ChoiceChip), findsNothing);
      // Nothing to answer, so nothing to say about answers counting, and
      // nothing to confirm.
      expect(inDates(_pollNotCountingCopy), findsNothing);
      expect(
        find.byKey(EventDetailScreen.confirmLeaderKey('o-1')),
        findsNothing,
      );
    });

    testWidgets('a changed vote shows its banner, re-reads the event, and the '
        'date loses its chips', (tester) async {
      // Confirmed elsewhere meanwhile, as the second read says.
      final served = [
        poll([date('o-1'), date('o-2', day: 13, sortOrder: 1)]),
        poll([
          date('o-1', status: OccurrenceStatus.confirmed),
          date('o-2', day: 13, sortOrder: 1),
        ]),
      ];
      var read = 0;
      when(
        () => repository.cacheEvent(any(), source: any(named: 'source')),
      ).thenAnswer((invocation) async {
        cache.add(
          EventDetail(
            snapshot: invocation.positionalArguments.single as EventSnapshot,
            attendance: me(),
          ),
        );
      });
      final remote = serving(
        read: (_) => served[read++ == 0 ? 0 : 1].snapshot,
        voted: (_) =>
            throw const EventWriteConflictException('moved', statusCode: 400),
      );
      await show(tester, served.first, remote: remote, onBack: back);
      expect(answer('o-1', available), findsOneWidget);

      await tapAnswer(tester, 'o-1', available);
      await settle(tester);

      expect(inPollOutcome(_pollChangedCopy), findsOneWidget);
      expect(pollToneOf(tester), BgeBannerTone.warning);
      // The vote's banner, not the actions'.
      expect(outcome(), findsNothing);
      expect(remote.detailRequests, ['e-1', 'e-1']);
      expect(inDates('Confirmed'), findsOneWidget);
      expect(answer('o-1', available), findsNothing);
      expect(answer('o-2', available), findsOneWidget);

      final dismiss = find.descendant(
        of: pollOutcome(),
        matching: find.text('Dismiss'),
      );
      await reveal(tester, dismiss);
      await tester.tap(dismiss);
      await tester.pump();
      expect(pollOutcome(), findsNothing);
    });

    testWidgets('a vote that asks for a read during a read reads again once '
        'that one ends', (tester) async {
      // The running read may have been answered before the vote found the
      // date moved, so it can't be trusted to show it.
      final reads = <Completer<EventSnapshot>>[];
      when(
        () => repository.cacheEvent(any(), source: any(named: 'source')),
      ).thenAnswer((invocation) async {
        cache.add(
          EventDetail(
            snapshot: invocation.positionalArguments.single as EventSnapshot,
            attendance: me(),
          ),
        );
      });
      final remote = serving(
        read: (_) {
          final read = Completer<EventSnapshot>();
          reads.add(read);
          return read.future;
        },
        voted: (_) =>
            throw const EventWriteConflictException('moved', statusCode: 400),
      );
      await show(tester, poll([date('o-1')]), remote: remote, onBack: back);
      await settle(tester);
      expect(reads, hasLength(1));

      await tapAnswer(tester, 'o-1', available);
      await settle(tester);
      expect(inPollOutcome(_pollChangedCopy), findsOneWidget);
      expect(reads, hasLength(1));

      // Served before the date moved.
      reads.single.complete(poll([date('o-1')]).snapshot);
      await settle(tester);
      expect(answer('o-1', available), findsOneWidget);
      expect(reads, hasLength(2));

      reads.last.complete(
        poll([date('o-1', status: OccurrenceStatus.confirmed)]).snapshot,
      );
      await settle(tester);
      expect(inDates('Confirmed'), findsOneWidget);
      expect(answer('o-1', available), findsNothing);
      expect(reads, hasLength(2));
    });

    for (final confirmFails in [false, true]) {
      testWidgets(
        'a vote that asks for a read while a confirm is out waits for it'
        '${confirmFails ? ', and reads once the confirm fails' : ''}',
        (tester) async {
          final vote = Completer<AvailabilityVote>();
          final confirming = Completer<EventOccurrence?>();
          final remote = serving(
            voted: (_) => vote.future,
            summary: (_) => summaryOf([
              tally('o-1', [
                voter('att-me', available),
                voter('att-2', available),
              ]),
            ]),
            written: (request) => request.call == 'confirm'
                ? confirming.future
                : date(
                    request.occurrenceId!,
                    status: OccurrenceStatus.declined,
                  ),
          );
          await show(
            tester,
            poll([
              date('o-1', label: 'Saturday'),
              date('o-2', day: 13, sortOrder: 1),
            ], viewer: me(role: EventRole.host)),
            remote: remote,
            onBack: back,
          );
          expect(remote.detailRequests, ['e-1']);

          // A vote on o-2, still out when the host confirms o-1 and
          // declines the others.
          await tapAnswer(tester, 'o-2', maybe);
          final confirm = find.byKey(EventDetailScreen.confirmLeaderKey('o-1'));
          await reveal(tester, confirm);
          await tester.tap(confirm);
          await animate(tester);
          await tester.tap(find.byKey(EventDetailScreen.declineOthersKey));
          await tester.pump();
          await tester.tap(find.byKey(EventDateDialogKeys.submit));
          await animate(tester);
          expect(remote.dateRequests.map((r) => r.call), ['confirm']);

          // The vote finds o-2 moved, and its read waits for the write: an
          // answer landing after the write's would put the date back as it
          // was (#589).
          vote.completeError(
            const EventWriteConflictException('moved', statusCode: 400),
          );
          await settle(tester);
          expect(inPollOutcome(_pollChangedCopy), findsOneWidget);
          expect(remote.detailRequests, ['e-1']);

          if (confirmFails) {
            confirming.completeError(_offline);
          } else {
            confirming.complete(
              date('o-1', status: OccurrenceStatus.confirmed),
            );
          }
          await animate(tester);

          // One read once the write ends. A done confirm's own read covers
          // the vote's. A transient failure asks for none, so the vote's
          // is the one.
          expect(
            remote.dateRequests.map((r) => r.call),
            confirmFails ? ['confirm'] : ['confirm', 'decline'],
          );
          expect(remote.detailRequests, ['e-1', 'e-1']);
          await animate(tester);
          expect(remote.detailRequests, ['e-1', 'e-1']);
        },
      );
    }

    testWidgets('a vote that asks for a read while a confirm is out reads '
        'nothing once the screen has closed', (tester) async {
      final vote = Completer<AvailabilityVote>();
      final confirming = Completer<EventOccurrence?>();
      final remote = serving(
        voted: (_) => vote.future,
        summary: (_) => summaryOf([
          tally('o-1', [voter('att-me', available), voter('att-2', available)]),
        ]),
        written: (_) => confirming.future,
      );
      await show(
        tester,
        poll([
          date('o-1', label: 'Saturday'),
          date('o-2', day: 13, sortOrder: 1),
        ], viewer: me(role: EventRole.host)),
        remote: remote,
        onBack: back,
      );

      await tapAnswer(tester, 'o-2', maybe);
      final confirm = find.byKey(EventDetailScreen.confirmLeaderKey('o-1'));
      await reveal(tester, confirm);
      await tester.tap(confirm);
      await animate(tester);
      await tester.tap(find.byKey(EventDateDialogKeys.submit));
      await animate(tester);

      vote.completeError(
        const EventWriteConflictException('moved', statusCode: 400),
      );
      await settle(tester);

      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      confirming.complete(date('o-1', status: OccurrenceStatus.confirmed));
      await settle(tester);

      expect(remote.detailRequests, ['e-1']);
    });

    testWidgets('a vote that asks for a read while Delete is out reads '
        'nothing once the event is deleted', (tester) async {
      final vote = Completer<AvailabilityVote>();
      final deleting = Completer<void>();
      final remote = serving(
        voted: (_) => vote.future,
        deleted: (_) => deleting.future,
      );
      await show(
        tester,
        poll([date('o-1')], viewer: me(role: EventRole.host)),
        remote: remote,
        onBack: back,
      );

      await tapAnswer(tester, 'o-1', maybe);
      await tester.tap(find.byKey(EventDetailScreen.moreActionsKey));
      await animate(tester);
      await tester.tap(find.byKey(EventDetailScreen.deleteKey));
      await animate(tester);
      await tester.tap(find.byKey(EventDetailScreen.deleteConfirmKey));
      await animate(tester);
      expect(remote.deleteRequests, ['e-1']);

      vote.completeError(
        const EventWriteConflictException('moved', statusCode: 400),
      );
      await settle(tester);
      expect(remote.detailRequests, ['e-1']);

      // A read now could cache the deleted event again (#501).
      deleting.complete();
      await animate(tester);
      expect(remote.detailRequests, ['e-1']);
    });

    group('each vote end has its copy and tone', () {
      final ends = [
        (
          name: 'a gone date',
          thrown: const EventRemoteNotFoundException('gone') as Object?,
          session: true,
          copy: _dateGoneCopy,
          tone: BgeBannerTone.warning,
          rereads: true,
        ),
        (
          name: 'a refusal',
          thrown: const EventWriteRefusedException('no', statusCode: 403),
          session: true,
          copy: _pollRefusedCopy,
          tone: BgeBannerTone.warning,
          rereads: true,
        ),
        (
          name: 'a transient failure',
          thrown: _offline,
          session: true,
          copy: _pollFailedCopy,
          tone: BgeBannerTone.error,
          rereads: false,
        ),
        (
          name: 'a vote the session stopped',
          thrown: null,
          session: false,
          copy: _pollFailedCopy,
          tone: BgeBannerTone.error,
          rereads: false,
        ),
      ];

      for (final end in ends) {
        testWidgets('${end.name}: ${end.copy}', (tester) async {
          var session = true;
          final remote = serving(voted: (_) => throw end.thrown!);
          await show(
            tester,
            poll([date('o-1')]),
            remote: remote,
            onBack: back,
            confirmSession: () async => session,
          );
          session = end.session;

          await tapAnswer(tester, 'o-1', available);
          await settle(tester);

          expect(inPollOutcome(end.copy), findsOneWidget);
          expect(pollToneOf(tester), end.tone);
          expect(remote.detailRequests, end.rereads ? ['e-1', 'e-1'] : ['e-1']);
          // The chip goes back to what the poll holds.
          expect(chosen(tester, 'o-1'), isNull);
        });
      }
    });

    testWidgets('the poll is read on open and again after each detail read', (
      tester,
    ) async {
      final reads = <Completer<EventSnapshot>>[];
      final remote = serving(
        read: (_) {
          final read = Completer<EventSnapshot>();
          reads.add(read);
          return read.future;
        },
      );
      await show(tester, poll([date('o-1')]), remote: remote, onBack: back);

      // On the first Ready, while the open's read runs. No read can overwrite
      // a vote, so the chips don't wait for it, though the menus do.
      expect(remote.summaryRequests, ['e-1']);
      expect(chipOf(tester, 'o-1', available).onSelected, isNotNull);

      reads.single.complete(poll([date('o-1')]).snapshot);
      await settle(tester);
      expect(remote.summaryRequests, ['e-1', 'e-1']);
      expect(chipOf(tester, 'o-1', available).onSelected, isNotNull);

      // A retry's read, once it ends, failed or not.
      blocOf(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      expect(remote.summaryRequests, hasLength(2));
      reads[1].completeError(_offline);
      await settle(tester);
      expect(remote.summaryRequests, hasLength(3));

      // Not once the event has no proposed date left.
      final settled = poll([date('o-1', status: OccurrenceStatus.confirmed)]);
      cache.add(settled);
      await settle(tester);
      blocOf(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      reads[2].complete(settled.snapshot);
      await settle(tester);
      expect(remote.summaryRequests, hasLength(3));
    });

    testWidgets('a chip keeps its focus through a detail read', (tester) async {
      final reads = <Completer<EventSnapshot>>[];
      final remote = serving(
        read: (_) {
          final read = Completer<EventSnapshot>();
          reads.add(read);
          return read.future;
        },
      );
      await show(tester, poll([date('o-1')]), remote: remote, onBack: back);
      reads.single.complete(poll([date('o-1')]).snapshot);
      await settle(tester);

      await reveal(tester, answer('o-1', available));
      Focus.of(
        tester.element(
          find.descendant(
            of: answer('o-1', available),
            matching: find.text('Available'),
          ),
        ),
      ).requestFocus();
      await tester.pump();
      final focused = primaryFocus;

      blocOf(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      expect(reads, hasLength(2));
      expect(primaryFocus, same(focused));
      expect(focused?.hasPrimaryFocus, isTrue);
    });

    testWidgets('a poll read that finds the event gone reads the event, once', (
      tester,
    ) async {
      var reads = 0;
      var gone = false;
      final remote = serving(
        read: (_) {
          reads++;
          return poll([date('o-1')]).snapshot;
        },
        summary: (_) {
          if (gone) {
            throw const EventRemoteNotFoundException('gone');
          }
          return summaryOf(const []);
        },
      );
      await show(tester, poll([date('o-1')]), remote: remote, onBack: back);
      await settle(tester);
      final before = reads;
      final summaries = remote.summaryRequests.length;

      // The detail read answers, as a server that has the event but not its
      // poll would: its end reads the poll again, which is gone again, and
      // nothing more follows.
      gone = true;
      tester
          .element(find.byKey(EventDetailScreen.datesKey))
          .read<EventPollBloc>()
          .add(const EventPollRequested('e-1'));
      await settle(tester);
      await settle(tester);
      await settle(tester);

      expect(reads, before + 1);
      expect(remote.summaryRequests, hasLength(summaries + 2));
    });

    testWidgets('a poll read that finds the event gone during a read reads '
        'the event again once that one ends, once', (tester) async {
      // The running read may have been answered before the event went, and
      // the poll staying gone would start no other.
      final reads = <Completer<EventSnapshot>>[];
      final remote = serving(
        read: (_) {
          final read = Completer<EventSnapshot>();
          reads.add(read);
          return read.future;
        },
        summary: (_) => throw const EventRemoteNotFoundException('gone'),
      );
      await show(tester, poll([date('o-1')]), remote: remote, onBack: back);
      await settle(tester);
      expect(reads, hasLength(1));

      reads.single.complete(poll([date('o-1')]).snapshot);
      await settle(tester);
      expect(reads, hasLength(2));

      reads.last.complete(poll([date('o-1')]).snapshot);
      await settle(tester);
      await settle(tester);
      expect(reads, hasLength(2));
    });

    testWidgets('a refused viewer sees no change while the poll is read '
        'again', (tester) async {
      final held = Completer<AvailabilitySummary>();
      var refuse = true;
      final remote = serving(
        summary: (_) {
          if (refuse) {
            throw const EventRemoteForbiddenException('no');
          }
          return held.future;
        },
      );
      await show(
        tester,
        poll([date('o-1')]),
        remote: remote,
        onBack: back,
        onWhoAnswered: (_) {},
      );
      await settle(tester);
      final note = inDates("You can't see this poll's answers.");
      expect(note, findsOneWidget);

      refuse = false;
      tester
          .element(find.byKey(EventDetailScreen.datesKey))
          .read<EventPollBloc>()
          .add(const EventPollRequested('e-1'));
      await settle(tester);

      expect(note, findsOneWidget);
      expect(find.byKey(EventDetailScreen.whoAnsweredKey), findsNothing);

      held.completeError(const EventRemoteForbiddenException('no'));
      await settle(tester);
    });

    testWidgets('an event that is not a poll, or not on the server yet, '
        'reads none', (tester) async {
      final remote = serving();
      await show(
        tester,
        _detail(occurrences: [date('o-1')], attendance: me()),
        remote: remote,
        onBack: back,
        onWhoAnswered: (_) {},
      );
      expect(remote.detailRequests, ['e-1']);
      expect(remote.summaryRequests, isEmpty);
      expect(find.byType(ChoiceChip), findsNothing);

      // Created offline: the server has never heard of its id.
      cache.add(
        _detail(
          event: _event(schedulingMode: EventSchedulingMode.poll)
              .copyWith(isLocalOnly: true),
          occurrences: [date('o-1')],
          attendees: [me(), _member('att-2')],
          attendance: me(),
        ),
      );
      await settle(tester);
      expect(remote.summaryRequests, isEmpty);
      // So it shows no poll either: nothing to answer, and no page of
      // answers to open, though its roster can be read.
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byKey(EventDetailScreen.whoAnsweredKey), findsNothing);
    });

    testWidgets('a hidden poll says so, and a failed one offers a retry', (
      tester,
    ) async {
      Object? fails = const EventRemoteForbiddenException(
        'not yours',
        statusCode: 403,
      );
      final remote = serving(
        summary: (_) {
          if (fails case final error?) throw error;
          return summaryOf([
            tally('o-1', [voter('att-2', available)]),
          ]);
        },
      );
      await show(
        tester,
        poll([date('o-1')], attendees: [me(), _member('att-2')]),
        remote: remote,
        onBack: back,
        onWhoAnswered: (_) {},
      );

      expect(inDates(_pollHiddenCopy), findsOneWidget);
      expect(find.byKey(EventDetailScreen.pollRetryKey), findsNothing);
      // The page would show nothing either.
      expect(find.byKey(EventDetailScreen.whoAnsweredKey), findsNothing);
      expect(find.byKey(EventDetailScreen.pollTalliesKey('o-1')), findsNothing);
      // The viewer may still answer.
      expect(answer('o-1', available), findsOneWidget);

      fails = _offline;
      blocOf(tester).add(const EventDetailRetryRequested());
      await settle(tester);

      expect(inDates(_pollHiddenCopy), findsNothing);
      expect(inDates(_pollLoadFailedCopy), findsOneWidget);
      final retry = find.byKey(EventDetailScreen.pollRetryKey);
      expect(retry, findsOneWidget);
      expect(
        find.descendant(of: retry, matching: find.text('Try again')),
        findsOneWidget,
      );

      fails = null;
      final asked = remote.summaryRequests.length;
      await reveal(tester, retry);
      await tester.tap(retry);
      await settle(tester);

      expect(remote.summaryRequests, hasLength(asked + 1));
      expect(inDates(_pollLoadFailedCopy), findsNothing);
      expect(talliesOf(tester, 'o-1'), '1 available · 0 maybe · 0 unavailable');
    });

    testWidgets('a poll read the session stops shows the failed banner, '
        'with its retry', (tester) async {
      // On web, after a sign-in in another tab (#432). Nothing went out, and
      // the dates still show.
      var confirmed = false;
      final remote = serving(
        summary: (_) => summaryOf([
          tally('o-1', [voter('att-2', available)]),
        ]),
      );
      await show(
        tester,
        poll([date('o-1')], attendees: [me(), _member('att-2')]),
        remote: remote,
        onBack: back,
        confirmSession: () async => confirmed,
      );

      expect(remote.summaryRequests, isEmpty);
      expect(inDates(_pollLoadFailedCopy), findsOneWidget);
      final retry = find.byKey(EventDetailScreen.pollRetryKey);
      expect(retry, findsOneWidget);

      confirmed = true;
      await reveal(tester, retry);
      await tester.tap(retry);
      await settle(tester);

      expect(remote.summaryRequests, isNotEmpty);
      expect(inDates(_pollLoadFailedCopy), findsNothing);
      expect(talliesOf(tester, 'o-1'), '1 available · 0 maybe · 0 unavailable');
    });

    testWidgets("Enter held on the poll's retry reads once, even after the "
        'read ends', (tester) async {
      // Every read fails at once, so the key is still down when it ends.
      final remote = serving(summary: (_) => throw _offline);
      await show(
        tester,
        poll([date('o-1')], attendees: [me(), _member('att-2')]),
        remote: remote,
        onBack: back,
      );
      final retry = find.byKey(EventDetailScreen.pollRetryKey);
      await reveal(tester, retry);
      Focus.of(
        tester.element(
          find.descendant(of: retry, matching: find.byType(Text)).first,
        ),
      ).requestFocus();
      await tester.pump();
      final asked = remote.summaryRequests.length;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await settle(tester);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await settle(tester);

      expect(remote.summaryRequests, hasLength(asked + 1));
      expect(inDates(_pollLoadFailedCopy), findsOneWidget);
    });

    testWidgets("the poll's retry keeps focus, and its banner, while its read "
        'runs', (tester) async {
      Object? fails = _offline;
      final reads = <Completer<AvailabilitySummary>>[];
      final remote = serving(
        summary: (_) {
          if (fails case final error?) throw error;
          final read = Completer<AvailabilitySummary>();
          reads.add(read);
          return read.future;
        },
      );
      await show(
        tester,
        poll([date('o-1')], attendees: [me(), _member('att-2')]),
        remote: remote,
        onBack: back,
      );
      final retry = find.byKey(EventDetailScreen.pollRetryKey);
      FocusNode retryFocus() => Focus.of(
        tester.element(
          find.descendant(of: retry, matching: find.byType(Text)).first,
        ),
      );
      final banner = find.ancestor(
        of: retry,
        matching: find.byType(BgeInlineBanner),
      );
      Future<void> press() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
      }

      await reveal(tester, retry);
      retryFocus().requestFocus();
      await tester.pump();
      expect(retryFocus().hasPrimaryFocus, isTrue);
      final asked = remote.summaryRequests.length;

      // Held.
      fails = null;
      await press();

      expect(reads, hasLength(1));
      expect(retryFocus().hasPrimaryFocus, isTrue);
      expect(inDates(_pollLoadFailedCopy), findsOneWidget);
      expect(banner, findsOneWidget);
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
      expect(remote.summaryRequests, hasLength(asked + 1));

      // Failed again: the same banner, the retry offered again, focus kept.
      reads.single.completeError(_offline);
      await settle(tester);

      expect(retryFocus().hasPrimaryFocus, isTrue);
      expect(inDates(_pollLoadFailedCopy), findsOneWidget);
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

      // And read: the banner goes, with its retry.
      await press();
      expect(reads, hasLength(2));
      reads[1].complete(
        summaryOf([
          tally('o-1', [voter('att-2', available)]),
        ]),
      );
      await settle(tester);

      expect(inDates(_pollLoadFailedCopy), findsNothing);
      expect(retry, findsNothing);
      expect(talliesOf(tester, 'o-1'), '1 available · 0 maybe · 0 unavailable');
    });

    testWidgets("no who-answered button where the roster isn't visible", (
      tester,
    ) async {
      var opened = 0;
      final remote = serving();
      final whoAnswered = find.byKey(EventDetailScreen.whoAnsweredKey);
      await show(
        tester,
        poll([date('o-1')]),
        remote: remote,
        onBack: back,
        onWhoAnswered: (_) => opened++,
      );
      // Not read yet.
      expect(whoAnswered, findsNothing);

      // Withheld from this viewer.
      cache.add(poll([date('o-1')], attendees: const []));
      await settle(tester);
      expect(whoAnswered, findsNothing);

      cache.add(poll([date('o-1')], attendees: [me(), _member('att-2')]));
      await settle(tester);
      expect(
        find.descendant(of: whoAnswered, matching: find.text('Who answered')),
        findsOneWidget,
      );
      await reveal(tester, whoAnswered);
      await tester.tap(whoAnswered);
      await tester.pump();
      expect(opened, 1);

      // A screen with nowhere to open it.
      await show(
        tester,
        poll([date('o-1')], attendees: [me(), _member('att-2')]),
        remote: remote,
        onBack: back,
      );
      expect(whoAnswered, findsNothing);
    });

    testWidgets('confirm this date on the leader, with decline the others, '
        'sends the decline list', (tester) async {
      // Tied at first.
      var summary = summaryOf([
        tally('o-1', [voter('att-me', available)]),
        tally('o-2', [voter('att-me', available)]),
      ]);
      final remote = serving(
        summary: (_) => summary,
        written: (request) => date(
          request.occurrenceId!,
          status: request.call == 'confirm'
              ? OccurrenceStatus.confirmed
              : OccurrenceStatus.declined,
        ),
      );
      await show(
        tester,
        poll([
          date('o-1', label: 'Saturday'),
          date('o-2', day: 13, sortOrder: 1),
          date('o-3', day: 20, sortOrder: 2),
          // Declined already, so not again.
          date('o-4', day: 27, sortOrder: 3, status: OccurrenceStatus.declined),
        ], viewer: me(role: EventRole.host)),
        remote: remote,
        onBack: back,
      );
      // No single leader, so nothing to confirm from the poll.
      expect(leaderOf(tester, 'o-1'), 'Tied for most available');
      expect(find.text('Confirm this date'), findsNothing);

      summary = summaryOf([
        tally('o-1', [voter('att-me', available), voter('att-2', available)]),
        tally('o-2', [voter('att-me', available)]),
      ]);
      blocOf(tester).add(const EventDetailRetryRequested());
      await settle(tester);

      final confirm = find.byKey(EventDetailScreen.confirmLeaderKey('o-1'));
      expect(
        find.descendant(of: confirm, matching: find.text('Confirm this date')),
        findsOneWidget,
      );
      // On the leader alone.
      expect(
        find.byKey(EventDetailScreen.confirmLeaderKey('o-2')),
        findsNothing,
      );

      await reveal(tester, confirm);
      await tester.tap(confirm);
      await animate(tester);
      expect(find.text('Confirm Saturday?'), findsOneWidget);
      expect(find.text(_declineOthersCopy), findsOneWidget);
      await tester.tap(find.byKey(EventDetailScreen.declineOthersKey));
      await tester.pump();
      await tester.tap(find.byKey(EventDateDialogKeys.submit));
      await animate(tester);

      expect(
        remote.dateRequests.map((r) => (r.call, r.eventId, r.occurrenceId)),
        [
          ('confirm', 'e-1', 'o-1'),
          ('decline', 'e-1', 'o-2'),
          ('decline', 'e-1', 'o-3'),
        ],
      );
      expect(inOutcome('Date confirmed'), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.success);
    });

    testWidgets("a date's menu offers decline the others too, only while "
        'another date is proposed', (tester) async {
      final remote = serving(
        written: (request) {
          if (request.call == 'decline') throw _offline;
          return date(
            request.occurrenceId!,
            status: OccurrenceStatus.confirmed,
          );
        },
      );
      await show(
        tester,
        poll([
          date('o-1'),
          date('o-2', day: 13, sortOrder: 1),
        ], viewer: me(role: EventRole.host)),
        remote: remote,
        onBack: back,
      );

      Future<void> confirmFromMenu(String id) async {
        await tester.tap(find.byKey(EventDetailScreen.dateMenuKey(id)));
        await animate(tester);
        await tester.tap(
          find.byKey(
            EventDetailScreen.dateActionKey(id, EventAction.confirmDate),
          ),
        );
        await animate(tester);
      }

      await confirmFromMenu('o-2');
      await tester.tap(find.byKey(EventDetailScreen.declineOthersKey));
      await tester.pump();
      await tester.tap(find.byKey(EventDateDialogKeys.submit));
      await animate(tester);

      expect(remote.dateRequests.map((r) => (r.call, r.occurrenceId)), [
        ('confirm', 'o-2'),
        ('decline', 'o-1'),
      ]);
      // The confirm went through, and a decline may not have.
      expect(inOutcome(_confirmedNotAllDeclinedCopy), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.warning);

      // No other proposed date: nothing to offer.
      cache.add(
        poll([
          date('o-1'),
          date(
            'o-2',
            day: 13,
            sortOrder: 1,
            status: OccurrenceStatus.confirmed,
          ),
        ], viewer: me(role: EventRole.host)),
      );
      await settle(tester);
      await confirmFromMenu('o-1');
      expect(find.text('Confirm Fri, Nov 6 · 7:00 PM?'), findsOneWidget);
      expect(find.byKey(EventDetailScreen.declineOthersKey), findsNothing);
    });

    testWidgets('the chips wrap and stay tappable at 320dp and 2.0 text', (
      tester,
    ) async {
      useViewSize(tester, window.size);
      final remote = serving();
      await show(
        tester,
        poll([date('o-1', label: longLabel)]),
        remote: remote,
        onBack: back,
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );
      expect(tester.takeException(), isNull);

      // Not all three on one row.
      await reveal(tester, answer('o-1', maybe));
      final rows = {
        for (final response in responses)
          tester.getTopLeft(answer('o-1', response)).dy,
      };
      expect(rows.length, greaterThan(1));

      for (final response in responses) {
        await expectReachable(
          tester,
          answer('o-1', response),
          reason: response.name,
        );
        // Drawn whole, scaled down where it has to be: a chip cuts a label
        // it can't fit, and nothing overflows to say so.
        final label = find.descendant(
          of: answer('o-1', response),
          matching: find.byType(RichText),
        );
        final paragraph = tester.renderObject<RenderParagraph>(label);
        expect(
          paragraph.size.width,
          greaterThanOrEqualTo(paragraph.getMaxIntrinsicWidth(double.infinity)),
          reason: response.name,
        );
        final drawn = tester.getRect(label);
        final chip = tester.getRect(answer('o-1', response)).inflate(0.5);
        expect(
          chip.contains(drawn.topLeft) && chip.contains(drawn.bottomRight),
          isTrue,
          reason: '${response.name}: $drawn in $chip',
        );
      }

      await tapAnswer(tester, 'o-1', unavailable);
      expect(remote.voteRequests.map((r) => r.response), [unavailable]);
      expect(chosen(tester, 'o-1'), unavailable);
      expect(tester.takeException(), isNull);
    });

    testWidgets("the poll's notes and buttons fit at 320dp and 2.0 text", (
      tester,
    ) async {
      useViewSize(tester, window.size);
      Object? fails;
      Completer<AvailabilitySummary>? held;
      final remote = serving(
        summary: (_) {
          if (fails case final error?) throw error;
          if (held case final read?) return read.future;
          return summaryOf([
            tally('o-1', [voter('att-2', available)]),
          ]);
        },
      );
      final host = me(
        role: EventRole.host,
        status: EventParticipationStatus.notAttending,
      );
      await show(
        tester,
        poll(
          [date('o-1', label: longLabel), date('o-2', day: 13, sortOrder: 1)],
          viewer: host,
          attendees: [host, _member('att-2'), _member('att-3')],
        ),
        remote: remote,
        onBack: back,
        onWhoAnswered: (_) {},
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );

      expect(tester.takeException(), isNull);
      expect(inDates(_pollNotCountingCopy), findsOneWidget);
      expect(inDates("1 person hasn't answered"), findsOneWidget);
      for (final key in [
        EventDetailScreen.whoAnsweredKey,
        EventDetailScreen.confirmLeaderKey('o-1'),
      ]) {
        await expectReachable(tester, find.byKey(key), reason: '$key');
      }

      fails = _offline;
      blocOf(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      expect(inDates(_pollLoadFailedCopy), findsOneWidget);
      final retry = find.byKey(EventDetailScreen.pollRetryKey);
      await expectReachable(tester, retry);
      expect(tester.takeException(), isNull);

      // Under way, with the longer label.
      fails = null;
      held = Completer();
      await tester.tap(retry);
      await settle(tester);
      expect(
        find.descendant(of: retry, matching: find.text(_inProgressCopy)),
        findsOneWidget,
      );
      await expectReachable(tester, retry);
      expect(tester.takeException(), isNull);
    });
  });

  group('offline (#49)', () {
    const available = AvailabilityResponse.available;
    const maybe = AvailabilityResponse.maybe;
    const unavailable = AvailabilityResponse.unavailable;
    late ValueNotifier<bool> offline;

    setUpAll(() {
      registerFallbackValue(confirmed('o-fallback', kItemInstant));
    });

    setUp(() {
      offline = ValueNotifier(true);
      when(() => repository.cacheOccurrence(any()))
          .thenAnswer((_) async => true);
    });

    tearDown(() => offline.dispose());

    EventOccurrence date(String id, {int day = 6, int sortOrder = 0}) =>
        confirmed(
          id,
          DateTime(2026, 11, day, 19),
          sortOrder: sortOrder,
        ).copyWith(eventId: 'e-1', status: OccurrenceStatus.proposed);

    /// A poll the viewer hosts, with two proposed dates, the first leading
    /// alone.
    Future<void> showPoll(WidgetTester tester) async {
      await show(
        tester,
        _detail(
          event: _event(schedulingMode: EventSchedulingMode.poll),
          occurrences: [
            date('o-1'),
            date('o-2', day: 13, sortOrder: 1),
            date(
              'o-3',
              day: 20,
              sortOrder: 2,
            ).copyWith(status: OccurrenceStatus.confirmed),
          ],
          attendance: _attending(EventRole.host),
        ),
        remote: FakeEventRemote.detail(
          (_) => _detail().snapshot,
          summary: (_) => AvailabilitySummary(
            occurrences: [
              OccurrenceAvailability(
                occurrenceId: 'o-1',
                available: 1,
                maybe: 0,
                unavailable: 0,
                voters: const [
                  AvailabilityVoter(
                    attendeeId: 'att-2',
                    response: available,
                    eligible: true,
                  ),
                ],
              ),
            ],
          ),
        ),
        onBack: (_) {},
        offline: offline,
      );
      await settle(tester);
    }

    Finder reason() => find.text(_onlineOnlyCopy, skipOffstage: false);

    /// What a screen reader gets for a gated button or chip: its own state,
    /// not enabled, with the reason as its hint.
    Matcher gatedButton(String label) => matchesSemantics(
      label: label,
      hint: _onlineOnlyCopy,
      isButton: true,
      hasEnabledState: true,
    );

    Matcher gatedChip(String label) => matchesSemantics(
      label: label,
      hint: _onlineOnlyCopy,
      isButton: true,
      hasSelectedState: true,
      hasEnabledState: true,
    );

    /// A menu item's one node: both lines in its label, not enabled, no
    /// actions.
    Matcher gatedItem(String label) => matchesSemantics(
      label: '$label\n$_onlineOnlyCopy',
      hasEnabledState: true,
    );

    Future<void> openDateMenu(WidgetTester tester, String id) async {
      await tester.ensureVisible(find.byKey(EventDetailScreen.dateMenuKey(id)));
      await tester.tap(find.byKey(EventDetailScreen.dateMenuKey(id)));
      await animate(tester);
    }

    testWidgets("the poll's controls are disabled and say why", (tester) async {
      await showPoll(tester);

      final add = find.byKey(EventDetailScreen.addDateKey);
      final confirm = find.byKey(EventDetailScreen.confirmLeaderKey('o-1'));
      for (final (control, label) in [
        (add, 'Add a date'),
        (confirm, 'Confirm this date, Fri, Nov 6 \u{b7} 7:00 PM'),
      ]) {
        await tester.ensureVisible(control);
        await tester.pump();
        expect(tester.widget<ButtonStyleButton>(control).onPressed, isNull);
        expect(tester.getSemantics(control), gatedButton(label));
      }
      for (final (id, starts) in [
        ('o-1', 'Fri, Nov 6 \u{b7} 7:00 PM'),
        ('o-2', 'Fri, Nov 13 \u{b7} 7:00 PM'),
      ]) {
        for (final (response, answer) in [
          (available, 'Available'),
          (maybe, 'Maybe'),
          (unavailable, 'Unavailable'),
        ]) {
          final chip = find.byKey(
            EventDetailScreen.pollAnswerKey(id, response),
          );
          await tester.ensureVisible(chip);
          await tester.pump();
          expect(tester.widget<ChoiceChip>(chip).onSelected, isNull);
          expect(tester.getSemantics(chip), gatedChip('$answer for $starts'));
        }
      }
      // Once under Add a date, once under Confirm this date, and once under
      // each date's three chips, not once a chip.
      expect(reason(), findsNWidgets(4));

      offline.value = false;
      await tester.pump();

      expect(reason(), findsNothing);
      expect(tester.widget<ButtonStyleButton>(add).onPressed, isNotNull);
      expect(tester.widget<ButtonStyleButton>(confirm).onPressed, isNotNull);
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(EventDetailScreen.pollAnswerKey('o-1', maybe)),
            )
            .onSelected,
        isNotNull,
      );
    });

    testWidgets("a date's menu opens, and its items say why they can't be "
        'pressed', (tester) async {
      await showPoll(tester);

      await openDateMenu(tester, 'o-1');

      // A proposed date's items, then a confirmed date's, which is the one
      // offering Cancel.
      for (final (id, items) in [
        (
          'o-1',
          [
            (EventAction.confirmDate, 'Confirm'),
            (EventAction.editDate, 'Edit'),
            (EventAction.declineDate, 'Decline'),
            (EventAction.removeDate, 'Remove'),
          ],
        ),
        (
          'o-3',
          [
            (EventAction.editDate, 'Edit'),
            (EventAction.cancelDate, 'Cancel date'),
            (EventAction.removeDate, 'Remove'),
          ],
        ),
      ]) {
        if (id == 'o-3') {
          await openDateMenu(tester, 'o-1');
          await openDateMenu(tester, id);
        }
        for (final (action, label) in items) {
          final item = find.byKey(EventDetailScreen.dateActionKey(id, action));
          expect(item, findsOneWidget, reason: '$id $label');
          expect(tester.widget<MenuItemButton>(item).onPressed, isNull);
          expect(
            tester.getSemantics(item),
            gatedItem(label),
            reason: '$id $label',
          );
        }
        expect(find.byType(MenuItemButton), findsNWidgets(items.length));
      }
      // The anchor stays enabled, so the menu could be opened to read this.
      expect(
        tester
            .widget<IconButton>(
              find.byKey(EventDetailScreen.dateMenuKey('o-1')),
            )
            .onPressed,
        isNotNull,
      );

      offline.value = false;
      await tester.pump();

      expect(reason(), findsNothing);
      for (final action in [
        EventAction.editDate,
        EventAction.cancelDate,
        EventAction.removeDate,
      ]) {
        expect(
          tester
              .widget<MenuItemButton>(
                find.byKey(EventDetailScreen.dateActionKey('o-3', action)),
              )
              .onPressed,
          isNotNull,
        );
      }
    });

    testWidgets('online, the chips sit one 4dp step above the tallies, as '
        'before the offline note', (tester) async {
      offline.value = false;
      await showPoll(tester);

      final chip = find.byKey(
        EventDetailScreen.pollAnswerKey('o-1', unavailable),
      );
      final tallies = find.byKey(EventDetailScreen.pollTalliesKey('o-1'));
      await tester.ensureVisible(tallies);
      await tester.pump();

      expect(tester.getTopLeft(tallies).dy - tester.getRect(chip).bottom, 4.0);
    });

    testWidgets('Delete is disabled and says why', (tester) async {
      await show(
        tester,
        _detail(attendance: _attending(EventRole.host)),
        remote: FakeEventRemote.detail((_) => _detail().snapshot),
        onBack: (_) {},
        offline: offline,
      );

      await tester.tap(find.byKey(EventDetailScreen.moreActionsKey));
      await animate(tester);

      final delete = find.byKey(EventDetailScreen.deleteKey);
      expect(tester.widget<MenuItemButton>(delete).onPressed, isNull);
      expect(tester.getSemantics(delete), gatedItem('Delete event'));
      expect(
        tester
            .widget<IconButton>(find.byKey(EventDetailScreen.moreActionsKey))
            .onPressed,
        isNotNull,
      );

      offline.value = false;
      await tester.pump();

      expect(tester.widget<MenuItemButton>(delete).onPressed, isNotNull);
      expect(reason(), findsNothing);
    });

    testWidgets('going offline with Delete focused leaves focus recoverable', (
      tester,
    ) async {
      offline.value = false;
      await show(
        tester,
        _detail(attendance: _attending(EventRole.host)),
        remote: FakeEventRemote.detail((_) => _detail().snapshot),
        onBack: (_) {},
        offline: offline,
      );
      await tester.tap(find.byKey(EventDetailScreen.moreActionsKey));
      await animate(tester);
      Focus.of(tester.element(find.text('Delete event'))).requestFocus();
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;
      expect(
        focused,
        Focus.of(tester.element(find.text('Delete event'))),
        reason: 'Delete holds focus before the connection drops',
      );
      expect(focused!.hasPrimaryFocus, isTrue);

      // The menu has nothing left to press, so it closes, and focus falls to
      // the page.
      offline.value = true;
      await animate(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(EventDetailScreen.deleteKey), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      final now = FocusManager.instance.primaryFocus;
      expect(tester.takeException(), isNull);
      expect(now, isNotNull);
      expect(now, isNot(focused));
      expect(now, isNot(isA<FocusScopeNode>()));
      expect(now!.context, isNotNull);
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
          // Started before the clock and ending long after it, so the event
          // reads Happening now by its dates (#502), with the long end.
          confirmed(
            'o-1',
            DateTime(2026, 10, 23, 17),
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
