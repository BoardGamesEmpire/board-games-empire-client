import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:events/events.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
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

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockEventRepository extends Mock implements EventRepository {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockEventRemote extends Mock implements EventRemoteDataSource {}

class _MockUserRemote extends Mock implements UserRemoteDataSource {}

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

/// The #497 shell wiring through the real composition: the drawer entry and
/// its gate, the overview and group routes resolving the session's
/// repository, households and status, the retry reaching the events' own
/// refresher, and the entry trigger reaching the session's rehydrator.
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
    registerFallbackValue(EventAccessSource.read);
    registerFallbackValue(const EventDraft(title: 'x'));
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
  /// replaces what every `watchEvent` emits, for a cache the test drives.
  /// [sender] and [users] are what the create form sends through and finds
  /// invitees with, and a create writes the event here as `ev_local`.
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
    bool failedPass = false,
    EventRefresher? refresher,
    SessionRehydrator? rehydrator,
    SessionIdentityGuard? guard,
    SyncOperationSender? sender,
    UserRemoteDataSource? users,
  }) async {
    when(repository.watchAttendingEventListItems).thenAnswer(
      (_) => Stream.value([for (var n = 0; n < events; n++) _upcoming('e-$n')]),
    );
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
          FakeAuthRepository(initialSession: sampleSession()),
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

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
  }

  Future<void> openTheOverview(WidgetTester tester) async {
    await openDrawer(tester);
    await tester.tap(find.byKey(HomeScreen.entryKey('events')));
    await tester.pumpAndSettle();
  }

  group('the drawer entry', () {
    testWidgets('shows when the session has an event repository', (
      tester,
    ) async {
      await pumpHome(tester);
      await openDrawer(tester);

      expect(find.byKey(HomeScreen.entryKey('events')), findsOneWidget);
      expect(find.text('Events'), findsOneWidget);
    });

    testWidgets('hides when there is no user session', (tester) async {
      // The repository lives in the user tier, which sign-out tears down.
      await pumpHome(tester, withRepository: false);
      await openDrawer(tester);

      expect(find.byKey(HomeScreen.entryKey('events')), findsNothing);
      expect(find.byKey(HomeScreen.entryKey('send_feedback')), findsOneWidget);
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
      // events would replace the stack with the overview: no back button, no
      // drawer, and on desktop no way out (#308's household bug, which this
      // is the events' guard against).
      final remote = _MockEventRemote();
      when(() => remote.fetchEvent(any())).thenAnswer(
        (_) async => throw const EventRemoteNotFoundException('gone'),
      );
      // The cache holds nothing for the event the user opened, and never
      // closes.
      final cache = StreamController<EventDetail?>()..add(null);
      addTearDown(() => unawaited(cache.close()));
      await pumpHome(tester, remote: remote, detailCache: cache.stream);
      await openTheOverview(tester);

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

      testWidgets('the session guard is asked around the delete too', (
        tester,
      ) async {
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
