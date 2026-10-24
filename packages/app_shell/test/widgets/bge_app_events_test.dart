import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:events/events.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockEventRepository extends Mock implements EventRepository {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

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

/// The #497 shell wiring through the real composition: the drawer entry and
/// its gate, the overview and group routes resolving the session's
/// repository, households and status, the retry reaching the events' own
/// refresher, and the entry trigger reaching the session's rehydrator.
///
/// The screens' own behaviour is pinned in `events`. What only this file can
/// check is that they are handed what the session registered, and that a
/// container without the optional parts still renders them.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  /// Pumps home with a cache holding [events] upcoming events. [withRepository]
  /// false is a signed-out session, where the user tier is gone.
  /// [failedPass] publishes a status whose last pass failed, which is where
  /// the banner and its retry live. [withHouseholds] caches `h-1`.
  Future<void> pumpHome(
    WidgetTester tester, {
    int events = 1,
    bool withRepository = true,
    bool withHouseholds = false,
    bool failedPass = false,
    EventRefresher? refresher,
    SessionRehydrator? rehydrator,
  }) async {
    final repository = _MockEventRepository();
    when(repository.watchAttendingEventListItems).thenAnswer(
      (_) => Stream.value([for (var n = 0; n < events; n++) _upcoming('e-$n')]),
    );

    HouseholdRepository? households;
    if (withHouseholds) {
      households = _MockHouseholdRepository();
      when(households.watchHouseholds).thenAnswer(
        (_) => Stream.value([
          Household(
            id: 'h-1',
            name: 'The Smiths',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        ]),
      );
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
          sessionRehydrator: rehydrator,
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
}
