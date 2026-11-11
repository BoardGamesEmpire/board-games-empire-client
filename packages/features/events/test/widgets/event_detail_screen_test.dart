import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/event_date_dialogs.dart';
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
    "Something went wrong. Check the event's status before trying again.";
const _rsvpNotGoingBodyCopy =
    "Nominations of games you're bringing will be paused, and those games "
    'will come off every date still to come. Your votes stop counting. '
    "Saying you're coming later brings the nominations back, but not the "
    'games.';
const _rsvpSavedCopy = 'Your answer is saved.';
const _rsvpGoneCopy = "You're no longer on this event, or it was deleted.";
const _rsvpRefusedCopy = "You can't answer for this event any more.";
const _rsvpChangedCopy =
    'This event changed before your answer went through. Check it below '
    'before trying again.';
const _rsvpFailedCopy =
    'An error occurred while sending your answer. You may need to try again.';
const _rsvpFailedUnexpectedCopy =
    'Something went wrong. Check your answer below before trying again.';
const _removeAdaBodyCopy =
    'Nominations of games Ada is bringing will be paused, and those games '
    'will come off every date still to come. Their votes stop counting. '
    'Adding them back brings the nominations back, but not the games.';
const _notGoingForAdaBodyCopy =
    'Nominations of games Ada is bringing will be paused, and those games '
    'will come off every date still to come. Their votes stop counting. '
    'Changing the answer back brings the nominations back, but not the games.';
const _rosterChangedCopy =
    'The roster changed before that went through. Check it below before '
    'trying again.';
const _attendeeWriteFailedCopy =
    "Couldn't reach the server. Check the roster below before trying again.";
