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
/// Both of #271's route criteria are here, and they are different mechanisms
/// rather than one:
///
/// - **The drawer path** (drawer → list → FAB → create) has a list route
///   beneath the form, so the replace leaves it there and back pops onto it.
/// - **Direct entry** (a restored route, a typed URL on web, a deep link
///   later) has nothing beneath. go_router's `pushReplacement` degrades to a
///   plain `go` when removing the top match empties the stack
///   (`parser.dart:300-312`), so the detail screen becomes the base location
///   and the *app-bar* back — `ctx.go(AppRoutes.household)`, wired by #270 —
///   is what lands on the list. A system or browser back from there leaves
///   the app: pre-existing #270 behavior, deliberately out of scope (#271 D3).
void main() {
  late _MockAppBootstrapCubit cubit;
  late Storage storage;
  late _MockHouseholdRepository repository;
  late _MockHouseholdRemoteDataSource remote;

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
        description: any(named: 'description'),
      ),
    ).thenAnswer((_) async => _household(_serverId));
  });

  Future<void> pumpApp(WidgetTester tester) async {
    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          householdRepository: repository,
          // The create route's guard needs the remote, unlike the list's and
          // the detail's (#269 D4).
          householdRemoteDataSource: remote,
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

    testWidgets('direct entry lands on the detail screen, and its back '
        'affordance goes to the list', (tester) async {
      await pumpApp(tester);

      // A restored route or a typed URL arrives this way, with no list
      // route beneath — the case #162 was reported against.
      routerOf(tester).go(AppRoutes.householdCreate);
      await tester.pumpAndSettle();
      expect(find.byType(CreateHouseholdScreen), findsOneWidget);

      await submitTheForm(tester);

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
      expect(find.byType(CreateHouseholdScreen), findsNothing);
      expect(find.text('Sunday Crew'), findsOneWidget);

      // The screen supplies this itself: with nothing beneath, the app bar
      // would imply no leading button at all (#271).
      await tester.tap(find.byKey(HouseholdDetailScreen.backKey));
      await tester.pumpAndSettle();

      expect(find.byType(HouseholdListScreen), findsOneWidget);
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
}
