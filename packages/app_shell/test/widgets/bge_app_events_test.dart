import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:events/events.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:go_router/go_router.dart';
import 'package:household/household.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_browser_history.dart';
import '../support/navigation.dart';
import '../support/no_later_recoveries.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    with NoLaterRecoveries
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockEventRepository extends Mock implements EventRepository {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockEventRemote extends Mock implements EventRemoteDataSource {}

class _MockUserRemote extends Mock implements UserRemoteDataSource {}

/// A collection cache holding [items], whose watch stays open, as Drift's
/// does. Nothing else of it is read here.
class _Collection implements GameCollectionRepository {
  _Collection(this.items);

  final List<GameCollectionListItem> items;

  @override
  Stream<List<GameCollectionListItem>> watchCollectionListItems() =>
      Stream.multi((stream) => stream.add(items));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Answers every send as delivered under the server's [eventId], as the
/// real sender does once the server has made the event and the cache holds
/// it.
class _DeliveringSender implements SyncOperationSender {
  _DeliveringSender(this.eventId);

  final String eventId;

  /// When set, delivery waits for it: the server has yet to answer.
  Completer<void>? held;

  @override
  Future<SyncDelivery> deliver(String entryId, SyncOperation operation) async {
    await held?.future;
    return SyncDelivered(eventId: eventId);
  }

  @override
  Future<SyncDelivery> deliverEntry(SyncQueueEntry entry) =>
      deliver(entry.id, entry.operation);
}

/// A games server whose every game reads as one of its own, as the game's
/// page reads it (#957). Nothing else of it is read here.
class _GamesRemote implements GamesRemoteDataSource {
  @override
  Future<GameWithPlatformGames> fetchGame(String id) async => (
    game: Game(
      id: id,
      title: 'Azul',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ),
    platformGames: const <PlatformGame>[],
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A user scope that holds whoever the shell last activated.
class _UserSessionScope implements UserSessionScope {
  @override
  String? activeUserId;

  @override
  Future<void> activate(String userId) async => activeUserId = userId;

  @override
  Future<void> deactivate() async => activeUserId = null;
}

/// A session guard that gives [answer] and records whom it was asked about.
class _RecordingGuard implements SessionIdentityGuard {
  _RecordingGuard(this.answer);

  final SessionConfirmation answer;
  final asked = <String>[];

  @override
  Future<SessionConfirmation> confirm(String userId) async {
    asked.add(userId);
    return answer;
  }
}

/// Counts passes without running any. What these tests check is who calls
/// the seam, not what it holds.
class _RecordingRehydrator implements SessionRehydrator {
  int passes = 0;

  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) {}

  @override
  Future<void> rehydrateStale() async => passes++;
}

/// An upcoming event in household `h-1`. The screens read the device clock
/// here, so the date is far enough out to stay upcoming.
EventListItem _upcoming(String id) {
  final at = DateTime.utc(2026);
  return EventListItem(
    event: Event(
      id: id,
      title: 'Game night $id',
      createdById: 'u1',
      householdId: 'h-1',
      type: EventType.casualGathering,
      reach: Reach.friends,
      status: EventStatus.scheduled,
      schedulingMode: EventSchedulingMode.fixed,
      createdAt: at,
      updatedAt: at,
    ),
    occurrences: [
      EventOccurrence(
        id: 'o-$id',
        eventId: id,
        startDate: DateTime.utc(2099, 1, 1, 19),
        status: OccurrenceStatus.confirmed,
        sortOrder: 0,
        createdAt: at,
        updatedAt: at,
      ),
    ],
  );
}

/// What the cache holds for an [_upcoming] event: the event and its dates,
/// with [attendance] as the current user's own roster row, or none.
EventDetail _detail(String id, {EventAttendee? attendance}) {
  final item = _upcoming(id);
  return EventDetail(
    snapshot: EventSnapshot(event: item.event, occurrences: item.occurrences),
    attendance: attendance,
  );
}

/// The current user's own roster row on event [id], as its host.
EventAttendee _hosting(String id) => EventAttendee(
  id: 'att-$id',
  eventId: id,
  userId: 'u1',
  status: EventParticipationStatus.attending,
  role: EventRole.host,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// The #497 shell wiring through the real composition: the Events
/// destination (#414) and its gate, the overview and group routes resolving
/// the session's repository, households and status, the retry reaching the
/// events' own refresher, and the entry trigger reaching the session's
/// rehydrator.
///
/// The screens' own behaviour is pinned in `events`. What only this file can
/// check is that they are handed what the session registered, and that a
/// container without the optional parts still renders them.
///
/// The same goes for the #498 detail the rows open: the route's builder, its
/// optional server client and its household lookups. And for the #499 create
/// form: the ways in, its gate, the households it may pick, and where a
/// created event is shown.
void main() {
  late _MockAppBootstrapCubit cubit;
  late _MockEventRepository repository;

  setUpAll(() {
    registerFallbackValue(_detail('e-0').snapshot);
    registerFallbackValue(_upcoming('e-0').occurrences.single);
    registerFallbackValue(EventAccessSource.read);
    registerFallbackValue(const EventDraft(title: 'x'));
    registerFallbackValue(AvailabilityResponse.available);
    registerFallbackValue(EventRole.participant);
    registerFallbackValue(_hosting('e-0'));
  });

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    repository = _MockEventRepository();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  /// Pumps home with a cache holding [events] upcoming events. [withRepository]
  /// false is a signed-out session, where the user tier is gone.
  /// [failedPass] publishes a status whose last pass failed, which is where
  /// the banner and its retry live. [withHouseholds] caches `h-1`, and
  /// [moreHouseholds] after it, in each of which the user holds
  /// [householdRole]. [remote] is the server's event client, and
  /// the user's own roster row on every detail is [attendance]. [detailCache]
  /// replaces what every `watchEvent` emits, and [listCache] what the list
  /// watch emits, for a cache the test drives.
  /// [sender] and [users] are what the create form sends through and finds
  /// invitees with, and a create writes the event here as `ev_local`.
  /// [collection] is the session's collection cache, which the Offer games
  /// page lists, and [games] the games server, which a game's page reads.
  Future<void> pumpHome(
    WidgetTester tester, {
    int events = 1,
    bool withRepository = true,
    bool withHouseholds = false,
    List<Household> moreHouseholds = const [],
    HouseholdRole? householdRole,
    EventAttendee? attendance,
    EventRemoteDataSource? remote,
    Stream<EventDetail?>? detailCache,
    Stream<List<EventListItem>>? listCache,
    bool failedPass = false,
    EventRefresher? refresher,
    SessionRehydrator? rehydrator,
    SessionIdentityGuard? guard,
    SyncOperationSender? sender,
    UserRemoteDataSource? users,
    GameCollectionRepository? collection,
    GamesRemoteDataSource? games,
  }) async {
    when(repository.watchAttendingEventListItems).thenAnswer(
      (_) =>
          listCache ??
          Stream.value([for (var n = 0; n < events; n++) _upcoming('e-$n')]),
    );
    // The household screen's events block (#503) lists its household's.
    when(() => repository.watchHouseholdEventListItems(any()))
        .thenAnswer((_) => Stream.value(const <EventListItem>[]));
    when(() => repository.watchEvent(any())).thenAnswer(
      (call) =>
          detailCache ??
          // Left open, as Drift's watch is: one that ends is a session
          // teardown, after which the screen offers no retry (#498).
          Stream.multi(
            (cache) => cache.add(
              _detail(
                call.positionalArguments.first as String,
                attendance: attendance,
              ),
            ),
          ),
    );
    when(() => repository.cacheEvent(any(), source: any(named: 'source')))
        .thenAnswer((_) async {});
    when(() => repository.lastWrite(any())).thenAnswer((_) async => 7);
    when(
      () => repository.forgetEvent(any(), lastWrite: any(named: 'lastWrite')),
    ).thenAnswer((_) async => true);
    when(() => repository.removeDeletedEvent(any()))
        .thenAnswer((_) async => true);
    when(() => repository.create(any())).thenAnswer(
      (call) async => (
        event: _upcoming('ev_local').event,
        syncQueueId: 'q1',
        operation: CreateEventOperation(
          localId: 'ev_local',
          draft: call.positionalArguments.single as EventDraft,
        ),
      ),
    );

    HouseholdRepository? households;
    if (withHouseholds) {
      final mock = _MockHouseholdRepository();
      households = mock;
      when(mock.watchHouseholds).thenAnswer(
        (_) => Stream.value([
          Household(
            id: 'h-1',
            name: 'The Smiths',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
          ...moreHouseholds,
        ]),
      );
      final me = HouseholdMember(
        id: 'm-1',
        userId: 'u1',
        householdId: 'h-1',
        role: householdRole,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      when(() => mock.getCurrentUserMember(any())).thenAnswer((_) async => me);
      // The roster, for the household's own screen.
      when(() => mock.watchMembers(any()))
          .thenAnswer((_) => Stream.value([me]));
    }

    EventHydrationStatus? status;
    if (failedPass) {
      status = EventHydrationStatus()
        ..started()
        ..finished(EventHydrateOutcome.failed);
      addTearDown(status.close);
    }

    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: testAuthResponse()),
          householdRepository: households,
          eventRepository: withRepository ? repository : null,
          eventHydrationStatus: status,
          eventRefresher: refresher,
          eventRemoteDataSource: remote,
          // A guard is asked about the scope's user, so it comes with one.
          userSessionScope: guard == null ? null : _UserSessionScope(),
          sessionIdentityGuard: guard,
          sessionRehydrator: rehydrator,
          syncOperationSender: sender,
          userRemoteDataSource: users,
          gameCollectionRepository: collection,
          gamesRemoteDataSource: games,
        ),
      ),
    );
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
    );
    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await tester.pumpAndSettle();
  }

  Future<void> openTheOverview(WidgetTester tester) =>
      goToDestination(tester, 'events');

  group('the destination (#414)', () {
    testWidgets('shows when the session has an event repository', (
      tester,
    ) async {
      await pumpHome(tester);

      expect(
        find.byKey(NavigationShell.destinationKey('events')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(NavigationShell.railKey),
          matching: find.text('Events'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('hides when there is no user session', (tester) async {
      // The repository lives in the user tier, which sign-out tears down.
      await pumpHome(tester, withRepository: false);
      expect(
        find.byKey(NavigationShell.destinationKey('events')),
        findsNothing,
      );
      // Home alone: no rail, so the menu lists the destinations.
      await openMenu(tester);

      expect(find.byKey(MenuDrawer.entryKey('events')), findsNothing);
      expect(find.byKey(MenuDrawer.entryKey('send_feedback')), findsOneWidget);
    });

    testWidgets('opens the overview', (tester) async {
      await pumpHome(tester);
      await openTheOverview(tester);

      expect(find.byType(EventOverviewScreen), findsOneWidget);
      expect(find.byKey(EventOverviewScreen.rowKey('e-0')), findsOneWidget);
    });

    testWidgets('a container with no hydrate still renders the overview', (
      tester,
    ) async {
      // No status reads as settled, not as loading forever.
      await pumpHome(tester);
      await openTheOverview(tester);

      expect(find.byKey(EventOverviewScreen.loadingKey), findsNothing);
      expect(find.text('Game night e-0'), findsOneWidget);
    });
  });

  group('the home section (#613)', () {
    const welcome = 'Welcome to Board Games Empire';

    PaginatedResult<EventSnapshot> offering(String id) {
      final offered = _upcoming(id);
      return PaginatedResult(
        items: [
          EventSnapshot(event: offered.event, occurrences: offered.occurrences),
        ],
        meta: const PaginationMeta(
          page: 1,
          limit: 3,
          total: 1,
          totalPages: 1,
          hasMore: false,
        ),
      );
    }

    testWidgets('shows when the session has an event repository', (
      tester,
    ) async {
      await pumpHome(tester);

      expect(find.byType(UpcomingEventsSection), findsOneWidget);
      expect(find.byKey(UpcomingEventsSection.rowKey('e-0')), findsOneWidget);
      expect(find.text(welcome), findsNothing);
    });

    testWidgets('the welcome line shows when it has none', (tester) async {
      await pumpHome(tester, withRepository: false);

      expect(find.byType(UpcomingEventsSection), findsNothing);
      expect(find.text(welcome), findsOneWidget);
    });

    testWidgets('See all opens the overview, and back returns home', (
      tester,
    ) async {
      await pumpHome(tester);

      await tester.tap(find.byKey(UpcomingEventsSection.linkKey));
      await tester.pumpAndSettle();
      expect(find.byType(EventOverviewScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(EventOverviewScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('a row opens the detail, and back returns home', (
      tester,
    ) async {
      await pumpHome(tester);

      await tester.tap(find.byKey(UpcomingEventsSection.rowKey('e-0')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EventDetailScreen>(find.byType(EventDetailScreen))
            .eventId,
        'e-0',
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(EventDetailScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets("the row's household is named from the session's cache", (
      tester,
    ) async {
      await pumpHome(tester, withHouseholds: true);

      expect(find.textContaining('The Smiths'), findsOneWidget);
    });

    testWidgets('a fallback row opens the detail, '
        'caching it for reading only', (
      tester,
    ) async {
      final remote = _MockEventRemote();
      when(
        () => remote.browseEvents(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => offering('e-offered'));
      when(() => remote.fetchEvent(any()))
          .thenAnswer((_) async => _detail('e-offered').snapshot);
      await pumpHome(tester, events: 0, remote: remote);
      verifyNever(
        () => repository.cacheEvent(any(), source: any(named: 'source')),
      );

      await tester.tap(find.byKey(UpcomingEventsSection.rowKey('e-offered')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EventDetailScreen>(find.byType(EventDetailScreen))
            .eventId,
        'e-offered',
      );
      // `read` is what keeps it off the events screen, which lists `attending`.
      verify(() => repository.cacheEvent(any(), source: EventAccessSource.read))
          .called(1);
      verifyNever(
        () => repository.cacheEvent(any(), source: EventAccessSource.attending),
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);

      await openTheOverview(tester);
      expect(find.byKey(EventOverviewScreen.rowKey('e-offered')), findsNothing);
    });

    testWidgets('home with no event remote shows the empty text', (
      tester,
    ) async {
      await pumpHome(tester, events: 0);

      expect(find.byKey(UpcomingEventsSection.emptyKey), findsOneWidget);
      expect(find.byKey(UpcomingEventsSection.linkKey), findsOneWidget);
    });

    testWidgets('a retry on a failed read reaches the session refresher', (
      tester,
    ) async {
      var calls = 0;
      await pumpHome(
        tester,
        listCache: Stream.error(StateError('no read')),
        refresher: EventRefresher(() async => calls++),
      );

      await tester.tap(find.byKey(UpcomingEventsSection.retryKey));
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('crossing the breakpoint reads nothing again', (tester) async {
      final remote = _MockEventRemote();
      when(
        () => remote.browseEvents(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => offering('e-offered'));
      useViewSize(tester, const Size(1000, 800));
      await pumpHome(tester, events: 0, remote: remote);
      verify(repository.watchAttendingEventListItems).called(1);

      useViewSize(tester, const Size(500, 800));
      await tester.pumpAndSettle();
      useViewSize(tester, const Size(1000, 800));
      await tester.pumpAndSettle();

      verifyNever(repository.watchAttendingEventListItems);
      verify(
        () => remote.browseEvents(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).called(1);
      expect(find.byKey(UpcomingEventsSection.rowKey('e-offered')), findsOne);
    });
  });

  testWidgets("the rows name the session's cached households", (tester) async {
    await pumpHome(tester, withHouseholds: true);
    await openTheOverview(tester);

    expect(find.textContaining('The Smiths'), findsOneWidget);
  });

  testWidgets('see all opens the group page', (tester) async {
    await pumpHome(tester, events: EventOverviewScreen.groupCap + 1);
    await openTheOverview(tester);

    await tester.tap(
      find.byKey(EventOverviewScreen.seeAllKey(EventGroup.upcoming)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(EventGroupScreen), findsOneWidget);
    expect(
      tester.widget<EventGroupScreen>(find.byType(EventGroupScreen)).group,
      EventGroup.upcoming,
    );
    // Every event in the group, the one the overview left out included.
    expect(
      find.byKey(EventOverviewScreen.rowKey('e-5'), skipOffstage: false),
      findsOneWidget,
    );

    // Back is the overview it was opened from.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(EventGroupScreen), findsNothing);
    expect(find.byType(EventOverviewScreen), findsOneWidget);
  });

  testWidgets('/events/archived opens the archived group page', (tester) async {
    await pumpHome(
      tester,
      // Multi-listen, as the route is built more than once.
      listCache: Stream.multi(
        (cache) => cache.add([
          for (var n = 0; n <= EventOverviewScreen.groupCap; n++)
            EventListItem(
              event: _upcoming('e-$n').event
                  .copyWith(status: EventStatus.archived),
              occurrences: const [],
            ),
        ]),
      ),
    );
    await openTheOverview(tester);

    await tester.tap(
      find.byKey(EventOverviewScreen.seeAllKey(EventGroup.archived)),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<EventGroupScreen>(find.byType(EventGroupScreen)).group,
      EventGroup.archived,
    );
    expect(
      find.byKey(
        EventOverviewScreen.rowKey('e-${EventOverviewScreen.groupCap}'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  group('the retry', () {
    testWidgets('the banner reaches the session refresher', (tester) async {
      var calls = 0;
      await pumpHome(
        tester,
        failedPass: true,
        refresher: EventRefresher(() async => calls++),
      );
      await openTheOverview(tester);

      expect(find.byKey(EventOverviewScreen.refreshBannerKey), findsOneWidget);
      await tester.tap(find.byKey(EventOverviewScreen.refreshRetryKey));
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('a container with no refresher offers none', (tester) async {
      await pumpHome(tester, failedPass: true);
      await openTheOverview(tester);

      expect(find.byKey(EventOverviewScreen.refreshBannerKey), findsOneWidget);
      expect(find.byKey(EventOverviewScreen.refreshRetryKey), findsNothing);
    });
  });

  group('the entry trigger', () {
    testWidgets('opening the overview asks the session for a stale pass', (
      tester,
    ) async {
      final rehydrator = _RecordingRehydrator();
      await pumpHome(tester, rehydrator: rehydrator);
      expect(rehydrator.passes, 0);

      await openTheOverview(tester);

      expect(rehydrator.passes, 1);
    });

    testWidgets('a group page asks for no pass of its own', (tester) async {
      // It is pushed above the overview, which asked on its own entry.
      final rehydrator = _RecordingRehydrator();
      await pumpHome(
        tester,
        events: EventOverviewScreen.groupCap + 1,
        rehydrator: rehydrator,
      );
      await openTheOverview(tester);

      await tester.tap(
        find.byKey(EventOverviewScreen.seeAllKey(EventGroup.upcoming)),
      );
      await tester.pumpAndSettle();

      expect(rehydrator.passes, 1);
    });
  });

  group('opening an event (#498)', () {
    Future<void> openRow(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(EventOverviewScreen.rowKey(id)));
      await tester.pumpAndSettle();
    }

    EventDetailScreen shown(WidgetTester tester) =>
        tester.widget<EventDetailScreen>(find.byType(EventDetailScreen));

    /// The screen's bloc. The provider is inside the screen, so the lookup
    /// starts from a widget it builds.
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

    testWidgets("a row opens the event's detail", (tester) async {
      await pumpHome(tester);
      await openTheOverview(tester);

      await openRow(tester, 'e-0');

      expect(shown(tester).eventId, 'e-0');
      expect(find.byKey(EventDetailScreen.datesKey), findsOneWidget);
      expect(find.text('Game night e-0'), findsOneWidget);
    });

    testWidgets("a group page's row opens it too", (tester) async {
      await pumpHome(tester, events: EventOverviewScreen.groupCap + 1);
      await openTheOverview(tester);
      await tester.tap(
        find.byKey(EventOverviewScreen.seeAllKey(EventGroup.upcoming)),
      );
      await tester.pumpAndSettle();

      // The sixth event, which only the group page lists.
      final row = find.byKey(EventOverviewScreen.rowKey('e-5'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(shown(tester).eventId, 'e-5');
      expect(find.byKey(EventDetailScreen.datesKey), findsOneWidget);
    });

    testWidgets(
      "a server's session guard is asked, as the scope's user, before the "
      'read goes out',
      (tester) async {
        // Web's: another tab can move the session cookie to another user
        // under this one (#432), whose answer would be cached as this
        // user's.
        final remote = _MockEventRemote();
        final guard = _RecordingGuard(SessionConfirmation.notThisUser);
        await pumpHome(tester, remote: remote, guard: guard);
        await openTheOverview(tester);

        await openRow(tester, 'e-0');

        expect(guard.asked, ['u1']);
        verifyNever(() => remote.fetchEvent(any()));
        expect(find.byKey(EventDetailScreen.refreshBannerKey), findsOneWidget);
      },
    );

    testWidgets('a confirmed session reads and writes the event', (
      tester,
    ) async {
      final remote = _MockEventRemote();
      when(() => remote.fetchEvent(any()))
          .thenAnswer((_) async => _detail('e-0').snapshot);
      final guard = _RecordingGuard(SessionConfirmation.confirmed);
      await pumpHome(tester, remote: remote, guard: guard);
      await openTheOverview(tester);

      await openRow(tester, 'e-0');

      // Once before the request, and once before its answer is written.
      expect(guard.asked, ['u1', 'u1']);
      verify(() => remote.fetchEvent('e-0')).called(1);
      verify(() => repository.cacheEvent(any(), source: EventAccessSource.read))
          .called(1);
    });

    testWidgets('back from the detail returns to the list', (tester) async {
      // The app bar's back button, which pops whatever the screen's own
      // `onBack` is. That callback is the not-found test's.
      await pumpHome(tester);
      await openTheOverview(tester);
      await openRow(tester, 'e-0');
      expect(find.byType(EventDetailScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(EventDetailScreen), findsNothing);
      expect(find.byType(EventOverviewScreen), findsOneWidget);
      expect(find.byKey(EventOverviewScreen.rowKey('e-0')), findsOneWidget);
    });

    testWidgets('the not-found way back returns to the list, with home still '
        'beneath it', (tester) async {
      // The screen's `onBack` is used on this surface alone. A `go` to the
      // events would replace the stack with the overview, dropping what the
      // user came from (#308's household bug, which this is the events'
      // guard against).
      final remote = _MockEventRemote();
      when(() => remote.fetchEvent(any())).thenAnswer(
        (_) async => throw const EventRemoteNotFoundException('gone'),
      );
      // The cache holds nothing for the event the user opened, and never
      // closes.
      final cache = StreamController<EventDetail?>()..add(null);
      addTearDown(() => unawaited(cache.close()));
      await pumpHome(tester, remote: remote, detailCache: cache.stream);
      // From home's See all, a push, so home is beneath the overview. The
      // Events destination is a `go` (#414), which leaves nothing beneath.
      await tester.tap(find.byKey(UpcomingEventsSection.linkKey));
      await tester.pumpAndSettle();

      await openRow(tester, 'e-0');

      expect(find.byKey(EventDetailScreen.notFoundKey), findsOneWidget);
      verify(
        () => repository.forgetEvent('e-0', lastWrite: any(named: 'lastWrite')),
      ).called(1);
      // The list is beneath the detail, not on screen.
      expect(find.byType(EventOverviewScreen), findsNothing);

      await tester.tap(find.byKey(EventDetailScreen.notFoundBackKey));
      await tester.pumpAndSettle();

      expect(find.byType(EventOverviewScreen), findsOneWidget);
      expect(find.byType(EventDetailScreen), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets(
      'a container with no event remote still renders the cached event',
      (tester) async {
        await pumpHome(tester);
        await openTheOverview(tester);

        await openRow(tester, 'e-0');

        expect(find.byKey(EventDetailScreen.datesKey), findsOneWidget);
        // Nothing to read from, so nothing written, and nothing to retry.
        verifyNever(
          () => repository.cacheEvent(any(), source: any(named: 'source')),
        );
        expect(find.byKey(EventDetailScreen.errorKey), findsNothing);
        expect(find.byKey(EventDetailScreen.refreshBannerKey), findsNothing);
        expect(find.byKey(EventDetailScreen.refreshRetryKey), findsNothing);
      },
    );

    testWidgets('a registered event remote reads the event once', (
      tester,
    ) async {
      final remote = _MockEventRemote();
      when(() => remote.fetchEvent(any()))
          .thenAnswer((_) async => _detail('e-0').snapshot);
      await pumpHome(tester, remote: remote);
      await openTheOverview(tester);

      await openRow(tester, 'e-0');

      verify(() => remote.fetchEvent('e-0')).called(1);
      verify(() => repository.cacheEvent(any(), source: EventAccessSource.read))
          .called(1);
    });

    testWidgets('a failed read leaves the cached event with a retry', (
      tester,
    ) async {
      final remote = _MockEventRemote();
      when(() => remote.fetchEvent(any()))
          .thenThrow(const EventRemoteTransientException('offline'));
      await pumpHome(tester, remote: remote);
      await openTheOverview(tester);

      await openRow(tester, 'e-0');

      expect(find.byKey(EventDetailScreen.datesKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.refreshBannerKey), findsOneWidget);
      expect(find.byKey(EventDetailScreen.refreshRetryKey), findsOneWidget);
    });

    testWidgets('the household role reaches the screen', (tester) async {
      // The user doesn't attend this event: no roster row names them. Its
      // household owner may edit it all the same.
      await pumpHome(
        tester,
        withHouseholds: true,
        householdRole: HouseholdRole.householdOwner,
      );
      await openTheOverview(tester);

      await openRow(tester, 'e-0');

      final state = blocOf(tester).state;
      expect(state, isA<EventDetailReady>());
      expect((state as EventDetailReady).actions, contains(EventAction.edit));
      expect(state.householdName, 'The Smiths');
    });

    testWidgets('a plain household member is offered nothing', (tester) async {
      await pumpHome(
        tester,
        withHouseholds: true,
        householdRole: HouseholdRole.householdMember,
      );
      await openTheOverview(tester);

      await openRow(tester, 'e-0');

      final state = blocOf(tester).state;
      expect(state, isA<EventDetailReady>());
      expect((state as EventDetailReady).actions, isEmpty);
    });

    group('deleting it (#501)', () {
      /// A server that reads the event and accepts its delete.
      _MockEventRemote deletable() {
        final remote = _MockEventRemote();
        when(() => remote.fetchEvent(any()))
            .thenAnswer((_) async => _detail('e-0').snapshot);
        when(() => remote.deleteEvent(any())).thenAnswer((_) async {});
        return remote;
      }

      /// From the open detail, through the menu and the dialog, to the
      /// delete's end. A menu item's press lands a frame after its tap, so
      /// the dialog is looked for after one.
      Future<void> deleteIt(WidgetTester tester) async {
        await tester.tap(find.byKey(EventDetailScreen.moreActionsKey));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(EventDetailScreen.deleteKey));
        await tester.pump();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(EventDetailScreen.deleteConfirmKey));
        await tester.pumpAndSettle();
      }

      testWidgets("a host's delete returns to the list", (tester) async {
        final remote = deletable();
        await pumpHome(tester, remote: remote, attendance: _hosting('e-0'));
        await openTheOverview(tester);
        await openRow(tester, 'e-0');

        await deleteIt(tester);

        verify(() => remote.deleteEvent('e-0')).called(1);
        verify(() => repository.removeDeletedEvent('e-0')).called(1);
        expect(find.byType(EventDetailScreen), findsNothing);
        expect(find.byType(EventOverviewScreen), findsOneWidget);
        // The app's messenger holds the snackbar past the route it came from.
        expect(find.text('Event deleted'), findsOneWidget);
      });

      testWidgets(
        'the session guard is asked before the delete request goes out',
        (tester) async {
          final guard = _RecordingGuard(SessionConfirmation.confirmed);
          await pumpHome(
            tester,
            remote: deletable(),
            attendance: _hosting('e-0'),
            guard: guard,
          );
          await openTheOverview(tester);
          await openRow(tester, 'e-0');

          // The read's two: before the request, and before its write.
          expect(guard.asked, ['u1', 'u1']);

          await deleteIt(tester);

          // The delete's one, before the request: its removal is every
          // user's, so nothing is asked before it.
          expect(guard.asked, ['u1', 'u1', 'u1']);
        },
      );
    });

    group('confirming a date (#506)', () {
      testWidgets(
        'a host confirms a date, and the overview moves the event to upcoming',
        (tester) async {
          final at = DateTime.utc(2026);
          final proposed = EventOccurrence(
            id: 'o-e-0',
            eventId: 'e-0',
            startDate: DateTime.utc(2099, 1, 1, 19),
            status: OccurrenceStatus.proposed,
            sortOrder: 0,
            createdAt: at,
            updatedAt: at,
          );
          final confirmed = proposed.copyWith(
            status: OccurrenceStatus.confirmed,
          );
          final planning = EventSnapshot(
            event: _upcoming('e-0').event
                .copyWith(status: EventStatus.planning),
            occurrences: [proposed],
          );
          final scheduled = EventSnapshot(
            event: _upcoming('e-0').event,
            occurrences: [confirmed],
          );

          // The cache the mock repository stands for: what it holds, and
          // the watches that follow it.
          var cached = planning;
          final detailWatches = <MultiStreamController<EventDetail?>>[];
          final listWatches = <MultiStreamController<List<EventListItem>>>[];
          EventDetail detailOf(EventSnapshot snapshot) =>
              EventDetail(snapshot: snapshot, attendance: _hosting('e-0'));
          List<EventListItem> listOf(EventSnapshot snapshot) => [
            EventListItem(
              event: snapshot.event,
              occurrences: snapshot.occurrences,
            ),
          ];
          void publish(EventSnapshot snapshot) {
            cached = snapshot;
            for (final watch in detailWatches) {
              watch.add(detailOf(snapshot));
            }
            for (final watch in listWatches) {
              watch.add(listOf(snapshot));
            }
          }

          final remote = _MockEventRemote();
          var reads = 0;
          when(() => remote.fetchEvent(any()))
              .thenAnswer((_) async => reads++ == 0 ? planning : scheduled);
          when(() => remote.confirmOccurrence(any(), any()))
              .thenAnswer((_) async => confirmed);

          await pumpHome(
            tester,
            remote: remote,
            detailCache: Stream.multi((watch) {
              detailWatches.add(watch);
              watch.add(detailOf(cached));
            }),
            listCache: Stream.multi((watch) {
              listWatches.add(watch);
              watch.add(listOf(cached));
            }),
          );
          when(() => repository.cacheEvent(any(), source: any(named: 'source')))
              .thenAnswer((call) async {
                publish(call.positionalArguments.first as EventSnapshot);
              });
          when(() => repository.cacheOccurrence(any()))
              .thenAnswer((call) async {
                final date = call.positionalArguments.first as EventOccurrence;
                publish(cached.copyWith(occurrences: [date]));
                return true;
              });

          await openTheOverview(tester);

          // Without a confirmed date the event is planned, not upcoming.
          expect(
            find.descendant(
              of: find.byKey(EventOverviewScreen.groupKey(EventGroup.planning)),
              matching: find.byKey(EventOverviewScreen.rowKey('e-0')),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(EventOverviewScreen.groupKey(EventGroup.upcoming)),
            findsNothing,
          );

          await openRow(tester, 'e-0');

          // The date's menu, then its Confirm entry. A menu item's press
          // lands a frame after its tap, so the dialog is looked for after
          // one.
          await tester.tap(find.byKey(EventDetailScreen.dateMenuKey('o-e-0')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(
              EventDetailScreen.dateActionKey('o-e-0', EventAction.confirmDate),
            ),
          );
          await tester.pump();
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Confirm'),
            ),
          );
          await tester.pumpAndSettle();

          verify(() => remote.confirmOccurrence('e-0', 'o-e-0')).called(1);
          verify(() => repository.cacheOccurrence(confirmed)).called(1);
          // The screen read the event again for its new status.
          verify(() => remote.fetchEvent('e-0')).called(2);
          expect(find.text('Date confirmed'), findsOneWidget);

          await tester.pageBack();
          await tester.pumpAndSettle();

          expect(find.byType(EventOverviewScreen), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(EventOverviewScreen.groupKey(EventGroup.upcoming)),
              matching: find.byKey(EventOverviewScreen.rowKey('e-0')),
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(EventOverviewScreen.groupKey(EventGroup.planning)),
            findsNothing,
          );
        },
      );
    });

    group('a poll (#507)', () {
      testWidgets(
        'a participant answers a proposed date through the app, then opens '
        'who answered',
        (tester) async {
          final history = FakeBrowserHistory.install(tester);
          final at = DateTime.utc(2026);
          EventOccurrence proposed(String id, int day, int sortOrder) =>
              EventOccurrence(
                id: id,
                eventId: 'e-0',
                startDate: DateTime.utc(2099, 1, day, 19),
                status: OccurrenceStatus.proposed,
                sortOrder: sortOrder,
                createdAt: at,
                updatedAt: at,
              );
          EventAttendee participant(String id, String userId, String name) =>
              EventAttendee(
                id: id,
                eventId: 'e-0',
                userId: userId,
                displayName: name,
                status: EventParticipationStatus.attending,
                role: EventRole.participant,
                createdAt: at,
                updatedAt: at,
              );
          // The viewer's own row, and Ada's.
          final me = participant('att-me', 'u1', 'Sam');
          final poll = EventSnapshot(
            event: _upcoming('e-0').event.copyWith(
              status: EventStatus.planning,
              schedulingMode: EventSchedulingMode.poll,
            ),
            occurrences: [proposed('o-1', 1, 0), proposed('o-2', 8, 1)],
            attendees: [me, participant('att-2', 'u2', 'Ada')],
          );

          // The server's poll: Ada's Maybe on the first date, and the
          // viewer's answer once they have given it.
          AvailabilityResponse? held;
          AvailabilitySummary summary() => AvailabilitySummary(
            occurrences: [
              OccurrenceAvailability(
                occurrenceId: 'o-1',
                available: held == AvailabilityResponse.available ? 1 : 0,
                maybe: 1,
                unavailable: 0,
                voters: [
                  if (held case final response?)
                    AvailabilityVoter(
                      attendeeId: 'att-me',
                      response: response,
                      eligible: true,
                    ),
                  const AvailabilityVoter(
                    attendeeId: 'att-2',
                    response: AvailabilityResponse.maybe,
                    eligible: true,
                  ),
                ],
              ),
            ],
          );
          final remote = _MockEventRemote();
          when(() => remote.fetchEvent(any())).thenAnswer((_) async => poll);
          when(() => remote.fetchAvailabilitySummary(any()))
              .thenAnswer((_) async => summary());
          when(() => remote.submitAvailability(any(), any(), any()))
              .thenAnswer((call) async {
                final response =
                    call.positionalArguments[2] as AvailabilityResponse;
                held = response;
                return AvailabilityVote(
                  id: 'v-1',
                  occurrenceId: call.positionalArguments[1] as String,
                  attendeeId: 'att-me',
                  response: response,
                  createdAt: at,
                  updatedAt: at,
                );
              });

          await pumpHome(
            tester,
            remote: remote,
            detailCache: Stream.multi(
              (cache) => cache.add(EventDetail(snapshot: poll, attendance: me)),
            ),
          );
          await openTheOverview(tester);
          await openRow(tester, 'e-0');

          final available = find.byKey(
            EventDetailScreen.pollAnswerKey(
              'o-1',
              AvailabilityResponse.available,
            ),
          );
          await tester.ensureVisible(available);
          await tester.pumpAndSettle();
          await tester.tap(available);
          await tester.pumpAndSettle();

          verify(
            () => remote.submitAvailability(
              'e-0',
              'o-1',
              AvailabilityResponse.available,
            ),
          ).called(1);
          expect(tester.widget<ChoiceChip>(available).selected, isTrue);
          // The detail's reads: as it opened, and once the vote was in.
          verify(() => remote.fetchAvailabilitySummary('e-0'))
              .called(greaterThanOrEqualTo(2));

          final whoAnswered = find.byKey(EventDetailScreen.whoAnsweredKey);
          await tester.ensureVisible(whoAnswered);
          await tester.pumpAndSettle();
          await tester.tap(whoAnswered);
          await tester.pumpAndSettle();

          expect(find.byType(EventAvailabilityScreen), findsOneWidget);
          // On web it has an address of its own (#321).
          expect(history.locations.last, AppRoutes.eventAvailabilityOf('e-0'));
          // The page's own read, which holds the answer.
          verify(() => remote.fetchAvailabilitySummary('e-0')).called(1);
          Finder shows(String attendeeId, String occurrenceId, String text) =>
              find.descendant(
                of: find.byKey(
                  EventAvailabilityScreen.cellKey(attendeeId, occurrenceId),
                ),
                matching: find.text(text),
              );
          expect(shows('att-me', 'o-1', 'Available'), findsOneWidget);
          expect(shows('att-2', 'o-1', 'Maybe'), findsOneWidget);
          expect(shows('att-me', 'o-2', '—'), findsOneWidget);

          // Back is the event.
          await tester.pageBack();
          await tester.pumpAndSettle();

          expect(find.byType(EventAvailabilityScreen), findsNothing);
          expect(find.byType(EventDetailScreen), findsOneWidget);
          expect(history.locations.last, AppRoutes.eventDetailOf('e-0'));
        },
      );
    });

    group('adding people (#510)', () {
      final at = DateTime.utc(2026);
      EventAttendee person(
        String id,
        String userId,
        String name,
        EventRole role, {
        EventParticipationStatus status = EventParticipationStatus.attending,
      }) => EventAttendee(
        id: id,
        eventId: 'e-0',
        userId: userId,
        displayName: name,
        status: status,
        role: role,
        createdAt: at,
        updatedAt: at,
      );

      // The viewer hosts e-0, with Ada beside them on its roster.
      final me = person('att-me', 'u1', 'Sam', EventRole.host);
      final hosted = EventSnapshot(
        event: _upcoming('e-0').event,
        occurrences: _upcoming('e-0').occurrences,
        attendees: [me, person('att-2', 'u2', 'Ada', EventRole.participant)],
      );
      const cy = UserSummary(id: 'u3', username: 'cy', displayName: 'Cy');

      GoRouter routerOf(WidgetTester tester) =>
          tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter;

      /// A server that reads [hosted] and adds whom it is asked to, invited.
      _MockEventRemote hosting() {
        final remote = _MockEventRemote();
        when(() => remote.fetchEvent(any())).thenAnswer((_) async => hosted);
        when(
          () => remote.addAttendee(
            any(),
            userId: any(named: 'userId'),
            role: any(named: 'role'),
          ),
        ).thenAnswer(
          (call) async => person(
            'att-3',
            call.namedArguments[#userId] as String,
            'Cy',
            call.namedArguments[#role] as EventRole,
            status: EventParticipationStatus.invited,
          ),
        );
        return remote;
      }

      /// A user search that finds Cy.
      _MockUserRemote finding() {
        final users = _MockUserRemote();
        when(
          () => users.searchUsers(
            any(),
            page: any(named: 'page'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer(
          (_) async => const PaginatedResult(
            items: [cy],
            meta: PaginationMeta(
              page: 1,
              limit: UserRemoteDataSource.maxSearchPageSize,
              total: 1,
              totalPages: 1,
              hasMore: false,
            ),
          ),
        );
        return users;
      }

      /// Opens e-0's detail, which the viewer hosts.
      Future<void> openHosted(
        WidgetTester tester, {
        required EventRemoteDataSource remote,
        UserRemoteDataSource? users,
      }) async {
        when(() => repository.addCachedAttendee(any()))
            .thenAnswer((_) async => true);
        await pumpHome(
          tester,
          remote: remote,
          users: users,
          detailCache: Stream.multi(
            (cache) => cache.add(EventDetail(snapshot: hosted, attendance: me)),
          ),
        );
        await openTheOverview(tester);
        await openRow(tester, 'e-0');
      }

      Future<void> tapShown(WidgetTester tester, Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      testWidgets("the detail's Add people opens /events/:id/attendees/add", (
        tester,
      ) async {
        final history = FakeBrowserHistory.install(tester);
        final remote = hosting();
        await openHosted(tester, remote: remote, users: finding());

        await tapShown(tester, find.byKey(EventDetailScreen.addAttendeeKey));

        expect(find.byType(AddAttendeeScreen), findsOneWidget);
        // On web it has an address of its own (#321).
        expect(history.locations.last, AppRoutes.eventAddAttendeeOf('e-0'));

        // The session's user search finds Cy, and the page answers with
        // them, as a participant.
        await tester.enterText(find.byKey(AddAttendeeScreen.searchKey), 'cy');
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        await tapShown(tester, find.byKey(AddAttendeeScreen.resultKey('u3')));
        await tapShown(tester, find.byKey(AddAttendeeScreen.addKey));

        // Back on the event, which sends the add.
        expect(find.byType(AddAttendeeScreen), findsNothing);
        expect(find.byType(EventDetailScreen), findsOneWidget);
        expect(history.locations.last, AppRoutes.eventDetailOf('e-0'));
        verify(
          () => remote.addAttendee(
            'e-0',
            userId: 'u3',
            role: EventRole.participant,
          ),
        ).called(1);
        expect(
          find.text("Added Cy. They'll be asked whether they're coming."),
          findsOneWidget,
        );
      });

      testWidgets('a deep link to the add page lands on the detail', (
        tester,
      ) async {
        // The page's roles and roster come from the open detail, which a
        // link, a refresh or a history entry doesn't carry.
        final history = FakeBrowserHistory.install(tester);
        await openHosted(tester, remote: hosting(), users: finding());

        routerOf(tester).go(AppRoutes.eventAddAttendeeOf('e-0'));
        await tester.pumpAndSettle();

        expect(find.byType(AddAttendeeScreen), findsNothing);
        expect(find.byType(NotYetAvailableScreen), findsNothing);
        expect(
          tester
              .widget<EventDetailScreen>(find.byType(EventDetailScreen))
              .eventId,
          'e-0',
        );
        expect(history.locations.last, AppRoutes.eventDetailOf('e-0'));
      });

      testWidgets("the closed page's own history entry gives way to the "
          'event, in its place', (tester) async {
        // Browser Back or Forward to it restores the stack the entry
        // stored, where go_router keeps a push's extra only as JSON, which
        // the page's isn't, and runs no route redirect on a restored push.
        // The route leaves for the event at once, and the entry becomes the
        // event's, so Back from there doesn't come straight back.
        final history = FakeBrowserHistory.install(tester);
        await openHosted(tester, remote: hosting(), users: finding());
        await tapShown(tester, find.byKey(EventDetailScreen.addAttendeeKey));
        expect(find.byType(AddAttendeeScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        final detail = AppRoutes.eventDetailOf('e-0');
        final page = AppRoutes.eventAddAttendeeOf('e-0');
        // The page's entry, between the event's before it and after it.
        final before = history.allLocations;
        expect(before.sublist(before.length - 3), [detail, page, detail]);
        expect(history.locations, before);

        Future<void> expectTheEvent() async {
          expect(find.byType(AddAttendeeScreen), findsNothing);
          expect(find.byType(NotYetAvailableScreen), findsNothing);
          expect(find.byType(EventDetailScreen), findsOneWidget);
        }

        await history.back();
        await expectTheEvent();
        // Replaced, not followed by a new entry.
        expect(history.allLocations, [
          ...before.sublist(0, before.length - 2),
          detail,
          detail,
        ]);
        expect(history.locations, hasLength(before.length - 1));

        // Forward is the event's entry it came back from.
        await history.forward();
        await expectTheEvent();
        expect(history.locations, hasLength(before.length));
        expect(history.locations.last, detail);

        // And Back twice passes the event's entries, the page's gone.
        await history.back();
        await expectTheEvent();
        expect(history.locations, hasLength(before.length - 1));
        await history.back();
        await expectTheEvent();
        expect(history.locations, hasLength(before.length - 2));
        expect(history.allLocations, hasLength(before.length));
      });

      testWidgets("the closed page's entry gives way under a dialog the "
          'event opened, which stays', (tester) async {
        // The dialog is on the root navigator, over the shell, and its
        // event stays beneath the restored entry, so the dialog stays too.
        // The route leaves from its own navigator: the router's pop would
        // close the dialog and leave the spent page and its address.
        final history = FakeBrowserHistory.install(tester);
        await openHosted(tester, remote: hosting(), users: finding());
        await tapShown(tester, find.byKey(EventDetailScreen.addAttendeeKey));
        await tester.pageBack();
        await tester.pumpAndSettle();
        final detail = AppRoutes.eventDetailOf('e-0');
        final page = AppRoutes.eventAddAttendeeOf('e-0');
        final before = history.allLocations;
        expect(before.sublist(before.length - 3), [detail, page, detail]);

        unawaited(
          showDialog<void>(
            context: tester.element(find.byType(EventDetailScreen)),
            builder: (_) => const AlertDialog(content: Text('probe')),
          ),
        );
        await tester.pumpAndSettle();

        await history.back();
        await tester.pumpAndSettle();

        expect(find.text('probe'), findsOneWidget);
        expect(find.byType(AddAttendeeScreen), findsNothing);
        expect(find.byType(EventDetailScreen), findsOneWidget);
        expect(history.locations.last, detail);
      });

      testWidgets('no Add people where no user search is registered', (
        tester,
      ) async {
        // The page finds people through it.
        await openHosted(tester, remote: hosting());

        expect(find.byKey(EventDetailScreen.attendeesKey), findsOneWidget);
        expect(find.text('Ada'), findsOneWidget);
        expect(find.byKey(EventDetailScreen.addAttendeeKey), findsNothing);
      });
    });

    group('offering games (#516)', () {
      final at = DateTime.utc(2026);

      // The viewer hosts e-0, alone on its roster.
      final me = EventAttendee(
        id: 'att-me',
        eventId: 'e-0',
        userId: 'u1',
        displayName: 'Sam',
        status: EventParticipationStatus.attending,
        role: EventRole.host,
        createdAt: at,
        updatedAt: at,
      );
      final hosted = EventSnapshot(
        event: _upcoming('e-0').event,
        occurrences: _upcoming('e-0').occurrences,
        attendees: [me],
      );
      final azul = GameCollectionListItem(
        entry: GameCollection(
          id: 'c-azul',
          userId: 'u1',
          platformGameId: 'pg-azul',
          medium: GameMedium.physical,
          createdAt: at,
          updatedAt: at,
        ),
        gameId: 'g-azul',
        title: 'Azul',
        platformName: 'Tabletop',
      );

      GoRouter routerOf(WidgetTester tester) =>
          tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter;

      /// A server that reads [hosted], an empty pool, and offers every game
      /// a batch sends.
      _MockEventRemote hosting() {
        final remote = _MockEventRemote();
        when(() => remote.fetchEvent(any())).thenAnswer((_) async => hosted);
        when(
          () => remote.fetchGamesPool(
            any(),
            attendeeIds: any(named: 'attendeeIds'),
            cancelled: any(named: 'cancelled'),
          ),
        ).thenAnswer((_) async => const []);
        when(
          () => remote.offerGames(
            any(),
            any(),
            collectionIds: any(named: 'collectionIds'),
          ),
        ).thenAnswer(
          (call) async => [
            for (final id
                in call.namedArguments[#collectionIds] as List<String>)
              GameOfferResult.offered(
                collectionId: id,
                alreadyOffered: false,
              ),
          ],
        );
        return remote;
      }

      /// Opens e-0's detail, which the viewer hosts, on its Games tab's Pool
      /// sub-tab, where Offer games is (#945).
      Future<void> openGames(
        WidgetTester tester, {
        required EventRemoteDataSource remote,
        GameCollectionRepository? collection,
      }) async {
        await pumpHome(
          tester,
          remote: remote,
          collection: collection,
          detailCache: Stream.multi(
            (cache) => cache.add(EventDetail(snapshot: hosted, attendance: me)),
          ),
        );
        await openTheOverview(tester);
        await openRow(tester, 'e-0');
        await tester.tap(
          find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(EventDetailScreen.sectionTabKey(EventGamesSection.pool)),
        );
        await tester.pumpAndSettle();
      }

      Future<void> tapShown(WidgetTester tester, Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      testWidgets('the offer route with no args goes back to the event', (
        tester,
      ) async {
        // What the page offers comes from the open detail, which a link, a
        // refresh or a history entry doesn't carry. It lands on the pool,
        // where Offer games is (#856).
        final history = FakeBrowserHistory.install(tester);
        final handle = tester.ensureSemantics();
        try {
          await openGames(
            tester,
            remote: hosting(),
            collection: _Collection([azul]),
          );

          routerOf(tester).go(AppRoutes.eventOfferGamesOf('e-0'));
          await tester.pumpAndSettle();

          expect(find.byType(OfferGamesScreen), findsNothing);
          expect(find.byType(NotYetAvailableScreen), findsNothing);
          expect(
            tester
                .widget<EventDetailScreen>(find.byType(EventDetailScreen))
                .eventId,
            'e-0',
          );
          expect(
            history.locations.last,
            AppRoutes.eventDetailOf('e-0', tab: 'pool'),
          );
          expect(
            tester.getSemantics(
              find.byKey(
                EventDetailScreen.sectionTabKey(EventGamesSection.pool),
              ),
            ),
            isSemantics(isSelected: true),
          );
          expect(find.byKey(EventDetailScreen.offerGamesKey), findsOneWidget);
        } finally {
          handle.dispose();
        }
      });

      testWidgets('with args and a collection it builds the page', (
        tester,
      ) async {
        final history = FakeBrowserHistory.install(tester);
        final remote = hosting();
        await openGames(
          tester,
          remote: remote,
          collection: _Collection([azul]),
        );

        await tapShown(tester, find.byKey(EventDetailScreen.offerGamesKey));

        expect(find.byType(OfferGamesScreen), findsOneWidget);
        // On web it has an address of its own (#321).
        expect(history.locations.last, AppRoutes.eventOfferGamesOf('e-0'));
        expect(
          AppRoutes.eventOfferGamesOf('e-0'),
          '${AppRoutes.eventDetailOf('e-0')}/games/offer',
        );

        // The session's collection, and its pick sent from the event.
        await tapShown(tester, find.byKey(OfferGamesScreen.rowKey('c-azul')));
        await tapShown(tester, find.byKey(OfferGamesScreen.sendKey));

        expect(find.byType(OfferGamesScreen), findsNothing);
        expect(find.byType(EventDetailScreen), findsOneWidget);
        expect(
          history.locations.last,
          AppRoutes.eventDetailOf('e-0', tab: 'pool'),
        );
        verify(
          () => remote.offerGames('e-0', 'att-me', collectionIds: ['c-azul']),
        ).called(1);
        expect(find.text('1 game offered.'), findsOneWidget);
      });

      testWidgets("the closed page's own history entry gives way to the "
          'event, in its place', (tester) async {
        // As Add people's: go_router keeps a push's extra only as JSON,
        // which the page's isn't, and runs no route redirect on a restored
        // push.
        final history = FakeBrowserHistory.install(tester);
        await openGames(
          tester,
          remote: hosting(),
          collection: _Collection([azul]),
        );
        await tapShown(tester, find.byKey(EventDetailScreen.offerGamesKey));
        expect(find.byType(OfferGamesScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        // The event's entry names the pool it was left on (#856).
        final detail = AppRoutes.eventDetailOf('e-0', tab: 'pool');
        final page = AppRoutes.eventOfferGamesOf('e-0');
        final before = history.allLocations;
        expect(before.sublist(before.length - 3), [detail, page, detail]);

        await history.back();

        expect(find.byType(OfferGamesScreen), findsNothing);
        expect(find.byType(NotYetAvailableScreen), findsNothing);
        expect(find.byType(EventDetailScreen), findsOneWidget);
        // Replaced, not followed by a new entry.
        expect(history.allLocations, [
          ...before.sublist(0, before.length - 2),
          detail,
          detail,
        ]);
      });

      testWidgets('no Offer games where no collection is registered, and the '
          'route builds nothing', (tester) async {
        await openGames(tester, remote: hosting());

        expect(find.byKey(EventDetailScreen.poolSearchKey), findsOneWidget);
        expect(find.byKey(EventDetailScreen.offerGamesKey), findsNothing);

        unawaited(
          routerOf(tester).push<void>(
            AppRoutes.eventOfferGamesOf('e-0'),
            extra: const OfferGamesArgs(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(OfferGamesScreen), findsNothing);
        expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      });
    });

    group('a quick look on the Games tab (#957)', () {
      final at = DateTime.utc(2026);

      // The viewer hosts e-0, alone on its roster, and offers Azul.
      final me = EventAttendee(
        id: 'att-me',
        eventId: 'e-0',
        userId: 'u1',
        displayName: 'Sam',
        status: EventParticipationStatus.attending,
        role: EventRole.host,
        createdAt: at,
        updatedAt: at,
      );
      final hosted = EventSnapshot(
        event: _upcoming('e-0').event,
        occurrences: _upcoming('e-0').occurrences,
        attendees: [me],
      );
      const azul = OfferedGame(
        id: 'o-azul',
        attendeeId: 'att-me',
        collectionId: 'c-azul',
        platformGameId: 'pg-azul',
        gameId: 'g-azul',
        title: 'Azul',
        platformName: 'Tabletop',
        medium: GameMedium.physical,
      );

      GoRouter routerOf(WidgetTester tester) =>
          tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter;

      testWidgets("a quick look's View game pushes /games/:id", (
        tester,
      ) async {
        final remote = _MockEventRemote();
        when(() => remote.fetchEvent(any())).thenAnswer((_) async => hosted);
        when(
          () => remote.fetchGamesPool(
            any(),
            attendeeIds: any(named: 'attendeeIds'),
            cancelled: any(named: 'cancelled'),
          ),
        ).thenAnswer((_) async => const [azul]);
        await pumpHome(
          tester,
          remote: remote,
          games: _GamesRemote(),
          detailCache: Stream.multi(
            (cache) => cache.add(EventDetail(snapshot: hosted, attendance: me)),
          ),
        );
        await openTheOverview(tester);
        await openRow(tester, 'e-0');
        await tester.tap(
          find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(EventDetailScreen.sectionTabKey(EventGamesSection.pool)),
        );
        await tester.pumpAndSettle();
        final head = find.byKey(EventDetailScreen.poolRowHeadKey(azul.id));
        await tester.ensureVisible(head);
        await tester.pumpAndSettle();

        await tester.tap(head);
        await tester.pumpAndSettle();
        expect(find.byKey(EventDetailScreen.quickLookKey), findsOneWidget);

        await tester.tap(find.byKey(EventDetailScreen.quickLookOpenGameKey));
        await tester.pumpAndSettle();

        expect(find.byType(GameDetailScreen), findsOneWidget);
        expect(
          routerOf(tester).state.uri.toString(),
          AppRoutes.gameDetailOf('g-azul'),
        );
        // Gone once the page has arrived, not just hidden under it.
        expect(
          find.byKey(EventDetailScreen.quickLookKey, skipOffstage: false),
          findsNothing,
        );

        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();

        expect(find.byType(GameDetailScreen), findsNothing);
        expect(find.byKey(EventDetailScreen.quickLookKey), findsNothing);
        expect(find.byType(EventDetailScreen), findsOneWidget);
      });

      testWidgets('without a games server the quick look offers no View game', (
        tester,
      ) async {
        final remote = _MockEventRemote();
        when(() => remote.fetchEvent(any())).thenAnswer((_) async => hosted);
        when(
          () => remote.fetchGamesPool(
            any(),
            attendeeIds: any(named: 'attendeeIds'),
            cancelled: any(named: 'cancelled'),
          ),
        ).thenAnswer((_) async => const [azul]);
        await pumpHome(
          tester,
          remote: remote,
          detailCache: Stream.multi(
            (cache) => cache.add(EventDetail(snapshot: hosted, attendance: me)),
          ),
        );
        await openTheOverview(tester);
        await openRow(tester, 'e-0');
        await tester.tap(
          find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(EventDetailScreen.sectionTabKey(EventGamesSection.pool)),
        );
        await tester.pumpAndSettle();
        final head = find.byKey(EventDetailScreen.poolRowHeadKey(azul.id));
        await tester.ensureVisible(head);
        await tester.pumpAndSettle();

        await tester.tap(head);
        await tester.pumpAndSettle();

        expect(find.byKey(EventDetailScreen.quickLookKey), findsOneWidget);
        expect(
          find.byKey(EventDetailScreen.quickLookOpenGameKey),
          findsNothing,
        );
      });
    });

    group('its tab in the location (#856)', () {
      GoRouter routerOf(WidgetTester tester) =>
          tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter;

      /// Pumps home with e-0 hosted by the viewer, alone on its roster, and
      /// a server that reads it with nothing offered and nothing nominated:
      /// enough for the Games tab and its sub-tabs. The pool is read for the
      /// roster, so an empty one would never read it. Who answered its poll
      /// reads as nobody, for the page that lists them. [id] names the event
      /// in place of e-0.
      Future<void> pumpHosted(WidgetTester tester, {String id = 'e-0'}) {
        final me = _hosting(id);
        final hosted = EventSnapshot(
          event: _upcoming(id).event,
          occurrences: _upcoming(id).occurrences,
          attendees: [me],
        );
        final remote = _MockEventRemote();
        when(() => remote.fetchEvent(any())).thenAnswer((_) async => hosted);
        when(
          () => remote.fetchGamesPool(
            any(),
            attendeeIds: any(named: 'attendeeIds'),
            cancelled: any(named: 'cancelled'),
          ),
        ).thenAnswer((_) async => const []);
        when(() => remote.fetchNominations(any()))
            .thenAnswer((_) async => const []);
        when(() => remote.fetchAvailabilitySummary(any())).thenAnswer(
          (_) async => const AvailabilitySummary(occurrences: []),
        );
        return pumpHome(
          tester,
          remote: remote,
          detailCache: Stream.multi(
            (cache) => cache.add(EventDetail(snapshot: hosted, attendance: me)),
          ),
        );
      }

      Future<void> choose(WidgetTester tester, Finder control) async {
        await tester.tap(control);
        await tester.pumpAndSettle();
      }

      testWidgets('choosing Pool on an event opened from Home replaces its '
          'location, keeps its screen and keeps Back', (tester) async {
        // Home pushes the event, so the stack beneath it isn't the one its
        // location would build. A tab change that built the stack again
        // from the location would lose the screen's state, and Back would
        // land on the events list instead of Home.
        final history = FakeBrowserHistory.install(tester);
        await pumpHosted(tester);
        await choose(tester, find.byKey(UpcomingEventsSection.rowKey('e-0')));
        expect(history.locations.last, AppRoutes.eventDetailOf('e-0'));
        final entries = history.allLocations.length;
        // EventDetailScreen is stateless; the first state beneath it holds
        // the screen's blocs.
        final blocs = find
            .descendant(
              of: find.byType(EventDetailScreen),
              matching: find.byWidgetPredicate((w) => w is StatefulWidget),
            )
            .first;
        final state = tester.state(blocs);

        await choose(
          tester,
          find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
        );
        await choose(
          tester,
          find.byKey(EventDetailScreen.sectionTabKey(EventGamesSection.pool)),
        );

        expect(
          history.locations.last,
          AppRoutes.eventDetailOf('e-0', tab: 'pool'),
        );
        // Each change took the event's entry; none was added.
        expect(history.allLocations, hasLength(entries));
        expect(state.mounted, isTrue);
        expect(tester.state(blocs), same(state));
        expect(find.byKey(EventDetailScreen.poolSearchKey), findsOneWidget);

        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(find.byType(EventDetailScreen), findsNothing);
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(history.locations.last, AppRoutes.home);
      });

      testWidgets('choosing Pool on an event opened by a link replaces its '
          'location and keeps its screen', (tester) async {
        // A link builds the event's page from its location, as a replace
        // would build it again: the screen's state stays only because the
        // replace keeps the page and its key.
        final history = FakeBrowserHistory.install(tester);
        await pumpHosted(tester);
        routerOf(tester).go('/events/e-0');
        await tester.pumpAndSettle();
        expect(history.locations.last, AppRoutes.eventDetailOf('e-0'));
        final entries = history.allLocations.length;
        // EventDetailScreen is stateless; the first state beneath it holds
        // the screen's blocs.
        final blocs = find
            .descendant(
              of: find.byType(EventDetailScreen),
              matching: find.byWidgetPredicate((w) => w is StatefulWidget),
            )
            .first;
        final state = tester.state(blocs);

        await choose(
          tester,
          find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
        );
        await choose(
          tester,
          find.byKey(EventDetailScreen.sectionTabKey(EventGamesSection.pool)),
        );

        expect(
          history.locations.last,
          AppRoutes.eventDetailOf('e-0', tab: 'pool'),
        );
        // Each change took the event's entry; none was added.
        expect(history.allLocations, hasLength(entries));
        expect(state.mounted, isTrue);
        expect(tester.state(blocs), same(state));
        expect(find.byKey(EventDetailScreen.poolSearchKey), findsOneWidget);
      });

      testWidgets('choosing Pool on an event whose link spells its id '
          'another way replaces its location', (tester) async {
        // A link may leave raw what eventDetailOf escapes: here the id's
        // colon, which a path may carry as it is. The event is still the top
        // location, so the tab still goes into it.
        final history = FakeBrowserHistory.install(tester);
        await pumpHosted(tester, id: 'e:0');
        routerOf(tester).go('/events/e:0');
        await tester.pumpAndSettle();
        expect(AppRoutes.eventDetailOf('e:0'), isNot('/events/e:0'));

        await choose(
          tester,
          find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
        );
        await choose(
          tester,
          find.byKey(EventDetailScreen.sectionTabKey(EventGamesSection.pool)),
        );

        expect(
          history.locations.last,
          AppRoutes.eventDetailOf('e:0', tab: 'pool'),
        );
        expect(find.byKey(EventDetailScreen.poolSearchKey), findsOneWidget);
      });

      testWidgets('a tab told while a page of its own covers the event leaves '
          'that page and its location', (tester) async {
        // The screen tells a tab only while its route is current, which the
        // router doesn't rely on: it replaces only while the top location is
        // still the event's. Told here while Availability, the event's own
        // child, is on top, a replace would put the event in its place.
        final history = FakeBrowserHistory.install(tester);
        await pumpHosted(tester);
        routerOf(tester).go('/events/e-0');
        await tester.pumpAndSettle();
        unawaited(
          routerOf(tester).push<void>(AppRoutes.eventAvailabilityOf('e-0')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(EventAvailabilityScreen), findsOneWidget);
        expect(history.locations.last, AppRoutes.eventAvailabilityOf('e-0'));
        final entries = history.allLocations.length;

        final screen = find.byType(EventDetailScreen, skipOffstage: false);
        tester.widget<EventDetailScreen>(screen).onTabChanged!(
          tester.element(
            find
                .descendant(
                  of: screen,
                  matching: find.byType(Scaffold, skipOffstage: false),
                  skipOffstage: false,
                )
                .first,
          ),
          EventScreenTab.pool,
        );
        await tester.pumpAndSettle();

        expect(find.byType(EventAvailabilityScreen), findsOneWidget);
        expect(history.locations.last, AppRoutes.eventAvailabilityOf('e-0'));
        expect(history.allLocations, hasLength(entries));
      });

      testWidgets('a link to ?tab=pool opens the event on Pool', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        try {
          await pumpHosted(tester);

          routerOf(tester).go('/events/e-0?tab=pool');
          await tester.pumpAndSettle();

          expect(
            tester.getSemantics(
              find.byKey(
                EventDetailScreen.sectionTabKey(EventGamesSection.pool),
              ),
            ),
            isSemantics(isSelected: true),
          );
          expect(find.byKey(EventDetailScreen.poolSearchKey), findsOneWidget);
        } finally {
          handle.dispose();
        }
      });

      testWidgets('a link with an unknown tab opens Details', (tester) async {
        final handle = tester.ensureSemantics();
        try {
          await pumpHosted(tester);

          routerOf(tester).go('/events/e-0?tab=scores');
          await tester.pumpAndSettle();

          expect(
            tester.getSemantics(
              find.byKey(EventDetailScreen.tabKey(EventDetailTab.details)),
            ),
            isSemantics(isSelected: true),
          );
          expect(find.byKey(EventDetailScreen.datesKey), findsOneWidget);
        } finally {
          handle.dispose();
        }
      });

      testWidgets('a tab that settles once the location has gone elsewhere '
          'leaves it there', (tester) async {
        // The screen tells a tab only while its route is on top of its own
        // navigator, the navigation shell's. A page that comes in over the
        // whole shell leaves that route on top there until it has come in:
        // here an unknown location's not-found page, which matches no route,
        // so there is no event to replace and the router has no location to
        // report. Nothing writes the tab into the event's entry, or any
        // other.
        final history = FakeBrowserHistory.install(tester);
        await pumpHosted(tester);
        await choose(tester, find.byKey(UpcomingEventsSection.rowKey('e-0')));
        // Games is chosen, and the location moves before it settles.
        await tester.tap(
          find.byKey(EventDetailScreen.tabKey(EventDetailTab.games)),
        );
        await tester.pump();
        routerOf(tester).go('/nowhere');
        await tester.pumpAndSettle();

        expect(find.byType(EventDetailScreen), findsNothing);
        expect(find.byType(RouteNotFoundScreen), findsOneWidget);
        // No entry of the history names the tab, the event's own included.
        expect(
          history.allLocations.where(
            (location) => Uri.parse(
              location,
            ).queryParameters.containsKey(AppRoutes.eventTabParam),
          ),
          isEmpty,
        );
      });

      test("AppRoutes.eventPoolTab is the screen's own value", () {
        expect(AppRoutes.eventPoolTab, EventScreenTab.pool.query);
      });
    });
  });

  group('creating an event (#499)', () {
    GoRouter routerOf(WidgetTester tester) =>
        tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
            as GoRouter;

    /// Pumps home with all a create needs: a sender that delivers each one
    /// as `srv1`, and the person search.
    Future<void> pumpCreatable(
      WidgetTester tester, {
      int events = 1,
      bool withHouseholds = false,
      List<Household> moreHouseholds = const [],
      HouseholdRole? householdRole,
    }) => pumpHome(
      tester,
      events: events,
      withHouseholds: withHouseholds,
      moreHouseholds: moreHouseholds,
      householdRole: householdRole,
      sender: _DeliveringSender('srv1'),
      users: _MockUserRemote(),
    );

    Future<void> reveal(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
    }

    /// [text] as what the form's household picker shows.
    Finder pickerShows(String text) => find.descendant(
      of: find.byKey(CreateEventScreen.householdKey),
      matching: find.text(text),
    );

    testWidgets('New event on the overview opens the create form', (
      tester,
    ) async {
      await pumpCreatable(tester);
      await openTheOverview(tester);

      await tester.tap(find.byKey(EventOverviewScreen.createKey));
      await tester.pumpAndSettle();

      expect(find.byType(CreateEventScreen), findsOneWidget);
      // This session caches no households, so there are none to pick.
      expect(find.byKey(CreateEventScreen.householdKey), findsNothing);

      // Pushed above the overview, so back returns there.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(EventOverviewScreen), findsOneWidget);
    });

    testWidgets("a group page's New event opens it too", (tester) async {
      await pumpCreatable(tester, events: EventOverviewScreen.groupCap + 1);
      await openTheOverview(tester);
      await tester.tap(
        find.byKey(EventOverviewScreen.seeAllKey(EventGroup.upcoming)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(EventGroupScreen.createKey));
      await tester.pumpAndSettle();

      expect(find.byType(CreateEventScreen), findsOneWidget);
    });

    testWidgets('a created event replaces the form with its detail', (
      tester,
    ) async {
      await pumpCreatable(tester);
      await openTheOverview(tester);
      await tester.tap(find.byKey(EventOverviewScreen.createKey));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(CreateEventScreen.titleKey),
        'Game night',
      );
      // The title brings its caret into view on the next frame, which would
      // undo a reveal made before it.
      await tester.pumpAndSettle();
      // When it starts: the day and the time the pickers open on.
      final starts = find.widgetWithText(InkWell, 'Starts');
      await reveal(tester, starts);
      await tester.tap(starts);
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(CreateEventScreen.submitKey));
      await tester.tap(find.byKey(CreateEventScreen.submitKey));
      await tester.pumpAndSettle();

      // The event the server made, under its id.
      expect(find.byType(CreateEventScreen), findsNothing);
      expect(
        tester
            .widget<EventDetailScreen>(find.byType(EventDetailScreen))
            .eventId,
        'srv1',
      );
      expect(
        routerOf(tester).state.matchedLocation,
        AppRoutes.eventDetailOf('srv1'),
      );

      // Back is the overview the form was opened from. The spent form was
      // replaced, not pushed over, so back can't land on it (#162).
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(EventOverviewScreen), findsOneWidget);
      expect(find.byType(CreateEventScreen), findsNothing);
    });

    // #465: pages animate now, so a form the user left is still mounted for
    // its exit transition, and a create can answer inside it.
    testWidgets('a create that answers after the user went back leaves the '
        'overview open', (tester) async {
      final sender = _DeliveringSender('srv1');
      await pumpHome(tester, sender: sender, users: _MockUserRemote());
      await openTheOverview(tester);
      await tester.tap(find.byKey(EventOverviewScreen.createKey));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(CreateEventScreen.titleKey),
        'Game night',
      );
      await tester.pumpAndSettle();
      final starts = find.widgetWithText(InkWell, 'Starts');
      await reveal(tester, starts);
      await tester.tap(starts);
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(CreateEventScreen.submitKey));
      final held = sender.held = Completer<void>();
      await tester.tap(find.byKey(CreateEventScreen.submitKey));
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byType(CreateEventScreen, skipOffstage: false),
        findsOneWidget,
        reason: 'the form is still on its way out',
      );

      held.complete();
      await tester.pumpAndSettle();

      expect(find.byType(CreateEventScreen), findsNothing);
      expect(find.byType(EventDetailScreen), findsNothing);
      expect(find.byType(EventOverviewScreen), findsOneWidget);
    });

    // #321: on web the form has a browser history entry of its own, which
    // the detail must take over rather than follow.
    testWidgets('browser Back from the created event goes to the overview', (
      tester,
    ) async {
      final history = FakeBrowserHistory.install(tester);
      await pumpCreatable(tester);
      await openTheOverview(tester);
      await tester.tap(find.byKey(EventOverviewScreen.createKey));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(CreateEventScreen.titleKey),
        'Game night',
      );
      await tester.pumpAndSettle();
      final starts = find.widgetWithText(InkWell, 'Starts');
      await reveal(tester, starts);
      await tester.tap(starts);
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(CreateEventScreen.submitKey));
      await tester.tap(find.byKey(CreateEventScreen.submitKey));
      await tester.pumpAndSettle();
      expect(history.locations.last, AppRoutes.eventDetailOf('srv1'));

      await history.back();

      expect(find.byType(EventOverviewScreen), findsOneWidget);
      expect(find.byType(CreateEventScreen), findsNothing);
    });

    testWidgets("a household's New event opens the form with it picked", (
      tester,
    ) async {
      await pumpCreatable(
        tester,
        withHouseholds: true,
        householdRole: HouseholdRole.householdMember,
      );
      routerOf(tester).go(AppRoutes.householdDetailOf('h-1'));
      await tester.pumpAndSettle();

      await reveal(tester, find.byKey(HouseholdDetailScreen.newEventKey));
      await tester.tap(find.byKey(HouseholdDetailScreen.newEventKey));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<CreateEventScreen>(find.byType(CreateEventScreen))
            .householdId,
        'h-1',
      );
      // A member may create one there, so the form starts in it.
      expect(pickerShows('The Smiths'), findsOneWidget);
    });

    testWidgets('a household the user may not create in is not picked', (
      tester,
    ) async {
      // A guest lacks create:event:household, so the server would refuse
      // the create there.
      await pumpCreatable(
        tester,
        withHouseholds: true,
        householdRole: HouseholdRole.householdGuest,
      );

      routerOf(tester).go(AppRoutes.eventCreateOf(householdId: 'h-1'));
      await tester.pumpAndSettle();

      expect(find.byType(CreateEventScreen), findsOneWidget);
      expect(pickerShows('No household'), findsOneWidget);
      expect(pickerShows('The Smiths'), findsNothing);
    });

    testWidgets("going from one household's form straight to another's starts "
        'it in the second (#466)', (tester) async {
      await pumpCreatable(
        tester,
        withHouseholds: true,
        moreHouseholds: [
          Household(
            id: 'h-2',
            name: 'The Joneses',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        ],
        householdRole: HouseholdRole.householdMember,
      );
      routerOf(tester).go(AppRoutes.eventCreateOf(householdId: 'h-1'));
      await tester.pumpAndSettle();
      expect(pickerShows('The Smiths'), findsOneWidget);

      // The same page: go_router keys it by its path, which leaves the
      // household out.
      routerOf(tester).go(AppRoutes.eventCreateOf(householdId: 'h-2'));
      await tester.pumpAndSettle();

      expect(pickerShows('The Joneses'), findsOneWidget);
      expect(pickerShows('The Smiths'), findsNothing);
    });

    testWidgets('without a sync sender there is no New event', (tester) async {
      // The form sends the create straight away, through the sender, as the
      // household create does (#121). A session without one has no form.
      await pumpHome(
        tester,
        withHouseholds: true,
        householdRole: HouseholdRole.householdMember,
        users: _MockUserRemote(),
      );
      await openTheOverview(tester);
      expect(find.byKey(EventOverviewScreen.createKey), findsNothing);

      // Nor does a household offer one, though its role would allow it.
      routerOf(tester).go(AppRoutes.householdDetailOf('h-1'));
      await tester.pumpAndSettle();
      expect(find.byKey(HouseholdDetailScreen.roleKey), findsOneWidget);
      expect(find.byKey(HouseholdDetailScreen.newEventKey), findsNothing);

      // And a link to the form falls back.
      routerOf(tester).go(AppRoutes.eventCreate);
      await tester.pumpAndSettle();
      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(find.byType(CreateEventScreen), findsNothing);
    });

    testWidgets('without a person search there is no New event', (
      tester,
    ) async {
      // The form's invitee search reads it.
      await pumpHome(tester, sender: _DeliveringSender('srv1'));
      await openTheOverview(tester);
      expect(find.byKey(EventOverviewScreen.createKey), findsNothing);

      routerOf(tester).go(AppRoutes.eventCreate);
      await tester.pumpAndSettle();
      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(find.byType(CreateEventScreen), findsNothing);
    });
  });
}
