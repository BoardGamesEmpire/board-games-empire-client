import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/event_date_dialogs.dart';
import 'package:flutter/material.dart';
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
    'This date changed meanwhile. Here it is as it stands now.';
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
/// shares with the overview. Then Delete (#501), from the menu to the screen
/// leaving, and the dates' menus and dialogs (#506).
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
    Future<bool> Function()? confirmSession,
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
      householdRole: householdRole,
      onBack: onBack,
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
    Future<bool> Function()? confirmSession,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    await tester.pumpWidget(
      harness(
        remote: remote,
        households: households,
        householdRole: householdRole,
        onBack: onBack,
        confirmSession: confirmSession,
        textScaler: textScaler,
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

    testWidgets("a household admin who doesn't host gets no menu", (
      tester,
    ) async {
      // An owner or admin deletes only an event they host.
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

      expect(find.byKey(EventDetailScreen.moreActionsKey), findsNothing);
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
          [for (final item in shown) (item.child! as Text).data],
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
