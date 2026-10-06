import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:household/household.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockHouseholdRemoteDataSource extends Mock
    implements HouseholdRemoteDataSource {}

class _MockSyncQueueRepository extends Mock implements SyncQueueRepository {}

const _localId = 'hh_local';
const _serverId = 'hh_server';

Household _household(String id, {bool localOnly = false}) => Household(
  id: id,
  name: 'Sunday Crew',
  isDirty: localOnly,
  isLocalOnly: localOnly,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

HouseholdMember _member(String householdId) => HouseholdMember(
  id: 'm-u-me',
  userId: 'u-me',
  householdId: householdId,
  role: HouseholdRole.householdOwner,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// Exercises `_buildCreateHouseholdRoute`'s navigation on success (#271)
/// through the real composition — the half
/// `create_household_screen_test.dart` cannot reach, because asserting "back
/// lands on the list, never on the spent form" needs a real back stack.
///
/// Both of #271's route criteria are here, and since #308 they are one
/// mechanism reached two ways:
///
/// - **The drawer path** (drawer → list → FAB → create) has the pushed list
///   route beneath the form, so the replace leaves it there and back pops
///   onto it, with home still beneath that.
/// - **Direct entry** (a `go` to the create route; nothing in the app does
///   this today) has the list beneath too, because create is the list's
///   child: go_router builds the parent for a `go`. The replace swaps create
///   for the detail screen within that stack, and back pops onto the list.
void main() {
  late _MockAppBootstrapCubit cubit;
  late Storage storage;
  late _MockHouseholdRepository repository;
  late _MockHouseholdRemoteDataSource remote;
  late _MockSyncQueueRepository syncQueue;

  /// The local cache, standing in for the drift-backed one. Stateful on
  /// purpose: the destination renders from the cache (#271's third
  /// acceptance criterion), so a fixture that never gains the household
  /// would send every one of these tests to the not-found surface and prove
  /// nothing about where the user landed.
  late List<Household> cache;
  late StreamController<List<Household>> cacheChanges;

  void cacheHolds(List<Household> households) {
    cache = households;
    cacheChanges.add(households);
  }

  setUpAll(() => registerFallbackValue(_household(_serverId)));

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    repository = _MockHouseholdRepository();
    remote = _MockHouseholdRemoteDataSource();
    // The inline send claims its op first (#430); nothing else holds it.
    syncQueue = _MockSyncQueueRepository();
    when(() => syncQueue.claim(any())).thenAnswer((_) async => true);
    when(() => syncQueue.release(any())).thenAnswer((_) async {});
    when(() => syncQueue.markFailed(any(), error: any(named: 'error')))
        .thenAnswer((_) async {});

    // Empty to begin with: the list is where the user starts, and the
    // household under test is the one they are about to create.
    cache = const [];
    cacheChanges = StreamController<List<Household>>.broadcast();
    addTearDown(cacheChanges.close);

    // Snapshot then updates, for every subscriber — the list bloc subscribes
    // before the create, the detail bloc after it.
    when(repository.watchHouseholds).thenAnswer((_) async* {
      yield cache;
      yield* cacheChanges.stream;
    });
    when(() => repository.watchMembers(any())).thenAnswer(
      (invocation) => Stream<List<HouseholdMember>>.value([
        _member(invocation.positionalArguments.first as String),
      ]),
    );
    when(() => repository.getCurrentUserMember(any())).thenAnswer(
      (invocation) async =>
          _member(invocation.positionalArguments.first as String),
    );
    when(
      () => repository.create(
        name: any(named: 'name'),
        description: any(named: 'description'),
      ),
    ).thenAnswer((_) async {
      final local = _household(_localId, localOnly: true);
      cacheHolds([local]);
      return (household: local, syncQueueId: 'q1');
    });
    when(
      () => repository.reconcileCreatedHousehold(
        any(),
        localId: any(named: 'localId'),
        completedSyncQueueId: any(named: 'completedSyncQueueId'),
      ),
    ).thenAnswer((invocation) async {
      // What the real reconcile does to the cache: the optimistic row is
      // replaced by the server-confirmed one, under the canonical id.
      cacheHolds([invocation.positionalArguments.first as Household]);
    });
    when(
      () => remote.createHousehold(
        name: any(named: 'name'),
        clientRequestId: any(named: 'clientRequestId'),
        description: any(named: 'description'),
      ),
    ).thenAnswer((_) async => _household(_serverId));
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    HouseholdHydrationStatus? hydrationStatus,
  }) async {
    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          householdRepository: repository,
          // The create route's guard needs the remote and the queue, unlike
          // the list's and the detail's (#269).
          householdRemoteDataSource: remote,
          syncQueueRepository: syncQueue,
          householdHydrationStatus: hydrationStatus,
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

  GoRouter routerOf(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
          as GoRouter;

  Future<void> submitTheForm(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(CreateHouseholdForm.nameFieldKey),
      'Sunday Crew',
    );
    await tester.tap(find.byKey(CreateHouseholdForm.submitButtonKey));
    await tester.pumpAndSettle();
  }

  group('BgeApp create-household navigation (#271)', () {
    testWidgets('the drawer path lands on the detail screen, and back goes to '
        'the list', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HomeScreen.entryKey('households')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HouseholdListScreen.createFabKey));
      await tester.pumpAndSettle();
      expect(find.byType(CreateHouseholdScreen), findsOneWidget);

      await submitTheForm(tester);

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
      expect(find.byType(CreateHouseholdScreen), findsNothing);
      expect(
        routerOf(tester).state.matchedLocation,
        AppRoutes.householdDetailOf(_serverId),
      );
      // The household itself, not the not-found surface: the destination
      // resolves from the cache the create just wrote.
      expect(find.text('Sunday Crew'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(HouseholdListScreen), findsOneWidget);
      expect(
        find.byType(CreateHouseholdScreen),
        findsNothing,
        reason: 'the spent form was replaced, not pushed over (#271)',
      );
    });

    testWidgets('direct entry lands on the detail screen, and back goes to '
        'the list', (tester) async {
      await pumpApp(tester);

      // Nothing pushed first — the case #162 was reported against, when
      // this left the new household's screen alone on the stack.
      routerOf(tester).go(AppRoutes.householdCreate);
      await tester.pumpAndSettle();
      expect(find.byType(CreateHouseholdScreen), findsOneWidget);

      await submitTheForm(tester);

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
      expect(find.byType(CreateHouseholdScreen), findsNothing);
      expect(find.text('Sunday Crew'), findsOneWidget);

      // The app bar's own back button: the list built beneath the create
      // route is still there once the form has been replaced (#308).
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(HouseholdListScreen), findsOneWidget);
      expect(find.byType(CreateHouseholdScreen), findsNothing);
    });

    testWidgets('a queued household navigates identically, on its local id', (
      tester,
    ) async {
      // The server never answers, so the household is created locally and
      // left queued. It is still a household, and #269's badge carries the
      // state — so the destination is the same, addressed by the optimistic
      // local id. (A later reconcile remapping that id is #306.)
      when(
        () => remote.createHousehold(
          name: any(named: 'name'),
          clientRequestId: any(named: 'clientRequestId'),
          description: any(named: 'description'),
        ),
      ).thenThrow(const HouseholdRemoteTransientException('offline'));

      await pumpApp(tester);
      routerOf(tester).go(AppRoutes.householdCreate);
      await tester.pumpAndSettle();

      await submitTheForm(tester);

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
      expect(
        routerOf(tester).state.matchedLocation,
        AppRoutes.householdDetailOf(_localId),
      );
      verifyNever(
        () => repository.reconcileCreatedHousehold(
          any(),
          localId: any(named: 'localId'),
          completedSyncQueueId: any(named: 'completedSyncQueueId'),
        ),
      );
    });
  });

  group('a create clears the staleness window (#300 D3, D9)', () {
    /// A status whose last pass succeeded and has not aged out — the state
    /// in which the window would otherwise suppress the next entry's pass.
    HouseholdHydrationStatus freshlyRefreshed() {
      final status = HouseholdHydrationStatus(
        now: () => DateTime.utc(2026, 8, 27, 12),
      )..started();
      status.finished(HydrateOutcome.complete);
      addTearDown(status.close);
      return status;
    }

    testWidgets('creating a household drops the timestamp', (tester) async {
      // D3's reasoning: a create makes the local set stale by definition, so
      // the next entry re-hydrates rather than waiting out the remaining
      // minutes. The invalidation belongs to *mutation*, and the
      // composition root is where mutations are already wired (#300 D9) —
      // which is what gives #122's membership mutations the same hook.
      final status = freshlyRefreshed();
      expect(status.sinceRefresh, isNotNull);

      await pumpApp(tester, hydrationStatus: status);
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HomeScreen.entryKey('households')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HouseholdListScreen.createFabKey));
      await tester.pumpAndSettle();

      await submitTheForm(tester);

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
      expect(status.sinceRefresh, isNull);
    });

    testWidgets('the state itself is untouched — the rows we have are still '
        'the rows we have', (tester) async {
      final status = freshlyRefreshed();

      await pumpApp(tester, hydrationStatus: status);
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HomeScreen.entryKey('households')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HouseholdListScreen.createFabKey));
      await tester.pumpAndSettle();

      await submitTheForm(tester);

      // Not `running` and not `failed`: nothing is in flight and nothing
      // failed. Only the claim that the set is current went away.
      expect(status.state, equals(HouseholdHydrationState.refreshed));
    });

    testWidgets('a composition with no hydration status still creates', (
      tester,
    ) async {
      // The #137 path: no household client means no status to invalidate,
      // and a create must not care.
      await pumpApp(tester);
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HomeScreen.entryKey('households')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(HouseholdListScreen.createFabKey));
      await tester.pumpAndSettle();

      await submitTheForm(tester);

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
    });
  });
}
