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

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

const _id = 'hh_1';

Household _household(String id, {String name = 'Sunday Crew'}) => Household(
  id: id,
  name: name,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

HouseholdMember _member(String userId) => HouseholdMember(
  id: 'm-$userId',
  userId: userId,
  householdId: _id,
  role: HouseholdRole.householdOwner,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// Exercises `_buildHouseholdDetailRoute` (#270) through the real
/// composition, which is the half `household_detail_route_test.dart` cannot
/// reach: that file pins the *route table* against injected builders, this
/// one pins the **builder's own guard** and the list → detail path a user
/// actually walks.
///
/// The guard is [HouseholdRepository] **alone**, matching the list's (#269
/// D4) and deliberately not the create route's: the detail screen reads the
/// local cache and never calls the server, so a container without a
/// `HouseholdRemoteDataSource` must still reach it.
void main() {
  late _MockAppBootstrapCubit cubit;
  late Storage storage;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  /// Pumps the app at the home drawer with a household cache holding one
  /// household. [withRepository] false is the signed-out native state and
  /// web until its user tier lands (#137).
  Future<void> pumpHome(
    WidgetTester tester, {
    bool withRepository = true,
  }) async {
    final repository = _MockHouseholdRepository();
    when(repository.watchHouseholds)
        .thenAnswer((_) => Stream<List<Household>>.value([_household(_id)]));
    when(
      () => repository.watchMembers(any()),
    ).thenAnswer((_) => Stream<List<HouseholdMember>>.value([_member('u-me')]));
    when(() => repository.getCurrentUserMember(any()))
        .thenAnswer((_) async => _member('u-me'));

    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          // No remote data source anywhere in this file: the detail route
          // must not need one.
          householdRepository: withRepository ? repository : null,
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

  /// Walks the real path: drawer → list → tap the row.
  Future<void> openDetailFromTheList(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(HomeScreen.entryKey('households')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(HouseholdListScreen.rowKey(_id)));
    await tester.pumpAndSettle();
  }

  group('BgeApp household detail wiring (#270)', () {
    testWidgets('a list row opens the real detail screen', (tester) async {
      await pumpHome(tester);

      await openDetailFromTheList(tester);

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
      expect(find.byType(HouseholdListScreen), findsNothing);
    });

    testWidgets('the detail screen renders the household it was opened for', (
      tester,
    ) async {
      await pumpHome(tester);

      await openDetailFromTheList(tester);

      expect(find.text('Sunday Crew'), findsOneWidget);
      expect(find.text('1 member'), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
    });

    testWidgets('back from the detail screen lands on the list', (
      tester,
    ) async {
      // The row pushes rather than replaces, so the list is still beneath.
      await pumpHome(tester);
      await openDetailFromTheList(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(HouseholdListScreen), findsOneWidget);
    });

    testWidgets('reaches the detail screen with no HouseholdRemoteDataSource '
        '— the read never calls the server (#269 D4)', (tester) async {
      // Nothing in this file registers a remote. Reinstating that
      // requirement in the detail guard would fail here and nowhere else.
      await pumpHome(tester);

      await openDetailFromTheList(tester);

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailable when the per-user repository '
        'is absent (#135)', (tester) async {
      await pumpHome(tester, withRepository: false);

      // The drawer entry is gated too, so navigate the route directly —
      // a restored route or a deep link arrives this way.
      final router =
          tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter;
      router.go(AppRoutes.householdDetailOf(_id));
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(find.byType(HouseholdDetailScreen), findsNothing);
    });
  });
}