const _attendeeWriteFailedUnexpectedCopy =
    'Something went wrong. Check the roster below before trying again.';

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
/// header, the dates and who's coming, the Details and Games tabs (#516), and
/// the refresh banner it shares with the overview. Then Delete (#501), from
/// the menu to the screen leaving, the event's status writes (#502), the
/// dates' menus and dialogs (#506), the poll on the dates (#507), the
/// viewer's own answer (#508), and the page moving on with the clock (#502,
/// #655).
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
    Future<EventAttendeeAddition?> Function(
      BuildContext context,
      AddAttendeeArgs args,
    )?
    onAddAttendee,
    Future<bool> Function()? confirmSession,
    TextScaler? textScaler,
    ValueListenable<bool>? offline,
    DateTime Function()? clock,
    ThemeData? theme,
  }) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    locale: const Locale('en', 'US'),
    localizationsDelegates: EventsLocalizations.localizationsDelegates,
    supportedLocales: EventsLocalizations.supportedLocales,
    builder: (context, child) {
      // No override unless a test sets one, so an audit cell's own scale
      // reaches the screen (#767).
      final app = textScaler == null
          ? child!
          : MediaQuery(
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
      onAddAttendee: onAddAttendee,
      confirmSession: confirmSession,
      now: clock ?? () => now,
    ),
  );

  /// Lets the cache's answer reach the bloc, and its state the screen.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  /// Shows [detail] as the cache's answer. No server, unless [remote] says,
  /// and no way back, unless [onBack] does. The clock stands at `now`,
  /// unless [clock] says otherwise.
  Future<void> show(
    WidgetTester tester,
    EventDetail detail, {
    EventRemoteDataSource? remote,
    Stream<List<Household>>? households,
    Future<HouseholdRole?> Function(String householdId)? householdRole,
    void Function(BuildContext context)? onBack,
    void Function(BuildContext context)? onWhoAnswered,
    Future<EventAttendeeAddition?> Function(
      BuildContext context,
      AddAttendeeArgs args,
    )?
    onAddAttendee,
    Future<bool> Function()? confirmSession,
    TextScaler? textScaler,
    ValueListenable<bool>? offline,
    DateTime Function()? clock,
  }) async {
    await tester.pumpWidget(
      harness(
        remote: remote,
        households: households,
        householdRole: householdRole,
        onBack: onBack,
        onWhoAnswered: onWhoAnswered,
        onAddAttendee: onAddAttendee,
        confirmSession: confirmSession,
        textScaler: textScaler,
        offline: offline,
        clock: clock,
      ),
    );
    cache.add(detail);
    await settle(tester);
  }

  /// Answers each read from the completer it adds to [reads], so a test
  /// decides when, and how, each one ends. Deletes answer from [deleted],
  /// and succeed without one. The games pool is empty (#516).
  FakeEventRemote scripted(
    List<Completer<EventSnapshot>> reads, {
    FutureOr<void> Function(String id)? deleted,
  }) => FakeEventRemote.detail(
    (_) {
      final read = Completer<EventSnapshot>();
      reads.add(read);
      return read.future;
    },
    deleted: deleted ?? (_) {},
    pool: (_) => const [],
  );

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

  // The banners sit in the page's header (#516), which is built and in the
  // semantics tree wherever the page is scrolled, but which `find` counts as
  // offstage until the banner's reveal has scrolled it into view. So the
  // banners' finders look past that, and a test that needs the banner heard
  // before then says so with [liveRegionSaying].
  Finder outcome() =>
      find.byKey(EventDetailScreen.actionOutcomeKey, skipOffstage: false);

  Finder inOutcome(String text) => find.descendant(
    of: outcome(),
    matching: find.text(text, skipOffstage: false),
    skipOffstage: false,
  );

  /// The live region saying [text], found in the semantics tree: what a
  /// screen reader hears, whether or not the banner is on screen yet.
  SemanticsFinder liveRegionSaying(String text) =>
      find.semantics.byPredicate((node) {
        final data = node.getSemanticsData();
        return data.flagsCollection.isLiveRegion && data.label.contains(text);
      }, describeMatch: (_) => 'a live region saying "$text"');

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

    testWidgets('the link is at least a tap target tall', (tester) async {
      // A long press selects it, and a short link is a single line (#50).
      // Measured on the link's own node, so another target on the page
      // can't fail it.
      await show(tester, _detail(event: _event(url: 'https://bge.app')));

      final link = tester.getSemantics(find.byType(SelectableText));
      expect(
        link.getSemanticsData().hasAction(SemanticsAction.longPress),
        isTrue,
      );
      expect(link.rect.height, greaterThanOrEqualTo(kMinInteractiveDimension));
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

  testWidgets('section headings are headings', (tester) async {
    await show(tester, _detail());

    for (final heading in ['Dates', "Who's coming"]) {
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
      for (final text in ['Catan night', 'Dates', "Who's coming"])
        tester.getTopLeft(find.text(text)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(tops.toSet(), hasLength(3));
  });

  group('tabs (#516)', () {
    const details = EventDetailTab.details;
    const games = EventDetailTab.games;
    const notYetCopy = "This event's games will show here.";

    Finder bar() => find.byKey(EventDetailScreen.tabBarKey);
    Finder tab(EventDetailTab which) =>
        find.byKey(EventDetailScreen.tabKey(which));
    // A sliver group (#516), which a finder that skips what isn't on screen
    // would pass over.
    Finder gamesBody() =>
        find.byKey(EventDetailScreen.gamesBodyKey, skipOffstage: false);
    Finder dates() => find.byKey(EventDetailScreen.datesKey);
    Finder roster() => find.byKey(EventDetailScreen.attendeesKey);

    /// The page's one scroll view, whose count a screen reader reads.
    CustomScrollView scrollView(WidgetTester tester) =>
        tester.widget<CustomScrollView>(find.byType(CustomScrollView));

    /// The host's view of `e-1`, with a date ahead and someone on the
    /// roster.
    EventDetail hosted() => _detail(
      occurrences: [_ahead()],
      attendees: [
        _attending(EventRole.host),
        _member('att-2', displayName: 'Ada'),
      ],
      attendance: _attending(EventRole.host),
    );

    /// A server whose reads serve [detail], whose deletes answer from
    /// [deleted], and whose games pool is empty: the Games tab's own suite
    /// covers what it shows.
    FakeEventRemote serving(
      EventDetail detail, {
      FutureOr<void> Function(String id)? deleted,
    }) => FakeEventRemote.detail(
      (_) => detail.snapshot,
      deleted: deleted ?? (_) {},
      pool: (_) => const [],
    );

    /// Shows [detail] with a server and a way back, as the app opens it, and
    /// lets the read it starts end.
    Future<void> showTabbed(
      WidgetTester tester,
      EventDetail detail, {
      EventRemoteDataSource? remote,
      DateTime Function()? clock,
    }) async {
      await show(
        tester,
        detail,
        remote: remote ?? serving(detail),
        onBack: (_) {},
        clock: clock,
      );
      await settle(tester);
    }

    Future<void> choose(WidgetTester tester, EventDetailTab which) async {
      await tester.tap(tab(which));
      await animate(tester);
    }

    void expectDetails() {
      expect(find.text('Catan night'), findsOneWidget);
      expect(dates(), findsOneWidget);
      expect(roster(), findsOneWidget);
      expect(gamesBody(), findsNothing);
    }

    void expectGames() {
      expect(gamesBody(), findsOneWidget);
      expect(dates(), findsNothing);
      expect(roster(), findsNothing);
    }

    /// [banner] is on screen, and wholly above the bar.
    void expectAboveBar(WidgetTester tester, Finder banner) {
      expect(banner, findsOneWidget);
      expect(
        tester.getRect(banner).bottom,
        lessThanOrEqualTo(tester.getRect(bar()).top),
      );
    }

    testWidgets('the screen opens on Details, with a Games tab beside it', (
      tester,
    ) async {
      await showTabbed(tester, hosted());

      expect(bar(), findsOneWidget);
      expect(
        find.descendant(of: tab(details), matching: find.text('Details')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tab(games), matching: find.text('Games')),
        findsOneWidget,
      );
      // One row: Details first, Games after it.
      expect(
        tester.getCenter(tab(games)).dy,
        tester.getCenter(tab(details)).dy,
      );
      expect(
        tester.getCenter(tab(games)).dx,
        greaterThan(tester.getCenter(tab(details)).dx),
      );
      expectDetails();
      // The bar heads the event, title included.
      expect(
        tester.getRect(bar()).bottom,
        lessThanOrEqualTo(tester.getTopLeft(find.text('Catan night')).dy),
      );
      expect(scrollView(tester).semanticChildCount, isNull);
    });

    testWidgets('with no remote there is no tab bar', (tester) async {
      await show(tester, hosted(), onBack: (_) {});

      expect(bar(), findsNothing);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text('Details'), findsNothing);
      expect(find.text('Games'), findsNothing);
      expectDetails();
    });

    testWidgets('an event made offline has no tab bar', (tester) async {
      final detail = hosted();
      await showTabbed(
        tester,
        _detail(
          event: _event().copyWith(isLocalOnly: true),
          occurrences: detail.snapshot.occurrences,
          attendees: detail.snapshot.attendees,
          attendance: detail.attendance,
        ),
      );

      expect(bar(), findsNothing);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text('Details'), findsNothing);
      expect(find.text('Games'), findsNothing);
      expectDetails();
    });

    testWidgets(
      'choosing Games shows the games tab and hides the dates and the roster',
      (tester) async {
        await showTabbed(tester, hosted());

        await choose(tester, games);

        expectGames();
        expect(bar(), findsOneWidget);
        // An empty pool holds no rows (#516).
        expect(scrollView(tester).semanticChildCount, 0);
      },
    );

    testWidgets('choosing Details again shows the dates and the roster', (
      tester,
    ) async {
      await showTabbed(tester, hosted());
      await choose(tester, games);

      await choose(tester, details);

      expectDetails();
      expect(scrollView(tester).semanticChildCount, isNull);
    });

    testWidgets('a failed refresh shows above the tabs on both', (
      tester,
    ) async {
      final reads = <Completer<EventSnapshot>>[];
      await show(tester, hosted(), remote: scripted(reads), onBack: (_) {});
      reads.single.completeError(_offline);
      await settle(tester);

      final banner = find.byKey(EventDetailScreen.refreshBannerKey);
      expectAboveBar(tester, banner);
      expectDetails();

      await choose(tester, games);

      expectAboveBar(tester, banner);
      expectGames();
    });

    testWidgets('an outcome banner shows above the tabs on both', (
      tester,
    ) async {
      final detail = hosted();
      await showTabbed(
        tester,
        detail,
        remote: serving(
          detail,
          deleted: (_) =>
              throw const EventWriteRefusedException('no', statusCode: 403),
        ),
      );

      tester
          .element(bar())
          .read<EventActionsBloc>()
          .add(const EventDeleteRequested('e-1'));
      await animate(tester);

      expect(inOutcome(_refusedCopy), findsOneWidget);
      expectAboveBar(tester, outcome());
      expectDetails();

      await choose(tester, games);

      expect(inOutcome(_refusedCopy), findsOneWidget);
      expectAboveBar(tester, outcome());
      expectGames();
    });

    testWidgets('under reduced motion the tabs switch at once, and turning it '
        'on keeps the chosen tab', (tester) async {
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await showTabbed(tester, hosted());
      TabController tabs() => DefaultTabController.of(tester.element(bar()));
      expect(tabs().animationDuration, isNot(Duration.zero));
      await choose(tester, games);

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pump();

      expectGames();
      expect(tabs().index, games.index);
      expect(tabs().animationDuration, Duration.zero);

      // One frame, with no time passing: the indicator is already there.
      await tester.tap(tab(details));
      await tester.pump();
      expectDetails();
      expect(tabs().indexIsChanging, isFalse);
      expect(tabs().animation!.value, details.index);
    });

    testWidgets('an outcome is heard as it lands, however far down the page '
        'is', (tester) async {
      // A long roster at 320dp, scrolled to its end: the banners are many
      // viewports above, past what a scroll view keeps built for a screen
      // reader. They sit in the page's header, which it keeps all the same.
      useViewSize(tester, const Size(320, 480));
      final long = _detail(
        occurrences: [_ahead()],
        attendees: [
          _attending(EventRole.host),
          for (var i = 0; i < 30; i++)
            _member('att-x$i', displayName: 'Person $i'),
        ],
        attendance: _attending(EventRole.host),
      );
      await showTabbed(
        tester,
        long,
        remote: serving(
          long,
          deleted: (_) =>
              throw const EventWriteRefusedException('no', statusCode: 403),
        ),
      );
      final page = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      page.jumpTo(page.maxScrollExtent);
      await tester.pump();
      expect(page.pixels, greaterThan(2000));

      // From the scaffold: the bar is scrolled out of view.
      tester
          .element(find.byType(Scaffold).first)
          .read<EventActionsBloc>()
          .add(const EventDeleteRequested('e-1'));
      // The answer, and frames, but no time for the reveal to move the page.
      await settle(tester);
      await settle(tester);

      expect(page.pixels, greaterThan(2000));
      expect(liveRegionSaying(_refusedCopy), findsOne);

      // And it still comes into view.
      await tester.pumpAndSettle();
      expect(find.byKey(EventDetailScreen.actionOutcomeKey), findsOneWidget);
    });

    testWidgets('the chosen tab survives a refresh and a write', (
      tester,
    ) async {
      final detail = hosted();
      await showTabbed(
        tester,
        detail,
        remote: serving(
          detail,
          deleted: (_) =>
              throw const EventWriteRefusedException('no', statusCode: 403),
        ),
      );
      await choose(tester, games);

      // A read the user asks for, and the cache's answer to it.
      blocOf(tester).add(const EventDetailRetryRequested());
      await settle(tester);
      cache.add(hosted());
      await settle(tester);
      expectGames();

      // A write, its outcome, and the read that outcome starts.
      tester
          .element(bar())
          .read<EventActionsBloc>()
          .add(const EventDeleteRequested('e-1'));
      await animate(tester);
      expect(inOutcome(_refusedCopy), findsOneWidget);
      expectGames();
    });

    testWidgets('the chosen tab survives the clock moving the page on', (
      tester,
    ) async {
      // The date starts a minute after the clock, which builds the page
      // again then (#502).
      var clock = now;
      final starting = _detail(
        occurrences: [
          confirmed(
            'o-1',
            now.add(const Duration(minutes: 1)),
          ).copyWith(eventId: 'e-1'),
        ],
        attendance: _attending(EventRole.host),
      );
      await showTabbed(tester, starting, clock: () => clock);
      await choose(tester, games);

      clock = clock.add(const Duration(minutes: 2));
      await tester.pump(const Duration(minutes: 2));
      await tester.pump();

      expectGames();
    });

    testWidgets('the tabs say their role, which is selected, and their place', (
      tester,
    ) async {
      // Disposed in the body: the framework checks for live handles before
      // teardowns run.
      final handle = tester.ensureSemantics();
      await showTabbed(tester, hosted());

      final tabs = find.semantics.byPredicate(
        (node) => node.role == SemanticsRole.tab,
      );
      expect(tabs, findsNWidgets(2));
      expect(
        tabs.evaluate().where(
          (node) =>
              node.getSemanticsData().flagsCollection.isSelected ==
              Tristate.isTrue,
        ),
        hasLength(1),
      );

      SemanticsData dataOf(EventDetailTab which) =>
          tester.getSemantics(tab(which)).getSemanticsData();

      expect(dataOf(details).role, SemanticsRole.tab);
      expect(dataOf(details).label, contains('Details'));
      expect(dataOf(details).label, contains('Tab 1 of 2'));
      expect(dataOf(games).role, SemanticsRole.tab);
      expect(dataOf(games).label, contains('Games'));
      expect(dataOf(games).label, contains('Tab 2 of 2'));
      expect(tester.getSemantics(tab(details)), isSemantics(isSelected: true));
      expect(tester.getSemantics(tab(games)), isSemantics(isSelected: false));

      await choose(tester, games);

      expect(tester.getSemantics(tab(details)), isSemantics(isSelected: false));
      expect(tester.getSemantics(tab(games)), isSemantics(isSelected: true));
      handle.dispose();
    });

    testWidgets('Details no longer says games will show here', (tester) async {
      await showTabbed(tester, hosted());

      expect(find.text(notYetCopy), findsNothing);
      // The tab is the only Games on the page.
      expect(find.text('Games'), findsOneWidget);
      expect(
        find.descendant(of: bar(), matching: find.text('Games')),
        findsOneWidget,
      );

      // Nor where there are no tabs.
      await tester.pumpWidget(const SizedBox());
      await show(tester, hosted());
      expect(find.text(notYetCopy), findsNothing);
      expect(find.text('Games'), findsNothing);
    });
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

      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Above')),
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
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Above')),
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
      // The server's cancel calls off the event's Confirmed dates with it,
      // and only the read after it serves them.
      final remote = FakeEventRemote.detail(
        (_) {
          final snapshot = cached.snapshot;
          final event = snapshot.event;
          if (event.status != EventStatus.cancelled) return snapshot;
          return snapshot.copyWith(
            occurrences: [
              for (final o in snapshot.occurrences)
                if (o.status == OccurrenceStatus.confirmed)
                  o.copyWith(
                    status: OccurrenceStatus.cancelled,
                    cancelledAt: event.cancelledAt,
                    cancelReason: event.cancelReason,
                  )
                else
                  o,
            ],
          );
        },
        deleted: (_) {},
        statusWritten: answer,
      );
      // And the read's copy reaches the screen through the cache, as the
      // repository's watch delivers it.
      when(
        () => repository.cacheEvent(any(), source: any(named: 'source')),
      ).thenAnswer((invocation) async {
        final snapshot = invocation.positionalArguments.single as EventSnapshot;
        cached = EventDetail(snapshot: snapshot, attendance: cached.attendance);
        cache.add(cached);
      });
      await showStatus(tester, viewed(EventStatus.scheduled), remote: remote);
      expect(
        inSection(EventDetailScreen.datesKey, 'Confirmed'),
        findsOneWidget,
      );
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
      const reason = 'Reason: The venue flooded.';
      expect(
        inSection(EventDetailScreen.datesKey, 'Cancelled'),
        findsOneWidget,
      );
      expect(inSection(EventDetailScreen.datesKey, 'Confirmed'), findsNothing);
      // Once for the event, and once for the date it called off.
      expect(find.text(reason), findsNWidgets(2));
      expect(inSection(EventDetailScreen.datesKey, reason), findsOneWidget);
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
          thrown: const EventRemoteNotFoundException(
            'gone',
          ) as EventRemoteException,
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
        (
          // A 2xx whose body didn't parse: the write may have landed, so
          // the copy doesn't say it didn't, and the read shows the status.
          name: 'an answer it could not read',
          thrown: const EventRemotePermanentException(
            'unreadable',
            statusCode: 200,
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
      // The tab bar above the event (#516) can leave the last date's menu
      // below the test's view.
      await tester.ensureVisible(menuOf(id));
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
          thrown: null as EventRemoteException?,
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
          thrown: const EventRemoteNotFoundException(
            'gone',
          ) as EventRemoteException?,
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
          thrown: const EventRemoteNotFoundException(
            'gone',
          ) as EventRemoteException?,
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
          'its dialog was open, and the banner says so', (tester) async {
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
        expect(inOutcome(_dateChangedCopy), findsOneWidget);
      });
    }

    for (final action in [
      EventAction.confirmDate,
      EventAction.declineDate,
      EventAction.cancelDate,
    ]) {
      testWidgets('${action.name} is not sent for a host made an organizer '
          'while its dialog was open, and the banner says so', (tester) async {
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
        expect(inOutcome(_dateChangedCopy), findsOneWidget);
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

    // Past offstage, as the actions' banner's finders are: see [outcome].
    Finder pollOutcome() =>
        find.byKey(EventDetailScreen.pollOutcomeKey, skipOffstage: false);

    Finder inPollOutcome(String text) => find.descendant(
      of: pollOutcome(),
      matching: find.text(text, skipOffstage: false),
      skipOffstage: false,
    );

    BgeBannerTone pollToneOf(WidgetTester tester) =>
        tester.widget<BgeInlineBanner>(pollOutcome()).tone;

    Finder inDates(String text) => inSection(EventDetailScreen.datesKey, text);

    /// The dates' answer chips: who's coming has the viewer's own (#508).
    Finder chipsInDates() => find.descendant(
      of: find.byKey(EventDetailScreen.datesKey),
      matching: find.byType(ChoiceChip),
    );

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
      expect(chipsInDates(), findsNothing);
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
      // Heard as it lands, before its reveal has brought it on screen.
      expect(liveRegionSaying(_pollChangedCopy), findsOne);
      expect(pollToneOf(tester), BgeBannerTone.warning);
      // The vote's banner, not the actions'.
      expect(outcome(), findsNothing);
      expect(remote.detailRequests, ['e-1', 'e-1']);
      expect(inDates('Confirmed'), findsOneWidget);
      expect(answer('o-1', available), findsNothing);
      expect(answer('o-2', available), findsOneWidget);

      final dismiss = find.descendant(
        of: pollOutcome(),
        matching: find.text('Dismiss', skipOffstage: false),
        skipOffstage: false,
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
          expect(liveRegionSaying(_pollChangedCopy), findsOne);
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
          thrown: const EventRemoteNotFoundException(
            'gone',
          ) as EventRemoteException?,
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
      expect(chipsInDates(), findsNothing);

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
      expect(chipsInDates(), findsNothing);
      expect(find.byKey(EventDetailScreen.whoAnsweredKey), findsNothing);
    });

    testWidgets('a hidden poll says so, and a failed one offers a retry', (
      tester,
    ) async {
      EventRemoteException? fails = const EventRemoteForbiddenException(
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
      EventRemoteException? fails;
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

  group('RSVP (#508)', () {
    const going = EventParticipationStatus.attending;
    const maybe = EventParticipationStatus.maybe;
    const notGoing = EventParticipationStatus.notAttending;
    const invited = EventParticipationStatus.invited;
    const answers = [going, maybe, notGoing];

    /// What the cache holds: the detail a test shows, then each answer's
    /// row over it.
    late EventDetail cached;

    setUpAll(() => registerFallbackValue(attendance(invited)));

    setUp(() {
      // The viewer's row on the roster and as their attendance, and the
      // watch delivers it, as the repository does (#508).
      when(() => repository.cacheAttendee(any()))
          .thenAnswer((invocation) async {
            final row = invocation.positionalArguments.single as EventAttendee;
            cached = EventDetail(
              snapshot: cached.snapshot.copyWith(
                attendees: [
                  for (final attendee
                      in cached.snapshot.attendees ?? const <EventAttendee>[])
                    if (attendee.id == row.id) row else attendee,
                ],
              ),
              attendance: row,
            );
            cache.add(cached);
            return true;
          });
    });

    /// The viewer's own row on `e-1`, `att-me`, named Me, holding [role] and
    /// answered [status], with [notes].
    EventAttendee me({
      EventRole role = EventRole.participant,
      EventParticipationStatus status = invited,
      String? notes,
    }) => attendance(status)
        .copyWith(eventId: 'e-1', displayName: 'Me', role: role, notes: notes);

    /// Event `e-1`, Scheduled by a date ahead unless [status] or
    /// [occurrences] say otherwise, with [viewer] and Ada, who is going, on
    /// its roster. A null [viewer] isn't on it.
    EventDetail viewed(
      EventAttendee? viewer, {
      EventStatus status = EventStatus.scheduled,
      EventSchedulingMode schedulingMode = EventSchedulingMode.fixed,
      List<EventOccurrence>? occurrences,
      String? householdId,
    }) => _detail(
      event: _event(
        status: status,
        schedulingMode: schedulingMode,
        householdId: householdId,
      ),
      occurrences: occurrences ?? [_ahead()],
      attendees: [
        ?viewer,
        _member('att-2', displayName: 'Ada'),
      ],
      attendance: viewer,
    );

    /// The viewer's row as the server holds it after [request]: its answer,
    /// and the note it sent, else the one it had.
    EventAttendee answer(RsvpRequest request) {
      final mine = cached.attendance!;
      return mine.copyWith(
        status: request.status,
        notes: request.notes ?? mine.notes,
      );
    }

    /// A server whose reads serve what the cache holds, or answer from
    /// [read], whose RSVPs answer from [answered] ([answer] by default), and
    /// whose poll reads find nobody has answered.
    FakeEventRemote answering({
      FutureOr<EventSnapshot> Function(String id)? read,
      FutureOr<EventAttendee> Function(RsvpRequest request)? answered,
    }) => FakeEventRemote.detail(
      read ?? (_) => cached.snapshot,
      rsvp: answered ?? answer,
      summary: (_) => const AvailabilitySummary(occurrences: []),
    );

    /// Shows [detail] from [remote], with a way back.
    Future<void> showRsvp(
      WidgetTester tester,
      EventDetail detail,
      FakeEventRemote remote, {
      Future<HouseholdRole?> Function(String householdId)? householdRole,
      TextScaler textScaler = TextScaler.noScaling,
      ValueListenable<bool>? offline,
    }) async {
      cached = detail;
      await show(
        tester,
        detail,
        remote: remote,
        householdRole: householdRole,
        onBack: (_) {},
        textScaler: textScaler,
        offline: offline,
      );
      // The household role's lookup, and the poll's read.
      await settle(tester);
    }

    /// Lets the screen go, so the next [showRsvp] starts with new blocs.
    Future<void> leave(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    }

    Finder chip(EventParticipationStatus status) =>
        find.byKey(EventDetailScreen.rsvpAnswerKey(status));

    ChoiceChip chipOf(WidgetTester tester, EventParticipationStatus status) =>
        tester.widget(chip(status));

    Finder note() => find.byKey(EventDetailScreen.rsvpNoteKey);

    TextButton noteOf(WidgetTester tester) => tester.widget(note());

    Finder noteField() => find.byKey(EventDetailScreen.rsvpNoteFieldKey);

    Finder inGroup(EventParticipationStatus status, String text) =>
        find.descendant(
          of: find.byKey(EventDetailScreen.attendeeGroupKey(status)),
          matching: find.text(text),
        );

    Future<void> press(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await animate(tester);
    }

    /// Moves focus to [finder]'s control and presses Enter on it, as a
    /// keyboard user would, and answers its focus node.
    Future<FocusNode> pressWithKeys(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pump();
      final node = switch (tester.widget(finder)) {
        final ChoiceChip chip => chip.focusNode!,
        final ButtonStyleButton button => button.focusNode!,
        final widget => throw ArgumentError.value(widget),
      }..requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await animate(tester);
      return node;
    }

    Future<void> saveNote(WidgetTester tester, String text) async {
      await tester.enterText(noteField(), text);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(EventDetailScreen.rsvpNoteSaveKey));
      await animate(tester);
    }

    testWidgets('Going sends at once, and the banner says it is saved', (
      tester,
    ) async {
      final remote = answering();
      await showRsvp(tester, viewed(me()), remote);
      expect(find.text('Are you coming?'), findsOneWidget);
      expect(chipOf(tester, going).selected, isFalse);

      await press(tester, chip(going));

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.rsvps, [
        (eventId: 'e-1', attendeeId: 'att-me', status: going, notes: null),
      ]);
      expect(inOutcome(_rsvpSavedCopy), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.success);
      expect(chipOf(tester, going).selected, isTrue);
      expect(inGroup(going, 'Me'), findsOneWidget);

      // Maybe asks nothing either.
      await press(tester, chip(maybe));

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.rsvps.map((request) => request.status), [going, maybe]);
      expect(remote.rsvps.last.notes, isNull);
      expect(chipOf(tester, maybe).selected, isTrue);
      expect(inGroup(maybe, 'Me'), findsOneWidget);
    });

    testWidgets('Not going asks first, and Keep sends nothing', (tester) async {
      final remote = answering();
      await showRsvp(tester, viewed(me(status: going)), remote);

      await press(tester, chip(notGoing));

      expect(find.text('Not going?'), findsOneWidget);
      expect(find.text(_rsvpNotGoingBodyCopy), findsOneWidget);
      // In the error colour, as a decline's is: the games it takes off the
      // dates don't come back.
      expect(
        tester
            .widget<TextButton>(
              find.byKey(EventDetailScreen.rsvpNotGoingConfirmKey),
            )
            .style
            ?.foregroundColor
            ?.resolve(const {}),
        Theme.of(tester.element(find.byType(AlertDialog))).colorScheme.error,
      );
      await tester.tap(find.text('Keep my answer'));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.rsvps, isEmpty);
      expect(outcome(), findsNothing);
      expect(chipOf(tester, going).selected, isTrue);
      // Nothing is held: every control takes a press.
      for (final status in answers) {
        expect(chipOf(tester, status).onSelected, isNotNull);
      }
      expect(noteOf(tester).onPressed, isNotNull);
    });

    testWidgets('Not going confirmed sends notAttending', (tester) async {
      final remote = answering();
      await showRsvp(tester, viewed(me(status: going)), remote);

      await press(tester, chip(notGoing));
      await tester.tap(find.byKey(EventDetailScreen.rsvpNotGoingConfirmKey));
      await animate(tester);

      expect(remote.rsvps, [
        (eventId: 'e-1', attendeeId: 'att-me', status: notGoing, notes: null),
      ]);
      expect(inOutcome(_rsvpSavedCopy), findsOneWidget);
      expect(chipOf(tester, notGoing).selected, isTrue);
      expect(inGroup(notGoing, 'Me'), findsOneWidget);
    });

    testWidgets('the note dialog sends the current answer with the note, and '
        "an emptied note sends ''", (tester) async {
      final remote = answering();
      await showRsvp(tester, viewed(me(status: maybe)), remote);
      expect(find.text('Add a note'), findsOneWidget);

      await press(tester, note());
      expect(find.text('Your note'), findsOneWidget);
      await saveNote(tester, '  Running late  ');

      expect(remote.rsvps, [
        (
          eventId: 'e-1',
          attendeeId: 'att-me',
          status: maybe,
          notes: 'Running late',
        ),
      ]);
      expect(inOutcome(_rsvpSavedCopy), findsOneWidget);
      expect(find.text('Edit note'), findsOneWidget);
      expect(inGroup(maybe, 'Running late'), findsOneWidget);

      // The dialog opens on the note, and emptied it clears it.
      await press(tester, note());
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: noteField(),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        'Running late',
      );
      await saveNote(tester, '');

      expect(remote.rsvps.last, (
        eventId: 'e-1',
        attendeeId: 'att-me',
        status: maybe,
        notes: '',
      ));
      expect(find.text('Add a note'), findsOneWidget);
      expect(find.text('Running late'), findsNothing);
    });

    testWidgets('a note saved unchanged sends nothing', (tester) async {
      // The server takes every send as a new answer, and tells the host.
      for (final (notes, saved) in [
        (null, ''),
        ('', ''),
        ('Running late', 'Running late'),
        ('Running late', '  Running late  '),
      ]) {
        final remote = answering();
        await showRsvp(tester, viewed(me(status: going, notes: notes)), remote);
        final reason = '$notes -> "$saved"';

        await press(tester, note());
        await saveNote(tester, saved);

        expect(find.byType(AlertDialog), findsNothing, reason: reason);
        expect(remote.rsvps, isEmpty, reason: reason);
        expect(outcome(), findsNothing, reason: reason);
        // Nothing is held: every control takes a press.
        for (final status in answers) {
          expect(chipOf(tester, status).onSelected, isNotNull, reason: reason);
        }
        expect(noteOf(tester).onPressed, isNotNull, reason: reason);
        await leave(tester);
      }
    });

    testWidgets('a note saved as the dialog showed it, or as a sync left it '
        'while the dialog was open, sends nothing', (tester) async {
      // Saving what the dialog opened on would put it back over the note
      // another device saved meanwhile.
      for (final saved in ['Running late', 'Stuck in traffic']) {
        final remote = answering();
        await showRsvp(
          tester,
          viewed(me(status: going, notes: 'Running late')),
          remote,
        );
        await press(tester, note());

        cached = viewed(me(status: going, notes: 'Stuck in traffic'));
        cache.add(cached);
        await settle(tester);
        await saveNote(tester, saved);

        expect(remote.rsvps, isEmpty, reason: saved);
        expect(outcome(), findsNothing, reason: saved);
        expect(inGroup(going, 'Stuck in traffic'), findsOneWidget);
        expect(noteOf(tester).onPressed, isNotNull, reason: saved);
        await leave(tester);
      }
    });

    testWidgets('Not going confirmed after a sync answered it sends nothing', (
      tester,
    ) async {
      // The server takes it as a new answer all the same.
      final remote = answering();
      await showRsvp(tester, viewed(me(status: going)), remote);
      await press(tester, chip(notGoing));

      cached = viewed(me(status: notGoing));
      cache.add(cached);
      await settle(tester);
      await tester.tap(find.byKey(EventDetailScreen.rsvpNotGoingConfirmKey));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.rsvps, isEmpty);
      expect(outcome(), findsNothing);
      expect(inGroup(notGoing, 'Me'), findsOneWidget);
      for (final status in answers) {
        expect(chipOf(tester, status).onSelected, isNotNull);
      }
    });

    testWidgets('a host is offered Not going', (tester) async {
      final remote = answering();
      await showRsvp(
        tester,
        viewed(me(role: EventRole.host, status: going)),
        remote,
      );
      expect(chipOf(tester, notGoing).onSelected, isNotNull);

      await press(tester, chip(notGoing));
      expect(find.text(_rsvpNotGoingBodyCopy), findsOneWidget);
      await tester.tap(find.byKey(EventDetailScreen.rsvpNotGoingConfirmKey));
      await animate(tester);

      expect(remote.rsvps.single.status, notGoing);
      expect(inOutcome(_rsvpSavedCopy), findsOneWidget);
    });

    testWidgets('offers no answer on a cancelled or archived event', (
      tester,
    ) async {
      for (final status in [EventStatus.cancelled, EventStatus.archived]) {
        await showRsvp(
          tester,
          viewed(me(status: going), status: status),
          answering(),
        );

        expect(find.text('Are you coming?'), findsNothing, reason: '$status');
        for (final answer in answers) {
          expect(chip(answer), findsNothing, reason: '$status');
        }
        expect(note(), findsNothing, reason: '$status');
        // Their row still shows their answer, as everyone's does.
        expect(inGroup(going, 'Me'), findsOneWidget, reason: '$status');
        expect(
          inGroup(going, 'Participant · Going'),
          findsNWidgets(2),
          reason: '$status',
        );
        await leave(tester);
      }
    });

    testWidgets("offers no answer to a household admin who isn't on the "
        'roster', (tester) async {
      await showRsvp(
        tester,
        viewed(null, householdId: 'h-1'),
        answering(),
        householdRole: (_) async => HouseholdRole.householdAdmin,
      );

      // The household's role gives them Cancel, so it was read.
      expect(find.byKey(EventDetailScreen.moreActionsKey), findsOneWidget);
      expect(find.text('Are you coming?'), findsNothing);
      for (final answer in answers) {
        expect(chip(answer), findsNothing);
      }
      expect(note(), findsNothing);
    });

    testWidgets("offers no answer without the viewer's row", (tester) async {
      // Opened from the list before any read cached its roster. The answer
      // the list keeps for the viewer is not part of the detail, so the
      // cache gives the page no roster and no row of theirs to send an
      // answer for, and the read that would bring one hasn't ended.
      final remote = answering(read: (_) => Completer<EventSnapshot>().future);
      await showRsvp(tester, _detail(occurrences: [_ahead()]), remote);

      expect(
        inSection(EventDetailScreen.attendeesKey, 'Not loaded yet.'),
        findsOneWidget,
      );
      expect(find.text('Are you coming?'), findsNothing);
      for (final answer in answers) {
        expect(chip(answer), findsNothing);
      }
      expect(note(), findsNothing);
    });

    testWidgets('a dialog closed after the event was cancelled drops the '
        'write', (tester) async {
      final remote = answering();
      await showRsvp(tester, viewed(me(status: going)), remote);
      final reads = remote.detailRequests.length;
      await press(tester, chip(notGoing));

      // From another device, through a sync.
      cached = viewed(me(status: going), status: EventStatus.cancelled);
      cache.add(cached);
      await settle(tester);
      await tester.tap(find.byKey(EventDetailScreen.rsvpNotGoingConfirmKey));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.rsvps, isEmpty);
      // The banner is a live region, so a screen reader hears why nothing
      // happened. The page already shows the event as cached, so nothing is
      // read again.
      expect(inOutcome(_rsvpChangedCopy), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.warning);
      expect(remote.detailRequests, hasLength(reads));
    });

    testWidgets('a note dialog closed after the viewer left the roster, or '
        "their answer or role became one this client doesn't know, drops "
        'the write', (tester) async {
      for (final (name, synced) in [
        ('left the roster', viewed(null)),
        (
          'an unknown answer',
          viewed(me(status: EventParticipationStatus.unknown)),
        ),
        ('an unknown role', viewed(me(role: EventRole.unknown))),
      ]) {
        final remote = answering();
        await showRsvp(tester, viewed(me(status: going)), remote);
        await press(tester, note());

        cached = synced;
        cache.add(cached);
        await settle(tester);
        await saveNote(tester, 'Running late');

        expect(find.byType(AlertDialog), findsNothing, reason: name);
        expect(remote.rsvps, isEmpty, reason: name);
        expect(inOutcome(_rsvpChangedCopy), findsOneWidget, reason: name);
        await leave(tester);
      }
    });

    testWidgets('403 says the answer was refused and reads again', (
      tester,
    ) async {
      final remote = answering(
        answered: (_) =>
            throw const EventWriteRefusedException('no', statusCode: 403),
      );
      await showRsvp(tester, viewed(me()), remote);
      final reads = remote.detailRequests.length;

      await press(tester, chip(going));

      expect(remote.rsvps, hasLength(1));
      expect(inOutcome(_rsvpRefusedCopy), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.warning);
      expect(remote.detailRequests, hasLength(reads + 1));
      verifyNever(() => repository.cacheAttendee(any()));
    });

    group('each other end has its copy and tone', () {
      final ends = [
        (
          // The event, or the viewer's row on it: the read tells which.
          name: 'a 404',
          thrown: const EventRemoteNotFoundException(
            'gone',
          ) as EventRemoteException,
          copy: _rsvpGoneCopy,
          tone: BgeBannerTone.warning,
          rereads: true,
        ),
        (
          name: 'a 400',
          thrown: const EventWriteConflictException('no', statusCode: 400),
          copy: _rsvpChangedCopy,
          tone: BgeBannerTone.warning,
          rereads: true,
        ),
        (
          name: 'a transient failure',
          thrown: _offline,
          copy: _rsvpFailedCopy,
          tone: BgeBannerTone.error,
          rereads: true,
        ),
        (
          // A 2xx whose body didn't parse: the answer may have landed, so
          // the copy points at it, and the read shows it.
          name: 'any other failure',
          thrown: const EventRemotePermanentException(
            'unreadable',
            statusCode: 200,
          ),
          copy: _rsvpFailedUnexpectedCopy,
          tone: BgeBannerTone.error,
          rereads: true,
        ),
      ];

      for (final end in ends) {
        testWidgets('${end.name}: ${end.copy}', (tester) async {
          final remote = answering(answered: (_) => throw end.thrown);
          await showRsvp(tester, viewed(me()), remote);
          final reads = remote.detailRequests.length;

          await press(tester, chip(going));

          expect(inOutcome(end.copy), findsOneWidget);
          expect(toneOf(tester), end.tone);
          expect(
            remote.detailRequests,
            hasLength(reads + (end.rereads ? 1 : 0)),
          );
        });
      }
    });

    testWidgets('a lost answer is read again, and the read brings the saved '
        'answer back', (tester) async {
      // The server saved Maybe, and the answer was lost.
      when(
        () => repository.cacheEvent(any(), source: any(named: 'source')),
      ).thenAnswer((invocation) async {
        final snapshot = invocation.positionalArguments.first as EventSnapshot;
        final row = snapshot.attendees!.firstWhere((a) => a.id == 'att-me');
        cached = EventDetail(snapshot: snapshot, attendance: row);
        cache.add(cached);
      });
      final held = viewed(me(status: going));
      final saved = viewed(me(status: maybe));
      var served = held.snapshot;
      final remote = answering(
        read: (_) => served,
        answered: (_) {
          served = saved.snapshot;
          throw _offline;
        },
      );
      await showRsvp(tester, held, remote);
      expect(chipOf(tester, going).selected, isTrue);
      final reads = remote.detailRequests.length;

      await press(tester, chip(maybe));

      expect(inOutcome(_rsvpFailedCopy), findsOneWidget);
      expect(remote.detailRequests, hasLength(reads + 1));
      expect(chipOf(tester, maybe).selected, isTrue);
      expect(chipOf(tester, going).selected, isFalse);
    });

    testWidgets('offline, a failed answer and a failed read show one outcome '
        'banner and hold no control', (tester) async {
      final offline = ValueNotifier(false);
      addTearDown(offline.dispose);
      var failing = false;
      final remote = answering(
        read: (_) {
          if (failing) throw _offline;
          return cached.snapshot;
        },
        answered: (_) {
          failing = true;
          offline.value = true;
          throw _offline;
        },
      );
      await showRsvp(
        tester,
        viewed(me(status: going)),
        remote,
        offline: offline,
      );
      final reads = remote.detailRequests.length;

      await press(tester, chip(maybe));
      await settle(tester);

      // Still offline: the failed answer was read again, and the read
      // failed too.
      expect(remote.detailRequests, hasLength(reads + 1));
      expect(outcome(), findsOneWidget);
      expect(inOutcome(_rsvpFailedCopy), findsOneWidget);
      expect(find.text(_rsvpFailedCopy), findsOneWidget);
      // No control is held: every one is disabled, none with a spinner.
      for (final status in answers) {
        expect(chipOf(tester, status).onSelected, isNull, reason: '$status');
        expect(chipOf(tester, status).avatar, isNull, reason: '$status');
      }
      expect(noteOf(tester).onPressed, isNull);
      expect(
        find.descendant(
          of: find.byKey(EventDetailScreen.attendeesKey),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      // Back online, nothing stays held by the failed pair.
      offline.value = false;
      await tester.pump();
      for (final status in answers) {
        expect(chipOf(tester, status).onSelected, isNotNull, reason: '$status');
      }
      expect(noteOf(tester).onPressed, isNotNull);
    });

    testWidgets('a done answer reads the poll again', (tester) async {
      final remote = answering();
      final proposed = confirmed(
        'o-1',
        DateTime(2026, 11, 6, 19),
      ).copyWith(eventId: 'e-1', status: OccurrenceStatus.proposed);
      await showRsvp(
        tester,
        viewed(
          me(),
          schedulingMode: EventSchedulingMode.poll,
          occurrences: [proposed],
        ),
        remote,
      );
      final reads = remote.detailRequests.length;
      final polls = remote.summaryRequests.length;
      expect(polls, greaterThan(0));

      await press(tester, chip(going));

      expect(inOutcome(_rsvpSavedCopy), findsOneWidget);
      expect(remote.detailRequests, hasLength(reads + 1));
      // After the RSVP's read, so the poll counts the answer.
      expect(remote.summaryRequests, hasLength(polls + 1));
    });

    testWidgets('offline, the chips are disabled', (tester) async {
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      await showRsvp(
        tester,
        viewed(me(status: going, notes: 'Running late')),
        answering(),
        offline: offline,
      );

      for (final status in answers) {
        expect(chipOf(tester, status).onSelected, isNull, reason: '$status');
      }
      expect(noteOf(tester).onPressed, isNull);
      // Once, under the group.
      expect(
        inSection(EventDetailScreen.attendeesKey, _onlineOnlyCopy),
        findsOneWidget,
      );

      offline.value = false;
      await tester.pump();
      for (final status in answers) {
        expect(chipOf(tester, status).onSelected, isNotNull, reason: '$status');
      }
      expect(noteOf(tester).onPressed, isNotNull);
    });

    testWidgets('the answered chip keeps focus through the write and the '
        'read it starts', (tester) async {
      final reads = <Completer<EventSnapshot>>[];
      final written = Completer<EventAttendee>();
      final remote = answering(
        read: (_) {
          final read = Completer<EventSnapshot>();
          reads.add(read);
          return read.future;
        },
        answered: (_) => written.future,
      );
      await showRsvp(tester, viewed(me()), remote);
      reads.single.complete(cached.snapshot);
      await settle(tester);

      final focus = await pressWithKeys(tester, chip(going));
      expect(remote.rsvps, hasLength(1));

      void expectHeld(String reason) {
        expect(focus.hasPrimaryFocus, isTrue, reason: reason);
        expect(chipOf(tester, going).onSelected, isNotNull, reason: reason);
        expect(chipOf(tester, maybe).onSelected, isNull, reason: reason);
        expect(chipOf(tester, notGoing).onSelected, isNull, reason: reason);
        expect(noteOf(tester).onPressed, isNull, reason: reason);
      }

      expectHeld('the write is out');
      // Pressed again meanwhile, it sends nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(remote.rsvps, hasLength(1));

      // The answer is in, and the read its outcome starts is out.
      written.complete(answer(remote.rsvps.single));
      await settle(tester);
      expect(reads, hasLength(2));
      expect(inOutcome(_rsvpSavedCopy), findsOneWidget);
      expect(chipOf(tester, going).selected, isTrue);
      expectHeld('the read is out');

      // The read has ended: focus stayed, and every control takes a press.
      reads[1].complete(cached.snapshot);
      await settle(tester);
      expect(focus.hasPrimaryFocus, isTrue);
      for (final status in answers) {
        expect(chipOf(tester, status).onSelected, isNotNull, reason: '$status');
      }
      expect(noteOf(tester).onPressed, isNotNull);
    });

    testWidgets('a second answer pressed before the first is out sends '
        'nothing, and the first stays held', (tester) async {
      final written = Completer<EventAttendee>();
      final remote = answering(answered: (_) => written.future);
      await showRsvp(tester, viewed(me()), remote);
      await tester.ensureVisible(chip(going));
      await tester.pump();

      // Both before a frame shows the first one out.
      await tester.tap(chip(going));
      await tester.tap(chip(maybe));
      await tester.pump();

      expect(remote.rsvps.map((request) => request.status), [going]);
      // Going's write is out, and Going is the one held: it still takes a
      // press, and ignores it. Maybe's press was ignored, so it is disabled,
      // as the rest are while another control's request is out.
      expect(chipOf(tester, going).onSelected, isNotNull);
      expect(chipOf(tester, maybe).onSelected, isNull);
      expect(chipOf(tester, notGoing).onSelected, isNull);
      expect(noteOf(tester).onPressed, isNull);
      await tester.tap(chip(going));
      await tester.pump();
      expect(remote.rsvps, hasLength(1));

      written.complete(answer(remote.rsvps.single));
      await settle(tester);
      expect(chipOf(tester, going).selected, isTrue);
      expect(remote.rsvps, hasLength(1));
    });

    testWidgets('a dialog gives focus back to the control that opened it', (
      tester,
    ) async {
      final remote = answering();
      await showRsvp(tester, viewed(me(status: going)), remote);

      // Kept: nothing is sent, and Not going has it back.
      final notGoingFocus = await pressWithKeys(tester, chip(notGoing));
      expect(find.text('Not going?'), findsOneWidget);
      await tester.tap(find.text('Keep my answer'));
      await animate(tester);
      expect(remote.rsvps, isEmpty);
      expect(notGoingFocus.hasPrimaryFocus, isTrue);

      // Saved: the note button has it back, and keeps it through the write
      // and the read.
      final noteFocus = await pressWithKeys(tester, note());
      expect(find.text('Your note'), findsOneWidget);
      await saveNote(tester, 'Running late');
      expect(remote.rsvps.single.notes, 'Running late');
      expect(inOutcome(_rsvpSavedCopy), findsOneWidget);
      expect(noteFocus.hasPrimaryFocus, isTrue);

      // Cancelled: so does Edit note.
      await pressWithKeys(tester, note());
      await tester.tap(find.text('Cancel'));
      await animate(tester);
      expect(remote.rsvps, hasLength(1));
      expect(noteFocus.hasPrimaryFocus, isTrue);
    });

    testWidgets('the Not going and note dialogs fit at 320dp and 2.0 text', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 640));
      await showRsvp(
        tester,
        viewed(me(status: going, notes: 'Running late')),
        answering(),
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );
      expect(tester.takeException(), isNull);

      // Each dialog's title and body scroll, and its buttons stay on screen.
      for (final (opener, confirm, keep) in [
        (
          chip(notGoing),
          EventDetailScreen.rsvpNotGoingConfirmKey,
          'Keep my answer',
        ),
        (note(), EventDetailScreen.rsvpNoteSaveKey, 'Cancel'),
      ]) {
        await press(tester, opener);
        expect(tester.takeException(), isNull);
        final dialog = tester.getRect(find.byType(AlertDialog));
        for (final button in [
          find.byKey(confirm),
          find.ancestor(
            of: find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text(keep),
            ),
            matching: find.byType(TextButton),
          ),
        ]) {
          final rect = tester.getRect(button);
          expect(dialog.intersect(rect), rect);
          expect(rect.bottom, lessThanOrEqualTo(640));
        }
        await tester.tap(find.text(keep));
        await animate(tester);
      }
    });
  });

  group('the roster (#510)', () {
    const going = EventParticipationStatus.attending;
    const maybe = EventParticipationStatus.maybe;
    const notGoing = EventParticipationStatus.notAttending;
    const invited = EventParticipationStatus.invited;

    /// What the cache holds: the detail a test shows, then each write's
    /// answer over it.
    late EventDetail cached;

    setUpAll(() => registerFallbackValue(attendance(invited)));

    /// [cached] with its roster as [change] leaves it, delivered by the
    /// watch, as the repository's writes are.
    void recache(
      List<EventAttendee> Function(List<EventAttendee> roster) change,
    ) {
      cached = EventDetail(
        snapshot: cached.snapshot.copyWith(
          attendees: change(
            cached.snapshot.attendees ?? const <EventAttendee>[],
          ),
        ),
        attendance: cached.attendance,
      );
      cache.add(cached);
    }

    setUp(() {
      when(() => repository.cacheAttendee(any())).thenAnswer((
        invocation,
      ) async {
        final row = invocation.positionalArguments.single as EventAttendee;
        recache(
          (roster) => [
            for (final a in roster)
              if (a.id == row.id) row else a,
          ],
        );
        return true;
      });
      when(
        () => repository.removeCachedAttendee(
          eventId: any(named: 'eventId'),
          attendeeId: any(named: 'attendeeId'),
        ),
      ).thenAnswer((invocation) async {
        final id = invocation.namedArguments[#attendeeId] as String;
        recache(
          (roster) => [
            for (final a in roster)
              if (a.id != id) a,
          ],
        );
        return true;
      });
      when(() => repository.addCachedAttendee(any()))
          .thenAnswer((invocation) async {
            final row = invocation.positionalArguments.single as EventAttendee;
            recache((roster) => [...roster, row]);
            return true;
          });
    });

    /// The viewer's own row on `e-1`, `att-me`, named Me, holding [role]
    /// and going.
    EventAttendee me(EventRole role) =>
        attendance(going)
            .copyWith(eventId: 'e-1', displayName: 'Me', role: role);

    /// Ada, a participant who is going, and Bo, who may come.
    final ada = _member('att-2', displayName: 'Ada');
    final bo = _member('att-3', displayName: 'Bo', status: maybe);

    /// Event `e-1`, Scheduled by a date ahead unless [status] says
    /// otherwise, which the viewer holds [role] on, with [others] beside
    /// them on its roster: Ada and Bo unless a test says.
    EventDetail viewed({
      EventRole role = EventRole.host,
      EventStatus status = EventStatus.scheduled,
      List<EventAttendee>? others,
    }) => _detail(
      event: _event(status: status),
      occurrences: [_ahead()],
      attendees: [
        me(role),
        ...(others ?? [ada, bo]),
      ],
      attendance: me(role),
    );

    /// Row [id] as the cache holds it.
    EventAttendee rowOf(String id) =>
        cached.snapshot.attendees!.firstWhere((row) => row.id == id);

    /// A server whose reads serve what the cache holds, or answer from
    /// [read]. An answer set for someone answers from [answered], by
    /// default their row with that answer and the note it had, and a remove
    /// from [removed], by default the row. An add answers from [added].
    FakeEventRemote answering({
      FutureOr<EventSnapshot> Function(String id)? read,
      FutureOr<EventAttendee> Function(RsvpRequest request)? answered,
      FutureOr<EventAttendee> Function(RemoveAttendeeRequest request)? removed,
      FutureOr<EventAttendee> Function(AddAttendeeRequest request)? added,
    }) => FakeEventRemote.detail(
      read ?? (_) => cached.snapshot,
      rsvp:
          answered ??
          (request) =>
              rowOf(request.attendeeId).copyWith(status: request.status),
      removed: removed ?? (request) => rowOf(request.attendeeId),
      added: added ?? (_) => throw UnimplementedError('no add is sent'),
      summary: (_) => const AvailabilitySummary(occurrences: []),
    );

    /// Shows [detail] from [remote], with a way back, and with
    /// [onAddAttendee] as the way to the Add people page.
    Future<void> showRoster(
      WidgetTester tester,
      EventDetail detail,
      FakeEventRemote remote, {
      TextScaler? textScaler,
      Future<EventAttendeeAddition?> Function(
        BuildContext context,
        AddAttendeeArgs args,
      )?
      onAddAttendee,
    }) async {
      cached = detail;
      await show(
        tester,
        detail,
        remote: remote,
        onBack: (_) {},
        onAddAttendee: onAddAttendee,
        textScaler: textScaler,
      );
      await settle(tester);
    }

    /// Lets the screen go, so the next [showRoster] starts with new blocs.
    Future<void> leave(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    }

    Finder menuOf(String id) =>
        find.byKey(EventDetailScreen.attendeeMenuKey(id));

    Finder itemOf(String id, String item) =>
        find.byKey(EventDetailScreen.attendeeActionKey(id, item));

    Finder inGroup(EventParticipationStatus status, String text) =>
        find.descendant(
          of: find.byKey(EventDetailScreen.attendeeGroupKey(status)),
          matching: find.text(text),
        );

    /// Opens row [id]'s menu and picks [item], then lets what it opens
    /// finish moving. The pick lands after the frame its tap ends in, which
    /// [animate] covers.
    Future<void> choose(WidgetTester tester, String id, String item) async {
      await tester.ensureVisible(menuOf(id));
      await tester.pump();
      await tester.tap(menuOf(id));
      await animate(tester);
      await tester.tap(itemOf(id, item));
      await animate(tester);
    }

    /// The colour [key]'s dialog button draws its label in.
    Color? labelColourOf(WidgetTester tester, Key key) => tester
        .widget<TextButton>(find.byKey(key))
        .style
        ?.foregroundColor
        ?.resolve(const {});

    Color errorColour(WidgetTester tester) =>
        Theme.of(tester.element(find.byType(AlertDialog))).colorScheme.error;

    testWidgets('Remove asks, then sends the remove', (tester) async {
      final remote = answering();
      await showRoster(tester, viewed(), remote);
      // Not on the viewer's own row: leaving is #512's.
      expect(menuOf('att-me'), findsNothing);
      expect(menuOf('att-2'), findsOneWidget);
      final reads = remote.detailRequests.length;

      await choose(tester, 'att-2', 'remove');

      // It names them, and says what it does to their games and votes.
      expect(find.text('Remove Ada?'), findsOneWidget);
      expect(find.text(_removeAdaBodyCopy), findsOneWidget);
      expect(find.text('Keep them'), findsOneWidget);
      expect(
        labelColourOf(tester, EventDetailScreen.attendeeRemoveConfirmKey),
        errorColour(tester),
      );
      expect(remote.removes, isEmpty);

      await tester.tap(find.byKey(EventDetailScreen.attendeeRemoveConfirmKey));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.removes, [(eventId: 'e-1', attendeeId: 'att-2')]);
      verify(
        () => repository.removeCachedAttendee(
          eventId: 'e-1',
          attendeeId: 'att-2',
        ),
      ).called(1);
      expect(inOutcome('Removed Ada.'), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.success);
      expect(find.text('Ada'), findsNothing);
      expect(menuOf('att-2'), findsNothing);
      // As after every write's done, so the roster shows what the server
      // holds.
      expect(remote.detailRequests, hasLength(reads + 1));
    });

    testWidgets('keeping them sends nothing', (tester) async {
      final remote = answering();
      await showRoster(tester, viewed(), remote);
      final reads = remote.detailRequests.length;

      await choose(tester, 'att-2', 'remove');
      await tester.tap(find.text('Keep them'));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.removes, isEmpty);
      expect(outcome(), findsNothing);
      expect(inGroup(going, 'Ada'), findsOneWidget);
      expect(remote.detailRequests, hasLength(reads));
      // Nothing is held: the menu still takes a pick.
      await tester.tap(menuOf('att-2'));
      await animate(tester);
      expect(
        tester.widget<MenuItemButton>(itemOf('att-2', 'remove')).onPressed,
        isNotNull,
      );
    });

    testWidgets('a remove that finds them gone says they were already off', (
      tester,
    ) async {
      // Removed on another device: the read after the remove shows the
      // roster without them.
      when(() => repository.cacheEvent(any(), source: any(named: 'source')))
          .thenAnswer((invocation) async {
            cached = EventDetail(
              snapshot: invocation.positionalArguments.first as EventSnapshot,
              attendance: cached.attendance,
            );
            cache.add(cached);
          });
      var served = viewed().snapshot;
      final remote = answering(
        read: (_) => served,
        removed: (_) {
          served = viewed(others: [bo]).snapshot;
          throw const EventRemoteNotFoundException('gone');
        },
      );
      await showRoster(tester, viewed(), remote);
      final reads = remote.detailRequests.length;

      await choose(tester, 'att-2', 'remove');
      await tester.tap(find.byKey(EventDetailScreen.attendeeRemoveConfirmKey));
      await animate(tester);

      expect(remote.removes, hasLength(1));
      expect(inOutcome('Ada was already off the event.'), findsOneWidget);
      // What the remove asked for, as a delete's gone is.
      expect(toneOf(tester), BgeBannerTone.success);
      expect(remote.detailRequests, hasLength(reads + 1));
      expect(find.text('Ada'), findsNothing);
      verifyNever(
        () => repository.removeCachedAttendee(
          eventId: any(named: 'eventId'),
          attendeeId: any(named: 'attendeeId'),
        ),
      );
    });

    testWidgets('Not going for someone asks first, naming them', (
      tester,
    ) async {
      final remote = answering();
      await showRoster(tester, viewed(), remote);

      await choose(tester, 'att-2', 'notGoing');

      expect(find.text('Mark Ada as not going?'), findsOneWidget);
      expect(find.text(_notGoingForAdaBodyCopy), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(EventDetailScreen.attendeeNotGoingConfirmKey),
          matching: find.text('Not going'),
        ),
        findsOneWidget,
      );
      // In the error colour, as the viewer's own Not going is.
      expect(
        labelColourOf(tester, EventDetailScreen.attendeeNotGoingConfirmKey),
        errorColour(tester),
      );

      // Kept, nothing is sent.
      await tester.tap(find.text('Keep their answer'));
      await animate(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.rsvps, isEmpty);
      expect(outcome(), findsNothing);
      expect(inGroup(going, 'Ada'), findsOneWidget);

      await choose(tester, 'att-2', 'notGoing');
      await tester.tap(
        find.byKey(EventDetailScreen.attendeeNotGoingConfirmKey),
      );
      await animate(tester);

      expect(remote.rsvps, [
        (eventId: 'e-1', attendeeId: 'att-2', status: notGoing, notes: null),
      ]);
      expect(inOutcome("Saved Ada's answer."), findsOneWidget);
      expect(inGroup(notGoing, 'Ada'), findsOneWidget);
    });

    testWidgets('Not going for someone after a sync answered it sends '
        'nothing', (tester) async {
      // The server takes it as a new answer all the same.
      final remote = answering();
      await showRoster(tester, viewed(), remote);
      await choose(tester, 'att-2', 'notGoing');

      cached = viewed(
        others: [
          ada.copyWith(status: notGoing),
          bo,
        ],
      );
      cache.add(cached);
      await settle(tester);
      await tester.tap(
        find.byKey(EventDetailScreen.attendeeNotGoingConfirmKey),
      );
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.rsvps, isEmpty);
      expect(outcome(), findsNothing);
      expect(inGroup(notGoing, 'Ada'), findsOneWidget);
    });

    testWidgets('Maybe for someone sends at once', (tester) async {
      final remote = answering();
      // Ada left a note, which an answer set for her leaves as it was.
      await showRoster(
        tester,
        viewed(
          others: [
            ada.copyWith(notes: 'Bringing snacks'),
            bo,
          ],
        ),
        remote,
      );

      await choose(tester, 'att-2', 'maybe');

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.rsvps, [
        (eventId: 'e-1', attendeeId: 'att-2', status: maybe, notes: null),
      ]);
      expect(inGroup(maybe, 'Ada'), findsOneWidget);
      expect(inGroup(maybe, 'Bringing snacks'), findsOneWidget);
    });

    testWidgets('a row removed by a sync while the dialog was open drops the '
        'remove with the roster-changed banner', (tester) async {
      final remote = answering();
      await showRoster(tester, viewed(), remote);
      final reads = remote.detailRequests.length;
      await choose(tester, 'att-2', 'remove');

      // From another device, through a sync.
      cached = viewed(others: [bo]);
      cache.add(cached);
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.byKey(EventDetailScreen.attendeeRemoveConfirmKey));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.removes, isEmpty);
      // The banner is a live region, so a screen reader hears why nothing
      // happened. The page already shows the roster as cached, so nothing is
      // read again.
      expect(inOutcome(_rosterChangedCopy), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.warning);
      expect(remote.detailRequests, hasLength(reads));
    });

    testWidgets('the event cancelled while the Remove dialog was open drops '
        'the remove', (tester) async {
      final remote = answering();
      await showRoster(tester, viewed(), remote);
      final reads = remote.detailRequests.length;
      await choose(tester, 'att-2', 'remove');

      // From another device, through a sync. The page offers no menus now.
      cached = viewed(status: EventStatus.cancelled);
      cache.add(cached);
      await settle(tester);
      expect(menuOf('att-2'), findsNothing);
      await tester.tap(find.byKey(EventDetailScreen.attendeeRemoveConfirmKey));
      await animate(tester);

      expect(remote.removes, isEmpty);
      expect(inOutcome(_rosterChangedCopy), findsOneWidget);
      expect(toneOf(tester), BgeBannerTone.warning);
      expect(remote.detailRequests, hasLength(reads));
    });

    testWidgets('a co-host made an organizer while removing a co-host drops '
        'the remove', (tester) async {
      final cleo = _member(
        'att-6',
        displayName: 'Cleo',
        role: EventRole.coHost,
      );
      final remote = answering();
      await showRoster(
        tester,
        viewed(role: EventRole.coHost, others: [cleo]),
        remote,
      );
      await choose(tester, 'att-6', 'remove');

      // An organizer removes only those who attend, and the server would
      // refuse it: the page shows Cleo's menu without Remove.
      cached = viewed(role: EventRole.organizer, others: [cleo]);
      cache.add(cached);
      await settle(tester);
      await tester.tap(find.byKey(EventDetailScreen.attendeeRemoveConfirmKey));
      await animate(tester);

      expect(remote.removes, isEmpty);
      expect(inOutcome(_rosterChangedCopy), findsOneWidget);
      await tester.ensureVisible(menuOf('att-6'));
      await tester.pump();
      await tester.tap(menuOf('att-6'));
      await animate(tester);
      expect(itemOf('att-6', 'notGoing'), findsOneWidget);
      expect(itemOf('att-6', 'remove'), findsNothing);
    });

    testWidgets('a Not going dialog closed after the row left, or the viewer '
        'lost the roster, drops the answer', (tester) async {
      for (final (name, synced) in [
        ('the row left', viewed(others: [bo])),
        ('made a participant', viewed(role: EventRole.participant)),
      ]) {
        final remote = answering();
        await showRoster(tester, viewed(), remote);
        final reads = remote.detailRequests.length;
        await choose(tester, 'att-2', 'notGoing');

        cached = synced;
        cache.add(cached);
        await settle(tester);
        await tester.tap(
          find.byKey(EventDetailScreen.attendeeNotGoingConfirmKey),
        );
        await animate(tester);

        expect(remote.rsvps, isEmpty, reason: name);
        expect(inOutcome(_rosterChangedCopy), findsOneWidget, reason: name);
        expect(toneOf(tester), BgeBannerTone.warning, reason: name);
        expect(remote.detailRequests, hasLength(reads), reason: name);
        await leave(tester);
      }
    });

    testWidgets("a nameless row's remove that finds them gone starts its "
        'sentence with This person', (tester) async {
      final nobody = EventAttendee(
        id: 'att-7',
        eventId: 'e-1',
        userId: 'user-7',
        role: EventRole.participant,
        status: going,
        createdAt: kItemInstant,
        updatedAt: kItemInstant,
      );
      final remote = answering(
        removed: (_) => throw const EventRemoteNotFoundException('gone'),
      );
      await showRoster(tester, viewed(others: [nobody]), remote);
      expect(find.byTooltip('Actions for this person'), findsOneWidget);

      await choose(tester, 'att-7', 'remove');
      // Mid-sentence, it is lower case.
      expect(find.text('Remove this person?'), findsOneWidget);
      await tester.tap(find.byKey(EventDetailScreen.attendeeRemoveConfirmKey));
      await animate(tester);

      expect(
        inOutcome('This person was already off the event.'),
        findsOneWidget,
      );
    });

    testWidgets('a roster menu waits for a running read, and for a request '
        'already out', (tester) async {
      final reads = <Completer<EventSnapshot>>[];
      final written = Completer<EventAttendee>();
      final remote = answering(
        read: (_) {
          final read = Completer<EventSnapshot>();
          reads.add(read);
          return read.future;
        },
        answered: (_) => written.future,
      );
      await showRoster(tester, viewed(), remote);

      /// Opens Bo's menu, says whether each item Bo may be given takes a
      /// press, and closes it. Maybe is Bo's answer, and never does.
      Future<List<bool>> bosItems() async {
        // A banner that just landed scrolls itself into view first.
        await animate(tester);
        await tester.ensureVisible(menuOf('att-3'));
        await tester.pump();
        await tester.tap(menuOf('att-3'));
        await animate(tester);
        final pressable = [
          for (final item in ['going', 'notGoing', 'remove'])
            tester.widget<MenuItemButton>(itemOf('att-3', item)).onPressed !=
                null,
        ];
        await tester.tap(menuOf('att-3'));
        await animate(tester);
        return pressable;
      }

      // The open's read runs, whose answer landing after a write would put
      // the row back as it was (#589). The menu still opens.
      expect(reads, hasLength(1));
      expect(await bosItems(), [false, false, false]);
      reads.single.complete(cached.snapshot);
      await settle(tester);
      expect(await bosItems(), [true, true, true]);

      // Ada's answer is out.
      await choose(tester, 'att-2', 'maybe');
      expect(remote.rsvps, hasLength(1));
      expect(await bosItems(), [false, false, false]);

      // Its done reads again, and the menus wait for that read too.
      written.complete(rowOf('att-2').copyWith(status: maybe));
      await settle(tester);
      expect(reads, hasLength(2));
      expect(await bosItems(), [false, false, false]);
      reads[1].complete(cached.snapshot);
      await settle(tester);
      expect(await bosItems(), [true, true, true]);
    });

    testWidgets('the remove and Not going dialogs fit at 320dp and 2.0 text', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 640));
      await showRoster(
        tester,
        viewed(
          others: [
            ada.copyWith(
              displayName:
                  'Maximiliana Theodora Featherstonehaugh-Cholmondeley',
            ),
          ],
        ),
        answering(),
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );
      expect(tester.takeException(), isNull);

      // Each dialog's title and body scroll, and its buttons stay on screen.
      for (final (item, confirm, keep) in [
        ('remove', EventDetailScreen.attendeeRemoveConfirmKey, 'Keep them'),
        (
          'notGoing',
          EventDetailScreen.attendeeNotGoingConfirmKey,
          'Keep their answer',
        ),
      ]) {
        await choose(tester, 'att-2', item);
        expect(tester.takeException(), isNull, reason: item);
        expect(find.byKey(confirm), findsOneWidget, reason: item);
        final dialog = tester.getRect(find.byType(AlertDialog));
        for (final button in [
          find.byKey(confirm),
          find.ancestor(
            of: find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text(keep),
            ),
            matching: find.byType(TextButton),
          ),
        ]) {
          final rect = tester.getRect(button);
          expect(dialog.intersect(rect), rect, reason: item);
          expect(rect.bottom, lessThanOrEqualTo(640), reason: item);
        }
        await tester.tap(find.text(keep));
        await animate(tester);
      }
    });

    testWidgets('a done answer shows the saved banner and reads again', (
      tester,
    ) async {
      final remote = answering();
      await showRoster(tester, viewed(), remote);
      final reads = remote.detailRequests.length;

      await choose(tester, 'att-3', 'going');

      expect(remote.rsvps, [
        (eventId: 'e-1', attendeeId: 'att-3', status: going, notes: null),
      ]);
      verify(
        () => repository.cacheAttendee(
          any(
            that: isA<EventAttendee>()
                .having((row) => row.id, 'id', 'att-3')
                .having((row) => row.status, 'status', going),
          ),
        ),
      ).called(1);
      expect(inOutcome("Saved Bo's answer."), findsOneWidget);
      expect(liveRegionSaying("Saved Bo's answer."), findsOne);
      expect(toneOf(tester), BgeBannerTone.success);
      expect(inGroup(going, 'Bo'), findsOneWidget);
      expect(remote.detailRequests, hasLength(reads + 1));
    });

    testWidgets('no row menu on a cancelled event', (tester) async {
      // Nor on an archived one (#510): the host keeps the grant, and the
      // event takes no such write.
      for (final status in [EventStatus.cancelled, EventStatus.archived]) {
        await showRoster(tester, viewed(status: status), answering());

        expect(inGroup(going, 'Ada'), findsOneWidget, reason: '$status');
        expect(menuOf('att-2'), findsNothing, reason: '$status');
        expect(menuOf('att-3'), findsNothing, reason: '$status');
        await leave(tester);
      }
    });

    group('Add people', () {
      /// Whom the page answers with in these tests.
      const cy = UserSummary(id: 'user-cy', username: 'cy', displayName: 'Cy');

      /// Cy's row once added with [role]: invited, as every add is.
      EventAttendee cysRow(EventRole role) => _member(
        'att-cy',
        displayName: 'Cy',
        role: role,
        status: invited,
      ).copyWith(userId: cy.id);

      Finder addPeople() => find.byKey(EventDetailScreen.addAttendeeKey);

      /// A server whose add answers Cy's row, with the role asked for,
      /// unless [added] says otherwise.
      FakeEventRemote adding({
        FutureOr<EventSnapshot> Function(String id)? read,
        FutureOr<EventAttendee> Function(AddAttendeeRequest request)? added,
      }) => answering(
        read: read,
        added: added ?? (request) => cysRow(request.role),
      );

      /// Presses Add people, and lets what it sends land.
      Future<void> pressAddPeople(WidgetTester tester) async {
        await tester.ensureVisible(addPeople());
        await tester.pump();
        await tester.tap(addPeople());
        await animate(tester);
      }

      testWidgets("Add people opens the page with the roles and the roster's "
          'user ids', (tester) async {
        final opened = <AddAttendeeArgs>[];
        Future<EventAttendeeAddition?> open(
          BuildContext _,
          AddAttendeeArgs args,
        ) async {
          opened.add(args);
          // Back, from the page.
          return null;
        }

        final remote = adding();
        // Dee, a guest without an account, has no user id to leave out.
        await showRoster(
          tester,
          viewed(others: [ada, bo, _guest('att-4', 'Dee')]),
          remote,
          onAddAttendee: open,
        );
        final reads = remote.detailRequests.length;
        expect(
          find.descendant(of: addPeople(), matching: find.text('Add people')),
          findsOneWidget,
        );
        // Under the viewer's own answer, over the roster it adds to.
        expect(
          tester.getTopLeft(addPeople()).dy,
          greaterThan(
            tester
                .getBottomLeft(
                  find.byKey(
                    EventDetailScreen.rsvpAnswerKey(
                      EventParticipationStatus.attending,
                    ),
                  ),
                )
                .dy,
          ),
        );
        expect(
          tester.getBottomLeft(addPeople()).dy,
          lessThan(
            tester
                .getTopLeft(
                  find.byKey(EventDetailScreen.attendeeGroupKey(going)),
                )
                .dy,
          ),
        );

        await pressAddPeople(tester);

        expect(opened, [
          AddAttendeeArgs(
            roles: assignableEventRoles(AttendeeReach.allRoles),
            rosterUserIds: const {'user-me', 'user-att-2', 'user-att-3'},
          ),
        ]);
        // Back from the page sends nothing, and says nothing.
        expect(remote.adds, isEmpty);
        expect(outcome(), findsNothing);
        expect(remote.detailRequests, hasLength(reads));

        // An organizer's page offers those who attend.
        await leave(tester);
        await showRoster(
          tester,
          viewed(role: EventRole.organizer),
          adding(),
          onAddAttendee: open,
        );
        await pressAddPeople(tester);
        expect(opened.last.roles, [
          EventRole.participant,
          EventRole.guest,
          EventRole.spectator,
        ]);
      });

      testWidgets('an addition sends the add', (tester) async {
        final remote = adding();
        await showRoster(
          tester,
          viewed(),
          remote,
          onAddAttendee: (_, _) async =>
              const EventAttendeeAddition(user: cy, role: EventRole.guest),
        );
        final reads = remote.detailRequests.length;

        await pressAddPeople(tester);

        expect(remote.adds, [
          (eventId: 'e-1', userId: 'user-cy', role: EventRole.guest),
        ]);
        verify(
          () => repository.addCachedAttendee(
            any(
              that: isA<EventAttendee>()
                  .having((row) => row.userId, 'userId', 'user-cy')
                  .having((row) => row.role, 'role', EventRole.guest),
            ),
          ),
        ).called(1);
        expect(
          inOutcome("Added Cy. They'll be asked whether they're coming."),
          findsOneWidget,
        );
        expect(toneOf(tester), BgeBannerTone.success);
        expect(inGroup(invited, 'Cy'), findsOneWidget);
        // As after every write's done, so the roster shows what the server
        // holds.
        expect(remote.detailRequests, hasLength(reads + 1));
      });

      testWidgets('a role taken away while the page is open drops the add', (
        tester,
      ) async {
        for (final (name, synced, role, stillOffered) in [
          // An organizer still adds people, but appoints no co-hosts, and
          // the server would refuse it.
          (
            'made an organizer',
            viewed(role: EventRole.organizer),
            EventRole.coHost,
            true,
          ),
          (
            'made a participant',
            viewed(role: EventRole.participant),
            EventRole.participant,
            false,
          ),
          (
            'the event cancelled',
            viewed(status: EventStatus.cancelled),
            EventRole.participant,
            false,
          ),
        ]) {
          final page = Completer<EventAttendeeAddition?>();
          final remote = adding();
          await showRoster(
            tester,
            viewed(),
            remote,
            onAddAttendee: (_, _) => page.future,
          );
          final reads = remote.detailRequests.length;
          await pressAddPeople(tester);

          // From another device, through a sync, while the page is open.
          cached = synced;
          cache.add(cached);
          await settle(tester);
          expect(
            addPeople(),
            stillOffered ? findsOneWidget : findsNothing,
            reason: name,
          );
          page.complete(EventAttendeeAddition(user: cy, role: role));
          await animate(tester);

          expect(remote.adds, isEmpty, reason: name);
          // The banner is a live region, so a screen reader hears why
          // nothing happened. The page already shows the event as cached,
          // so nothing is read again.
          expect(inOutcome(_rosterChangedCopy), findsOneWidget, reason: name);
          expect(liveRegionSaying(_rosterChangedCopy), findsOne, reason: name);
          expect(toneOf(tester), BgeBannerTone.warning, reason: name);
          expect(remote.detailRequests, hasLength(reads), reason: name);
          await leave(tester);
        }
      });

      testWidgets('someone added by a sync while the page was open drops the '
          'add with the roster-changed banner', (tester) async {
        final page = Completer<EventAttendeeAddition?>();
        final remote = adding();
        await showRoster(
          tester,
          viewed(),
          remote,
          onAddAttendee: (_, _) => page.future,
        );
        final reads = remote.detailRequests.length;
        await pressAddPeople(tester);

        // Added on another device: the page couldn't have offered them.
        cached = viewed(others: [ada, bo, cysRow(EventRole.participant)]);
        cache.add(cached);
        await settle(tester);
        page.complete(
          const EventAttendeeAddition(user: cy, role: EventRole.participant),
        );
        await animate(tester);

        expect(remote.adds, isEmpty);
        expect(inOutcome(_rosterChangedCopy), findsOneWidget);
        expect(toneOf(tester), BgeBannerTone.warning);
        expect(remote.detailRequests, hasLength(reads));
      });

      testWidgets('a roster gone from view while the page is open drops the '
          'add', (tester) async {
        // Read as hidden from the viewer, or not yet read at all: the page
        // beneath shows no roster, and no Add people.
        for (final (name, roster) in [
          ('hidden', const <EventAttendee>[]),
          ('not read', null),
        ]) {
          final page = Completer<EventAttendeeAddition?>();
          final remote = adding();
          await showRoster(
            tester,
            viewed(),
            remote,
            onAddAttendee: (_, _) => page.future,
          );
          final reads = remote.detailRequests.length;
          await pressAddPeople(tester);

          cached = _detail(
            event: _event(),
            occurrences: [_ahead()],
            attendees: roster,
            attendance: me(EventRole.host),
          );
          cache.add(cached);
          await settle(tester);
          expect(addPeople(), findsNothing, reason: name);
          page.complete(
            const EventAttendeeAddition(user: cy, role: EventRole.participant),
          );
          await animate(tester);

          expect(remote.adds, isEmpty, reason: name);
          expect(inOutcome(_rosterChangedCopy), findsOneWidget, reason: name);
          expect(toneOf(tester), BgeBannerTone.warning, reason: name);
          expect(remote.detailRequests, hasLength(reads), reason: name);
          await leave(tester);
        }
      });

      testWidgets('a press that finds no role left to give opens nothing', (
        tester,
      ) async {
        final opened = <AddAttendeeArgs>[];
        final remote = adding();
        await showRoster(
          tester,
          viewed(),
          remote,
          onAddAttendee: (_, args) async {
            opened.add(args);
            return null;
          },
        );
        await tester.ensureVisible(addPeople());
        await tester.pump();

        // A sync makes the viewer a participant, and the detail has it, but
        // no frame has shown it yet: the button is still there to press.
        cached = viewed(role: EventRole.participant);
        cache.add(cached);
        for (var i = 0; i < 10; i++) {
          await Future<void>.value();
        }
        final shown = blocOf(tester).state as EventDetailReady;
        expect(shown.attendeeReach, AttendeeReach.none);
        expect(addPeople(), findsOneWidget);

        await tester.tap(addPeople());
        await animate(tester);

        // The page needs a role to offer, so it isn't opened.
        expect(opened, isEmpty);
        expect(remote.adds, isEmpty);
        expect(outcome(), findsNothing);
        expect(addPeople(), findsNothing);
      });

      testWidgets('a press on an event a sync has cancelled opens nothing', (
        tester,
      ) async {
        // Nor archived: the host keeps the grant, and the event takes no
        // such write.
        for (final status in [EventStatus.cancelled, EventStatus.archived]) {
          final opened = <AddAttendeeArgs>[];
          final remote = adding();
          cached = viewed();
          await showRoster(
            tester,
            viewed(),
            remote,
            onAddAttendee: (_, args) async {
              opened.add(args);
              return null;
            },
          );
          await tester.ensureVisible(addPeople());
          await tester.pump();

          // The detail has it, but no frame has shown it yet: the button is
          // still there to press, and the role table still gives roles.
          cached = viewed(status: status);
          cache.add(cached);
          for (var i = 0; i < 10; i++) {
            await Future<void>.value();
          }
          final shown = blocOf(tester).state as EventDetailReady;
          expect(shown.detail.snapshot.event.status, status);
          expect(shown.attendeeReach, isNot(AttendeeReach.none));
          expect(addPeople(), findsOneWidget, reason: '$status');

          await tester.tap(addPeople());
          await animate(tester);

          expect(opened, isEmpty, reason: '$status');
          expect(remote.adds, isEmpty, reason: '$status');
          expect(outcome(), findsNothing, reason: '$status');
          expect(addPeople(), findsNothing, reason: '$status');
          await leave(tester);
        }
      });

      testWidgets("the add's 409 says they're already on", (tester) async {
        final remote = adding(
          added: (_) =>
              throw const EventWriteConflictException('on', statusCode: 409),
        );
        await showRoster(
          tester,
          viewed(),
          remote,
          onAddAttendee: (_, _) async => const EventAttendeeAddition(
            user: cy,
            role: EventRole.participant,
          ),
        );
        final reads = remote.detailRequests.length;

        await pressAddPeople(tester);

        expect(remote.adds, hasLength(1));
        expect(inOutcome('Cy is already on this event.'), findsOneWidget);
        expect(toneOf(tester), BgeBannerTone.warning);
        // The read shows them.
        expect(remote.detailRequests, hasLength(reads + 1));
      });

      testWidgets('no Add people without onAddAttendee', (tester) async {
        await showRoster(tester, viewed(), adding());

        expect(inGroup(going, 'Ada'), findsOneWidget);
        expect(addPeople(), findsNothing);
        await leave(tester);

        // Nor without a server to send it to, where nothing is offered.
        cached = viewed();
        await show(tester, viewed(), onAddAttendee: (_, _) async => null);
        expect(inGroup(going, 'Ada'), findsOneWidget);
        expect(addPeople(), findsNothing);
      });

      testWidgets('no Add people on a cancelled event', (tester) async {
        // Nor on an archived one (#510): the host keeps the grant, and the
        // event takes no such write.
        for (final status in [EventStatus.cancelled, EventStatus.archived]) {
          await showRoster(
            tester,
            viewed(status: status),
            adding(),
            onAddAttendee: (_, _) async => null,
          );

          expect(inGroup(going, 'Ada'), findsOneWidget, reason: '$status');
          expect(addPeople(), findsNothing, reason: '$status');
          await leave(tester);
        }
      });

      testWidgets('no Add people for a participant, or with no roster to add '
          'to', (tester) async {
        Future<EventAttendeeAddition?> open(
          BuildContext _,
          AddAttendeeArgs _,
        ) => Future.value();
        final unread = _detail(
          event: _event(),
          occurrences: [_ahead()],
          attendance: me(EventRole.host),
        );
        for (final (name, detail) in [
          ('a participant', viewed(role: EventRole.participant)),
          ('a roster not read yet', unread),
          (
            "a roster the viewer can't see",
            _detail(
              event: _event(),
              occurrences: [_ahead()],
              attendees: const [],
              attendance: me(EventRole.host),
            ),
          ),
        ]) {
          await showRoster(tester, detail, adding(), onAddAttendee: open);

          expect(
            find.byKey(EventDetailScreen.attendeesKey),
            findsOneWidget,
            reason: name,
          );
          expect(addPeople(), findsNothing, reason: name);
          await leave(tester);
        }
      });

      testWidgets('Add people waits for a running read and for another '
          'request, and keeps its focus through its own add', (tester) async {
        final reads = <Completer<EventSnapshot>>[];
        final written = Completer<EventAttendee>();
        final added = Completer<EventAttendee>();
        final remote = answering(
          read: (_) {
            final read = Completer<EventSnapshot>();
            reads.add(read);
            return read.future;
          },
          answered: (_) => written.future,
          added: (_) => added.future,
        );
        await showRoster(
          tester,
          viewed(),
          remote,
          onAddAttendee: (_, _) async => const EventAttendeeAddition(
            user: cy,
            role: EventRole.participant,
          ),
        );
        TextButton button() => tester.widget<TextButton>(addPeople());
        Finder showing(String label) =>
            find.descendant(of: addPeople(), matching: find.text(label));

        // The open's read runs, whose answer landing after the add would
        // leave the roster without them (#589).
        expect(button().onPressed, isNull);
        reads.single.complete(cached.snapshot);
        await settle(tester);
        expect(button().onPressed, isNotNull);

        // Another request is out: Ada's answer, then the read its done
        // starts.
        await choose(tester, 'att-2', 'maybe');
        expect(remote.rsvps, hasLength(1));
        expect(button().onPressed, isNull);
        written.complete(rowOf('att-2').copyWith(status: maybe));
        await settle(tester);
        expect(button().onPressed, isNull);
        reads[1].complete(cached.snapshot);
        await settle(tester);
        await animate(tester);
        expect(button().onPressed, isNotNull);

        // Its own add, from the keyboard: the page hands the focus back to
        // it as it closes, and a disabled button would drop it (#607).
        final focus = button().focusNode!;
        await tester.ensureVisible(addPeople());
        await tester.pump();
        focus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expect(remote.adds, hasLength(1));
        expect(focus.hasPrimaryFocus, isTrue);
        expect(showing('Adding…'), findsOneWidget);
        expect(
          tester.getSemantics(addPeople()),
          isSemantics(label: 'Adding…', isEnabled: false, isFocused: true),
        );
        // A press meanwhile sends nothing more.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expect(remote.adds, hasLength(1));

        // Held through the read its done starts, then let go.
        added.complete(cysRow(EventRole.participant));
        await settle(tester);
        expect(reads, hasLength(3));
        expect(focus.hasPrimaryFocus, isTrue);
        expect(showing('Adding…'), findsOneWidget);
        reads[2].complete(cached.snapshot);
        await settle(tester);
        await animate(tester);
        expect(focus.hasPrimaryFocus, isTrue);
        expect(showing('Add people'), findsOneWidget);
        expect(button().onPressed, isNotNull);
      });
    });

    group('each other remove and answer end has its copy and tone', () {
      final ends = [
        (
          name: "a remove's 403",
          remove: true,
          thrown: const EventWriteRefusedException('no', statusCode: 403),
          copy: "You can't remove Ada from this event.",
          tone: BgeBannerTone.warning,
        ),
        (
          // A roster that moved since it was read: the read shows how.
          name: "a remove's 400",
          remove: true,
          thrown: const EventWriteConflictException('no', statusCode: 400),
          copy: _rosterChangedCopy,
          tone: BgeBannerTone.warning,
        ),
        (
          name: "an answer's 404",
          remove: false,
          thrown: const EventRemoteNotFoundException('gone'),
          copy: 'Ada is no longer on this event.',
          tone: BgeBannerTone.warning,
        ),
        (
          name: "an answer's 403",
          remove: false,
          thrown: const EventWriteRefusedException('no', statusCode: 403),
          copy: "You can't change Ada's answer.",
          tone: BgeBannerTone.warning,
        ),
        (
          name: "an answer's 400",
          remove: false,
          thrown: const EventWriteConflictException('no', statusCode: 400),
          copy: _rosterChangedCopy,
          tone: BgeBannerTone.warning,
        ),
        (
          name: "an answer's transient failure",
          remove: false,
          thrown: _offline,
          copy: _attendeeWriteFailedCopy,
          tone: BgeBannerTone.error,
        ),
      ];

      for (final end in ends) {
        testWidgets('${end.name}: ${end.copy}', (tester) async {
          final remote = answering(
            answered: (_) => throw end.thrown,
            removed: (_) => throw end.thrown,
          );
          await showRoster(tester, viewed(), remote);
          final reads = remote.detailRequests.length;

          if (end.remove) {
            await choose(tester, 'att-2', 'remove');
            await tester.tap(
              find.byKey(EventDetailScreen.attendeeRemoveConfirmKey),
            );
            await animate(tester);
          } else {
            await choose(tester, 'att-2', 'maybe');
          }

          expect(remote.removes, hasLength(end.remove ? 1 : 0));
          expect(remote.rsvps, hasLength(end.remove ? 0 : 1));
          expect(inOutcome(end.copy), findsOneWidget);
          expect(liveRegionSaying(end.copy), findsOne);
          expect(toneOf(tester), end.tone);
          // Each went out, so the roster is read again to show what the
          // server holds.
          expect(remote.detailRequests, hasLength(reads + 1));
        });
      }
    });

    group('each add end has its copy and tone', () {
      // Task 10's page sends an add. Here the actions bloc is sent one
      // directly, as the poll's outcome audit sends its bloc a vote.
      final cy = _member('att-9', displayName: 'Cy', status: invited);
      final ends = [
        (
          name: 'done',
          answer: (AddAttendeeRequest _) => cy,
          who: 'Cy',
          copy: "Added Cy. They'll be asked whether they're coming.",
          tone: BgeBannerTone.success,
          rereads: true,
        ),
        (
          // A person with no name is named for what they are.
          name: 'done, for someone with no name',
          answer: (AddAttendeeRequest _) => cy,
          who: null,
          copy: "Added this person. They'll be asked whether they're coming.",
          tone: BgeBannerTone.success,
          rereads: true,
        ),
        (
          // On the event already, perhaps added on another device.
          name: 'a 409',
          answer: (AddAttendeeRequest _) =>
              throw const EventWriteConflictException('on', statusCode: 409),
          who: 'Cy',
          copy: 'Cy is already on this event.',
          tone: BgeBannerTone.warning,
          rereads: true,
        ),
        (
          name: 'a 409, for someone with no name',
          answer: (AddAttendeeRequest _) =>
              throw const EventWriteConflictException('on', statusCode: 409),
          who: null,
          copy: 'This person is already on this event.',
          tone: BgeBannerTone.warning,
          rereads: true,
        ),
        (
          name: 'a 404',
          answer: (AddAttendeeRequest _) =>
              throw const EventRemoteNotFoundException('gone'),
          who: 'Cy',
          copy: "Couldn't add Cy: they or this event can't be found.",
          tone: BgeBannerTone.warning,
          rereads: true,
        ),
        (
          // A grant gone, or the invitee's own settings: one copy for both.
          name: 'a 403',
          answer: (AddAttendeeRequest _) =>
              throw const EventWriteRefusedException('no', statusCode: 403),
          who: 'Cy',
          copy: "Cy can't be added to this event.",
          tone: BgeBannerTone.warning,
          rereads: true,
        ),
        (
          name: 'a transient failure',
          answer: (AddAttendeeRequest _) => throw _offline,
          who: 'Cy',
          copy: _attendeeWriteFailedCopy,
          tone: BgeBannerTone.error,
          rereads: true,
        ),
        (
          name: 'any other failure',
          answer: (AddAttendeeRequest _) =>
              throw const EventRemotePermanentException(
                'unreadable',
                statusCode: 200,
              ),
          who: 'Cy',
          copy: _attendeeWriteFailedUnexpectedCopy,
          tone: BgeBannerTone.error,
          rereads: true,
        ),
      ];

      for (final end in ends) {
        testWidgets('${end.name}: ${end.copy}', (tester) async {
          final remote = answering(added: end.answer);
          await showRoster(tester, viewed(), remote);
          final reads = remote.detailRequests.length;

          tester
              .element(find.byKey(EventDetailScreen.attendeesKey))
              .read<EventActionsBloc>()
              .add(
                EventAttendeeAddRequested(
                  'e-1',
                  'user-att-9',
                  EventRole.participant,
                  name: end.who,
                ),
              );
          await settle(tester);

          expect(remote.adds, [
            (eventId: 'e-1', userId: 'user-att-9', role: EventRole.participant),
          ]);
          expect(inOutcome(end.copy), findsOneWidget);
          expect(toneOf(tester), end.tone);
          expect(
            remote.detailRequests,
            hasLength(reads + (end.rereads ? 1 : 0)),
          );
        });
      }

      testWidgets('dropped: $_rosterChangedCopy', (tester) async {
        final remote = answering();
        await showRoster(tester, viewed(), remote);
        final reads = remote.detailRequests.length;

        tester
            .element(find.byKey(EventDetailScreen.attendeesKey))
            .read<EventActionsBloc>()
            .add(
              const EventWriteDropped.attendee(
                EventAttendeeWrite.add,
                name: 'Cy',
              ),
            );
        await settle(tester);

        expect(remote.adds, isEmpty);
        expect(inOutcome(_rosterChangedCopy), findsOneWidget);
        expect(toneOf(tester), BgeBannerTone.warning);
        expect(remote.detailRequests, hasLength(reads));
      });
    });
  });

  group('the clock (#502, #655)', () {
    /// What the screen's clock reads, which each test moves on.
    late DateTime clock;

    setUpAll(() {
      registerFallbackValue(confirmed('o-fallback', kItemInstant));
    });

    setUp(() {
      clock = now;
      when(() => repository.cacheOccurrence(any()))
          .thenAnswer((_) async => true);
    });

    void back(BuildContext _) {}

    /// Date `o-1` of `e-1`, [status], from [start] to [end] after the clock
    /// as it stands when the test begins.
    EventOccurrence date({
      required Duration start,
      required Duration end,
      OccurrenceStatus status = OccurrenceStatus.proposed,
    }) => confirmed(
      'o-1',
      now.add(start),
      end: now.add(end),
    ).copyWith(eventId: 'e-1', status: status);

    /// Event `e-1`, a Scheduled [schedulingMode] event the viewer hosts,
    /// holding [occurrence].
    EventDetail hosted(
      EventOccurrence occurrence, {
      EventSchedulingMode schedulingMode = EventSchedulingMode.poll,
    }) => _detail(
      event: _event(schedulingMode: schedulingMode),
      occurrences: [occurrence],
      attendance: _attending(EventRole.host),
    );

    /// A server whose reads serve [detail], whose poll reads answer that
    /// nobody has answered, and whose date writes answer with the date they
    /// named.
    FakeEventRemote serving(EventDetail detail) => FakeEventRemote.detail(
      (_) => detail.snapshot,
      deleted: (_) {},
      summary: (_) => const AvailabilitySummary(occurrences: []),
      dateWritten: (_) => detail.snapshot.occurrences.single,
    );

    /// Shows [detail] from [remote], on the test's clock.
    Future<void> showClocked(
      WidgetTester tester,
      EventDetail detail,
      FakeEventRemote remote,
    ) async {
      await show(
        tester,
        detail,
        remote: remote,
        onBack: back,
        clock: () => clock,
      );
      // The poll's read.
      await settle(tester);
    }

    /// Moves the clock on by [by], and lets the time pass for the screen's
    /// timer too.
    Future<void> elapse(WidgetTester tester, Duration by) async {
      clock = clock.add(by);
      await tester.pump(by);
    }

    Future<void> toggle(WidgetTester tester, Finder button) async {
      await tester.tap(button);
      await animate(tester);
    }

    Finder dateMenu() => find.byKey(EventDetailScreen.dateMenuKey('o-1'));

    /// The open menu's items, by label, in order.
    List<String> offered(WidgetTester tester) => [
      for (final item in tester.widgetList<MenuItemButton>(
        find.byType(MenuItemButton),
      ))
        (item.child! as BgeOnlineOnlyLabel).label,
    ];

    testWidgets('a scheduled event reads Ongoing at its start and Completed '
        'at its end, with no read', (tester) async {
      final detail = hosted(
        date(
          start: const Duration(hours: 1),
          end: const Duration(hours: 3),
          status: OccurrenceStatus.confirmed,
        ),
        schedulingMode: EventSchedulingMode.fixed,
      );
      final remote = serving(detail);
      await showClocked(tester, detail, remote);

      expect(find.text('Strategy night · Scheduled'), findsOneWidget);
      await toggle(tester, find.byKey(EventDetailScreen.moreActionsKey));
      expect(offered(tester), ['Cancel event', 'Delete event']);
      await toggle(tester, find.byKey(EventDetailScreen.moreActionsKey));

      await elapse(tester, const Duration(hours: 1));
      expect(find.text('Strategy night · Happening now'), findsOneWidget);
      expect(find.text('Strategy night · Scheduled'), findsNothing);

      await elapse(tester, const Duration(hours: 2));
      expect(find.text('Strategy night · Completed'), findsOneWidget);
      // A host may archive an event that has ended (#502).
      await toggle(tester, find.byKey(EventDetailScreen.moreActionsKey));
      expect(offered(tester), [
        'Cancel event',
        'Archive event',
        'Delete event',
      ]);
      expect(
        tester
            .widget<MenuItemButton>(find.byKey(EventDetailScreen.archiveKey))
            .onPressed,
        isNotNull,
      );
      // The open's read alone: the clock moved the page on.
      expect(remote.detailRequests, ['e-1']);
    });

    testWidgets('a date a sync brings while open moves the page on at its '
        'start', (tester) async {
      final undated = _detail(
        event: _event(),
        attendance: _attending(EventRole.host),
      );
      await showClocked(tester, undated, serving(undated));
      // Nothing to wait for.
      expect(find.text('Strategy night · Planning'), findsOneWidget);

      cache.add(
        hosted(
          date(
            start: const Duration(hours: 1),
            end: const Duration(hours: 3),
            status: OccurrenceStatus.confirmed,
          ),
          schedulingMode: EventSchedulingMode.fixed,
        ),
      );
      await settle(tester);
      expect(find.text('Strategy night · Scheduled'), findsOneWidget);

      await elapse(tester, const Duration(hours: 1));
      expect(find.text('Strategy night · Happening now'), findsOneWidget);
    });

    testWidgets('a Proposed date that passes while open stops offering '
        'Confirm and Decline', (tester) async {
      final detail = hosted(
        date(start: const Duration(hours: 1), end: const Duration(hours: 2)),
      );
      final remote = serving(detail);
      await showClocked(tester, detail, remote);

      expect(inSection(EventDetailScreen.datesKey, 'Proposed'), findsOneWidget);
      await toggle(tester, dateMenu());
      expect(offered(tester), ['Confirm', 'Edit', 'Decline', 'Remove']);
      await toggle(tester, dateMenu());

      // Just past its end: a date ending at an instant hasn't passed at it.
      await elapse(tester, const Duration(hours: 2, microseconds: 1));

      expect(
        inSection(EventDetailScreen.datesKey, 'Date passed'),
        findsOneWidget,
      );
      expect(inSection(EventDetailScreen.datesKey, 'Proposed'), findsNothing);
      await toggle(tester, dateMenu());
      expect(offered(tester), ['Edit', 'Remove']);
      expect(remote.detailRequests, ['e-1']);
    });

    testWidgets('a confirm whose date passed while its dialog was open sends '
        'nothing, and says the date changed', (tester) async {
      // The server still takes a confirm on a passed date (backend#1005).
      final detail = hosted(
        date(start: const Duration(hours: 1), end: const Duration(hours: 2)),
      );
      final remote = serving(detail);
      await showClocked(tester, detail, remote);
      await toggle(tester, dateMenu());
      await tester.tap(
        find.byKey(
          EventDetailScreen.dateActionKey('o-1', EventAction.confirmDate),
        ),
      );
      await animate(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      await elapse(tester, const Duration(hours: 3));
      await tester.tap(find.byKey(EventDateDialogKeys.submit));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.dateRequests, isEmpty);
      expect(inOutcome(_dateChangedCopy), findsOneWidget);
    });

    testWidgets('a confirm whose date a sync confirmed while its dialog was '
        'open sends nothing, and says the date changed', (tester) async {
      // Its dialog checks the date again before it sends, so the confirm is
      // dropped rather than sent to come back 400.
      final proposed = hosted(
        date(start: const Duration(hours: 1), end: const Duration(hours: 2)),
      );
      final confirmedElsewhere = hosted(
        date(
          start: const Duration(hours: 1),
          end: const Duration(hours: 2),
          status: OccurrenceStatus.confirmed,
        ),
      );
      var served = proposed;
      final remote = FakeEventRemote.detail(
        (_) => served.snapshot,
        deleted: (_) {},
        summary: (_) => const AvailabilitySummary(occurrences: []),
        dateWritten: (_) => served.snapshot.occurrences.single,
      );
      await showClocked(tester, proposed, remote);
      await toggle(tester, dateMenu());
      await tester.tap(
        find.byKey(
          EventDetailScreen.dateActionKey('o-1', EventAction.confirmDate),
        ),
      );
      await animate(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      // Confirmed on another device. The server now serves it so, and a
      // read or a sync caches it under the dialog.
      served = confirmedElsewhere;
      cache.add(confirmedElsewhere);
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.byKey(EventDateDialogKeys.submit));
      await animate(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.dateRequests, isEmpty);
      expect(inOutcome(_dateChangedCopy), findsOneWidget);
      expect(
        inSection(EventDetailScreen.datesKey, 'Confirmed'),
        findsOneWidget,
      );
    });

    testWidgets('the timer stops when the screen goes', (tester) async {
      final detail = hosted(
        date(
          start: const Duration(hours: 1),
          end: const Duration(hours: 3),
          status: OccurrenceStatus.confirmed,
        ),
        schedulingMode: EventSchedulingMode.fixed,
      );
      await showClocked(tester, detail, serving(detail));
      expect(find.text('Strategy night · Scheduled'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      // Past both of the event's boundaries. A timer left running would
      // build a page that has gone, and the binding fails a test that ends
      // with one pending.
      await elapse(tester, const Duration(hours: 4));

      expect(find.byType(EventDetailScreen), findsNothing);
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
          summary: (_) => const AvailabilitySummary(
            occurrences: [
              OccurrenceAvailability(
                occurrenceId: 'o-1',
                available: 1,
                maybe: 0,
                unavailable: 0,
                voters: [
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
      // each date's three chips, not once a chip. Who's coming says it once
      // more, under the viewer's own answer (#508).
      expect(
        find.descendant(
          of: find.byKey(EventDetailScreen.datesKey),
          matching: reason(),
        ),
        findsNWidgets(4),
      );
      expect(
        find.descendant(
          of: find.byKey(EventDetailScreen.attendeesKey),
          matching: reason(),
        ),
        findsOneWidget,
      );

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

  // Each state the screen draws, in #50's four cells: the short centred
  // pages, the event as its host and as a guest see it, its banners, a write
  // in flight, offline, and each menu and dialog the screen opens.
  group('accessibility audit', () {
    const available = AvailabilityResponse.available;
    const maybe = AvailabilityResponse.maybe;
    const notGoing = EventParticipationStatus.notAttending;

    late List<Completer<EventSnapshot>> reads;
    late ValueNotifier<bool> offline;

    setUp(() {
      reads = [];
      offline = ValueNotifier(true);
    });

    tearDown(() => offline.dispose());

    /// Date [id] of `e-1`, Proposed unless [status] says otherwise, on the
    /// evening of November [day].
    EventOccurrence date(
      String id, {
      int day = 6,
      int sortOrder = 0,
      OccurrenceStatus status = OccurrenceStatus.proposed,
      DateTime? end,
    }) => confirmed(
      id,
      DateTime(2026, 11, day, 19),
      end: end,
      sortOrder: sortOrder,
    ).copyWith(eventId: 'e-1', status: status);

    /// The viewer's own row on `e-1`, `att-me`, named Me, holding [role] and
    /// going.
    EventAttendee me(EventRole role) =>
        attendance(EventParticipationStatus.attending)
            .copyWith(eventId: 'e-1', displayName: 'Me', role: role);

    /// A poll in the Smiths' household with every header line, two proposed
    /// dates and a confirmed one with an end, and someone in each answer's
    /// group, as [viewer] sees it. A null [viewer] isn't on the roster.
    EventDetail viewed(EventAttendee? viewer) => _detail(
      event: _event(
        schedulingMode: EventSchedulingMode.poll,
        householdId: 'h-1',
        location: 'The back room',
        url: 'https://example.com/catan-night',
        description: 'Bring snacks.',
      ),
      occurrences: [
        date('o-1'),
        date('o-2', day: 13, sortOrder: 1),
        date(
          'o-3',
          day: 20,
          sortOrder: 2,
          status: OccurrenceStatus.confirmed,
          end: DateTime(2026, 11, 20, 23),
        ),
      ],
      attendees: [
        ?viewer,
        _member('att-2', displayName: 'Ada'),
        _member(
          'att-3',
          displayName: 'Bo',
          status: EventParticipationStatus.maybe,
        ),
        _guest('att-4', 'Cy'),
        _member('att-5', displayName: 'Di', status: notGoing),
      ],
      attendance: viewer,
    );

    // The host has the most controls. A guest answers the invitation and
    // the poll, and has none of the host's. A spectator answers the
    // invitation alone, and a viewer not on the roster has no control at
    // all: the fewest.
    final host = viewed(me(EventRole.host));
    final guest = viewed(me(EventRole.guest));
    final spectator = viewed(me(EventRole.spectator));
    final offRoster = viewed(null);

    // The host alone on the roster. Offline changes no roster row, and with
    // the whole roster and the reason lines the page runs past
    // `useWholePage`'s view at 320dp × 2.0.
    final hostAlone = EventDetail(
      snapshot: host.snapshot.copyWith(attendees: [me(EventRole.host)]),
      attendance: host.attendance,
    );

    AvailabilityVoter voter(String id, AvailabilityResponse response) =>
        AvailabilityVoter(attendeeId: id, response: response, eligible: true);

    /// The poll as the server counts it: o-1 leads on the viewer's answer
    /// and Ada's, and Ada is a maybe on o-2.
    AvailabilitySummary answers(String _) => AvailabilitySummary(
      occurrences: [
        OccurrenceAvailability(
          occurrenceId: 'o-1',
          available: 2,
          maybe: 0,
          unavailable: 0,
          voters: [voter('att-me', available), voter('att-2', available)],
        ),
        OccurrenceAvailability(
          occurrenceId: 'o-2',
          available: 0,
          maybe: 1,
          unavailable: 0,
          voters: [voter('att-2', maybe)],
        ),
      ],
    );

    /// A server whose reads answer at once, whose poll reads answer from
    /// [summary] ([answers] by default), and whose deletes, votes and
    /// answers to the invitation answer from [deleted], [voted] and [rsvp].
    FakeEventRemote serving({
      FutureOr<AvailabilitySummary> Function(String eventId)? summary,
      FutureOr<void> Function(String id)? deleted,
      FutureOr<AvailabilityVote> Function(EventVoteRequest request)? voted,
      FutureOr<EventAttendee> Function(RsvpRequest request)? rsvp,
    }) => FakeEventRemote.detail(
      (_) => host.snapshot,
      summary: summary ?? answers,
      deleted: deleted ?? (_) {},
      voted: voted ?? (_) => throw UnimplementedError('no vote is sent'),
      rsvp: rsvp ?? (_) => throw UnimplementedError('no answer is sent'),
    );

    /// The screen with a server and a way back, as the app opens it, so the
    /// viewer's role alone decides what it offers. A new server each cell.
    Widget Function(ThemeData) screen({
      FakeEventRemote Function()? remote,
      bool isOffline = false,
    }) =>
        (theme) => harness(
          theme: theme,
          remote: (remote ?? serving)(),
          households: Stream.value([_household('h-1', 'The Smiths')]),
          onBack: (_) {},
          onWhoAnswered: (_) {},
          onAddAttendee: (_, _) async => null,
          offline: isOffline ? offline : null,
        );

    /// Shows [detail], and lets the reads it starts end: the detail's and
    /// the poll's.
    Future<void> showing(WidgetTester tester, EventDetail detail) async {
      cache.add(detail);
      await tester.pumpAndSettle();
      expect(find.text('Catan night'), findsOneWidget);
    }

    void expectHostsControls() {
      for (final key in [
        EventDetailScreen.moreActionsKey,
        EventDetailScreen.dateMenuKey('o-1'),
        EventDetailScreen.dateMenuKey('o-3'),
        EventDetailScreen.whoAnsweredKey,
        EventDetailScreen.confirmLeaderKey('o-1'),
        EventDetailScreen.pollAnswerKey('o-2', available),
        EventDetailScreen.addDateKey,
        EventDetailScreen.rsvpAnswerKey(notGoing),
        EventDetailScreen.rsvpNoteKey,
        EventDetailScreen.addAttendeeKey,
      ]) {
        expect(find.byKey(key), findsOneWidget, reason: '$key');
      }
    }

    /// Scrolls [finder] into view and taps it, then lets what it opens
    /// finish moving. A menu item's press lands after the frame its tap
    /// ends in, which the settle covers.
    Future<void> press(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Future<void> openMenu(WidgetTester tester) async {
      await press(tester, find.byKey(EventDetailScreen.moreActionsKey));
      // The last item is on screen, not merely built in a panel that
      // scrolls.
      expect(
        find.byKey(EventDetailScreen.deleteKey).hitTestable(),
        findsOneWidget,
      );
    }

    Future<void> openDeleteDialog(WidgetTester tester) async {
      await openMenu(tester);
      await press(tester, find.byKey(EventDetailScreen.deleteKey));
      // Three answers, since the menu offers Cancel too (#502).
      expect(find.byKey(EventDetailScreen.cancelInsteadKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.deleteConfirmKey), findsOneWidget);
    }

    Future<void> openCancelDialog(WidgetTester tester) async {
      await openMenu(tester);
      await press(tester, find.byKey(EventDetailScreen.cancelKey));
      expect(find.byKey(EventDetailScreen.cancelReasonKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.cancelConfirmKey), findsOneWidget);
    }

    Future<void> openNotGoingDialog(WidgetTester tester) async {
      await press(
        tester,
        find.byKey(EventDetailScreen.rsvpAnswerKey(notGoing)),
      );
      expect(
        find.byKey(EventDetailScreen.rsvpNotGoingConfirmKey),
        findsOneWidget,
      );
    }

    /// Not going for Ada, from her menu on the roster (#510).
    Future<void> openAttendeeNotGoingDialog(WidgetTester tester) async {
      await press(
        tester,
        find.byKey(EventDetailScreen.attendeeMenuKey('att-2')),
      );
      await press(
        tester,
        find.byKey(EventDetailScreen.attendeeActionKey('att-2', 'notGoing')),
      );
      expect(
        find.byKey(EventDetailScreen.attendeeNotGoingConfirmKey),
        findsOneWidget,
      );
    }

    /// Remove, from Ada's menu on the roster (#510).
    Future<void> openRemoveAttendeeDialog(WidgetTester tester) async {
      await press(
        tester,
        find.byKey(EventDetailScreen.attendeeMenuKey('att-2')),
      );
      await press(
        tester,
        find.byKey(EventDetailScreen.attendeeActionKey('att-2', 'remove')),
      );
      expect(
        find.byKey(EventDetailScreen.attendeeRemoveConfirmKey),
        findsOneWidget,
      );
    }

    /// Confirm this date, under the leader: the dialog offers to decline
    /// o-2 with it (#507).
    Future<void> openConfirmDateDialog(WidgetTester tester) async {
      await press(
        tester,
        find.byKey(EventDetailScreen.confirmLeaderKey('o-1')),
      );
      expect(find.byKey(EventDetailScreen.declineOthersKey), findsOneWidget);
    }

    /// Edit, on the confirmed date with an end: its note, and the end's
    /// clear button.
    Future<void> openEditDateDialog(WidgetTester tester) async {
      await press(tester, find.byKey(EventDetailScreen.dateMenuKey('o-3')));
      await press(
        tester,
        find.byKey(
          EventDetailScreen.dateActionKey('o-3', EventAction.editDate),
        ),
      );
      expect(find.byKey(EventDateDialogKeys.clearEnd), findsOneWidget);
      expect(
        find.text("Attendees aren't told when a confirmed date changes."),
        findsOneWidget,
      );
    }

    /// The host's page in a view tall enough to hold it whole, then the
    /// dialog [open] opens, which no longer scrolls either (#50). Its title
    /// and content scroll, and its buttons stay put under them.
    Future<void> openWhole(
      WidgetTester tester,
      Future<void> Function(WidgetTester tester) open,
    ) async {
      await showing(tester, host);
      await useWholePage(tester);
      expectWholePage(tester);
      await open(tester);
      expectWholePage(tester, within: find.byType(AlertDialog));
    }

    auditScreen(
      'loading',
      build: (theme) => harness(theme: theme),
      settle: false,
      arrange: (tester) async {
        expect(find.byKey(EventDetailScreen.loadingKey), findsOneWidget);
      },
    );

    auditScreen(
      'not found',
      build: (theme) => harness(
        theme: theme,
        remote: FakeEventRemote.detail(
          (_) => throw const EventRemoteNotFoundException('gone'),
        ),
        onBack: (_) {},
      ),
      arrange: (tester) async {
        cache.add(_detail());
        await settle(tester);
        expect(find.byKey(EventDetailScreen.notFoundKey), findsOneWidget);
        expect(find.byKey(EventDetailScreen.notFoundBackKey), findsOneWidget);
      },
    );

    Future<void> failFirstRead(WidgetTester tester) async {
      cache.add(null);
      await settle(tester);
      reads.single.completeError(_offline);
      await settle(tester);
      expect(find.byKey(EventDetailScreen.errorKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.errorRetryKey), findsOneWidget);
    }

    auditScreen(
      'error, with retry',
      build: (theme) => harness(theme: theme, remote: scripted(reads)),
      arrange: failFirstRead,
    );

    // At 320dp × 2.0 the retry is below the fold.
    auditScreen(
      'error, with retry, scrolled to the end',
      build: (theme) => harness(theme: theme, remote: scripted(reads)),
      arrange: (tester) async {
        await failFirstRead(tester);
        await scrollPageToEnd(tester);
      },
    );

    // The retry stays up, saying it is running, and its spinner never
    // settles. Scrolled first, since the scroll's own settle would wait on
    // the spinner.
    auditScreen(
      'error, retrying, scrolled to the end',
      build: (theme) => harness(theme: theme, remote: scripted(reads)),
      settle: false,
      arrange: (tester) async {
        await failFirstRead(tester);
        await scrollPageToEnd(tester);
        blocOf(tester).add(const EventDetailRetryRequested());
        await settle(tester);
        expect(reads, hasLength(2));
        expect(find.text(_inProgressCopy), findsOneWidget);
        final view = tester.view.physicalSize / tester.view.devicePixelRatio;
        expect(
          tester.getRect(find.byKey(EventDetailScreen.errorRetryKey)).bottom,
          lessThanOrEqualTo(view.height),
        );
      },
    );

    // No server to read again: the failure alone, as a plain banner.
    auditScreen(
      'error, without retry',
      build: (theme) => harness(theme: theme),
      arrange: (tester) async {
        cache.addError(StateError('no authenticated user'));
        await settle(tester);
        expect(find.byKey(EventDetailScreen.errorKey), findsOneWidget);
        expect(find.byKey(EventDetailScreen.errorRetryKey), findsNothing);
      },
    );

    // The menu, each date's menu, the poll's chips and Confirm this date,
    // Add a date and the host's own answer.
    auditScreen(
      'ready as host',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        expectHostsControls();
      },
    );

    // At 320dp × 2.0 the page is some 5400dp long, and its top and its end
    // leave the dates, the poll and the host's answer between them. At 390dp
    // × 1.0 everything under the first date is below the fold, and the end
    // isn't scrolled to there. This audits the page in a view tall enough
    // to hold it whole (#50). It stands for the end too: scrolled there at
    // 320dp × 2.0, the page leaves a roster row's menu button (#510) a
    // sliver high under the top edge, which the tap-target check fails at
    // its clipped size.
    auditScreen(
      'ready as host, whole page',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        await useWholePage(tester);
        expectHostsControls();
        // Everyone else's row has a menu: the host reaches every role.
        for (final id in ['att-2', 'att-3', 'att-4', 'att-5']) {
          expect(
            find.byKey(EventDetailScreen.attendeeMenuKey(id)),
            findsOneWidget,
            reason: id,
          );
        }
        expectWholePage(tester);
      },
    );

    /// What no role but the host's is offered.
    void expectNoneOfTheHosts() {
      for (final key in [
        EventDetailScreen.moreActionsKey,
        EventDetailScreen.dateMenuKey('o-1'),
        EventDetailScreen.dateMenuKey('o-3'),
        EventDetailScreen.confirmLeaderKey('o-1'),
        EventDetailScreen.addDateKey,
        EventDetailScreen.addAttendeeKey,
      ]) {
        expect(find.byKey(key), findsNothing, reason: '$key');
      }
    }

    // A guest answers the invitation and the poll, and has no menu, no
    // date's menu, no Add a date and no Confirm this date. A whole page, as
    // the host's: its top holds the header alone at 320dp × 2.0.
    auditScreen(
      'ready as guest, whole page',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, guest);
        await useWholePage(tester);
        expectNoneOfTheHosts();
        expect(
          find.byKey(EventDetailScreen.pollAnswerKey('o-2', available)),
          findsOneWidget,
        );
        expect(
          find.byKey(EventDetailScreen.rsvpAnswerKey(notGoing)),
          findsOneWidget,
        );
        expectWholePage(tester);
      },
    );

    // A spectator answers the invitation and can't vote: the answer chips
    // over dates that show the poll's tallies alone, which no other role's
    // page draws. A whole page, as the guest's.
    auditScreen(
      'ready as spectator, whole page',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, spectator);
        await useWholePage(tester);
        expectNoneOfTheHosts();
        expect(
          find.byKey(EventDetailScreen.pollAnswerKey('o-1', available)),
          findsNothing,
        );
        expect(
          find.byKey(EventDetailScreen.pollTalliesKey('o-1')),
          findsOneWidget,
        );
        expect(
          find.byKey(EventDetailScreen.rsvpAnswerKey(notGoing)),
          findsOneWidget,
        );
        expect(find.byKey(EventDetailScreen.rsvpNoteKey), findsOneWidget);
        expect(
          textOf(tester, find.byKey(EventDetailScreen.roleKey)),
          "You're a spectator at this event",
        );
        expectWholePage(tester);
      },
    );

    // A reader not on the roster, such as a friend who sees the event: the
    // fewest controls, Who answered alone. No answer to give, no vote and no
    // role line. A whole page, as the guest's.
    auditScreen(
      'ready as a viewer off the roster, whole page',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, offRoster);
        await useWholePage(tester);
        expectNoneOfTheHosts();
        for (final key in [
          EventDetailScreen.pollAnswerKey('o-1', available),
          EventDetailScreen.rsvpAnswerKey(notGoing),
          EventDetailScreen.rsvpNoteKey,
          EventDetailScreen.roleKey,
        ]) {
          expect(find.byKey(key), findsNothing, reason: '$key');
        }
        expect(
          find.byKey(EventDetailScreen.pollTalliesKey('o-1')),
          findsOneWidget,
        );
        expect(find.byKey(EventDetailScreen.whoAnsweredKey), findsOneWidget);
        expectWholePage(tester);
      },
    );

    Future<void> failRefresh(WidgetTester tester) async {
      cache.add(_detail(occurrences: [_ahead()]));
      await settle(tester);
      reads.single.completeError(_offline);
      await settle(tester);
      expect(find.byKey(EventDetailScreen.refreshBannerKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.refreshRetryKey), findsOneWidget);
    }

    auditScreen(
      'refresh failed',
      build: (theme) => harness(theme: theme, remote: scripted(reads)),
      arrange: failRefresh,
    );

    // The retry's read never ends, so its spinner keeps going.
    auditScreen(
      'refreshing',
      build: (theme) => harness(theme: theme, remote: scripted(reads)),
      settle: false,
      arrange: (tester) async {
        await failRefresh(tester);
        await tester.tap(find.byKey(EventDetailScreen.refreshRetryKey));
        await settle(tester);
        // The banner's copy and its button's label.
        expect(find.text(_inProgressCopy), findsNWidgets(2));
      },
    );

    // A refused delete: the warning banner over the event, with Dismiss.
    auditScreen(
      'action outcome',
      build: screen(
        remote: () => serving(
          deleted: (_) =>
              throw const EventWriteRefusedException('no', statusCode: 403),
        ),
      ),
      arrange: (tester) async {
        await showing(tester, host);
        await openDeleteDialog(tester);
        await press(tester, find.byKey(EventDetailScreen.deleteConfirmKey));
        expect(inOutcome(_refusedCopy), findsOneWidget);
        expect(inOutcome('Dismiss'), findsOneWidget);
      },
    );

    // A vote whose answer was lost: the error banner, over the event. Sent
    // as its chip sends it, which at 320dp × 2.0 is below the fold.
    auditScreen(
      'poll outcome',
      build: screen(remote: () => serving(voted: (_) => throw _offline)),
      arrange: (tester) async {
        await showing(tester, guest);
        tester
            .element(find.byKey(EventDetailScreen.datesKey))
            .read<EventPollBloc>()
            .add(const EventPollVoted('e-1', 'o-2', available));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(EventDetailScreen.pollOutcomeKey),
            matching: find.text(_pollFailedCopy),
          ),
          findsOneWidget,
        );
      },
    );

    // The poll's answers couldn't be read: its warning banner and retry,
    // above the dates, which still show. In the middle of the page, so a
    // whole page.
    auditScreen(
      'poll failed, whole page',
      build: screen(remote: () => serving(summary: (_) => throw _offline)),
      arrange: (tester) async {
        await showing(tester, host);
        await useWholePage(tester);
        expect(find.text(_pollLoadFailedCopy), findsOneWidget);
        expect(find.byKey(EventDetailScreen.pollRetryKey), findsOneWidget);
        expectWholePage(tester);
      },
    );

    // The host's Maybe is out and never answered: its chip spins, and the
    // page's other controls wait for it. The view is made whole first, since
    // its settle would wait on the spinner.
    auditScreen(
      'an answer in flight, whole page',
      build: screen(
        remote: () => serving(rsvp: (_) => Completer<EventAttendee>().future),
      ),
      settle: false,
      // Add a date, Going, Not going and Add a note are disabled while it is
      // out, and a disabled control's dimmed label is exempt (WCAG 1.4.3).
      // Each sits in `BgeOnlineOnly`'s merge, whose own node says disabled
      // only while offline, and that is what the guideline reads, so online
      // it measures them all the same (#50).
      textContrast: false,
      arrange: (tester) async {
        await showing(tester, host);
        await useWholePage(tester);
        await tester.tap(
          find.byKey(
            EventDetailScreen.rsvpAnswerKey(EventParticipationStatus.maybe),
          ),
        );
        await settle(tester);
        expect(
          find.descendant(
            of: find.byKey(
              EventDetailScreen.rsvpAnswerKey(EventParticipationStatus.maybe),
            ),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<ButtonStyleButton>(
                find.byKey(EventDetailScreen.addDateKey),
              )
              .onPressed,
          isNull,
        );
        expectWholePage(tester);
      },
    );

    // Every control that writes is disabled and says why. They sit down the
    // page, so a whole page.
    auditScreen(
      'offline, whole page',
      build: screen(isOffline: true),
      arrange: (tester) async {
        await showing(tester, hostAlone);
        await useWholePage(tester);
        expectHostsControls();
        expect(
          tester
              .widget<ButtonStyleButton>(
                find.byKey(EventDetailScreen.addDateKey),
              )
              .onPressed,
          isNull,
        );
        // Under Add a date, Confirm this date and each proposed date's
        // chips, and under the host's answer and Add people.
        expect(
          inSection(EventDetailScreen.datesKey, _onlineOnlyCopy),
          findsNWidgets(4),
        );
        expect(
          inSection(EventDetailScreen.attendeesKey, _onlineOnlyCopy),
          findsNWidgets(2),
        );
        expect(
          tester
              .widget<ButtonStyleButton>(
                find.byKey(EventDetailScreen.addAttendeeKey),
              )
              .onPressed,
          isNull,
        );
        expectWholePage(tester);
      },
    );

    auditScreen(
      'actions menu open',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        await openMenu(tester);
        expect(find.byKey(EventDetailScreen.cancelKey), findsOneWidget);
      },
    );

    // The items stay, disabled, each saying why.
    auditScreen(
      'actions menu open, offline',
      build: screen(isOffline: true),
      arrange: (tester) async {
        await showing(tester, host);
        await openMenu(tester);
        expect(
          tester
              .widget<MenuItemButton>(find.byKey(EventDetailScreen.deleteKey))
              .onPressed,
          isNull,
        );
      },
    );

    auditScreen(
      'date menu open',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        await press(tester, find.byKey(EventDetailScreen.dateMenuKey('o-1')));
        expect(
          find
              .byKey(
                EventDetailScreen.dateActionKey('o-1', EventAction.removeDate),
              )
              .hitTestable(),
          findsOneWidget,
        );
      },
    );

    // Cy's, who hasn't answered, so every item is enabled and measured (#510).
    // A row's current answer is disabled in its menu, and a disabled
    // control's dimmed label is exempt (WCAG 1.4.3).
    auditScreen(
      'attendee menu open',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        // Scrolled only until Cy's row shows, as a user reaching for it
        // scrolls. Scrolled to its top edge, the page stops at its end,
        // where at 390dp the host's answer chips sit half under the app bar,
        // and Flutter's tap-target check fails them at their clipped size,
        // a limit of the tool (`docs/design/ACCESSIBILITY_AUDIT.md` §3).
        final menu = find.byKey(EventDetailScreen.attendeeMenuKey('att-4'));
        await Scrollable.ensureVisible(
          tester.element(menu),
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
        await tester.pumpAndSettle();
        await tester.tap(menu);
        await tester.pumpAndSettle();
        expect(
          find
              .byKey(EventDetailScreen.attendeeActionKey('att-4', 'remove'))
              .hitTestable(),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'remove attendee dialog',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        await openRemoveAttendeeDialog(tester);
      },
    );

    auditScreen(
      'remove attendee dialog, whole page',
      build: screen(),
      arrange: (tester) => openWhole(tester, openRemoveAttendeeDialog),
    );

    auditScreen(
      'attendee not going dialog',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        await openAttendeeNotGoingDialog(tester);
      },
    );

    auditScreen(
      'attendee not going dialog, whole page',
      build: screen(),
      arrange: (tester) => openWhole(tester, openAttendeeNotGoingDialog),
    );

    auditScreen(
      'delete dialog',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        await openDeleteDialog(tester);
      },
    );

    // At 320dp × 2.0 each of these dialogs' title and body run past its
    // fold, over buttons that stay put. Each is audited again in a view
    // tall enough to hold it whole (#50).
    auditScreen(
      'delete dialog, whole page',
      build: screen(),
      arrange: (tester) => openWhole(tester, openDeleteDialog),
    );

    auditScreen(
      'cancel dialog',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        await openCancelDialog(tester);
      },
    );

    auditScreen(
      'cancel dialog, whole page',
      build: screen(),
      arrange: (tester) => openWhole(tester, openCancelDialog),
    );

    auditScreen(
      'not going dialog',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        await openNotGoingDialog(tester);
      },
    );

    auditScreen(
      'not going dialog, whole page',
      build: screen(),
      arrange: (tester) => openWhole(tester, openNotGoingDialog),
    );

    auditScreen(
      'note dialog',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        await press(tester, find.byKey(EventDetailScreen.rsvpNoteKey));
        expect(find.byKey(EventDetailScreen.rsvpNoteFieldKey), findsOneWidget);
        expect(find.byKey(EventDetailScreen.rsvpNoteSaveKey), findsOneWidget);
      },
    );

    auditScreen(
      'add date dialog',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        await press(tester, find.byKey(EventDetailScreen.addDateKey));
        expect(find.byKey(EventDateDialogKeys.start), findsOneWidget);
        expect(find.byKey(EventDateDialogKeys.submit), findsOneWidget);
      },
    );

    auditScreen(
      'confirm date dialog',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        await openConfirmDateDialog(tester);
      },
    );

    auditScreen(
      'confirm date dialog, whole page',
      build: screen(),
      arrange: (tester) => openWhole(tester, openConfirmDateDialog),
    );

    auditScreen(
      'edit date dialog',
      build: screen(),
      arrange: (tester) async {
        await showing(tester, host);
        await openEditDateDialog(tester);
      },
    );

    auditScreen(
      'edit date dialog, whole page',
      build: screen(),
      arrange: (tester) => openWhole(tester, openEditDateDialog),
    );
  });
}
