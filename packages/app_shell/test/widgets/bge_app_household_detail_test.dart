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

HouseholdMember _member(
  String userId, {
  String householdId = _id,
  HouseholdRole role = HouseholdRole.householdOwner,
}) => HouseholdMember(
  id: 'm-$householdId-$userId',
  userId: userId,
  householdId: householdId,
  role: role,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// [text] in the current user's "Your role" block. Each roster row says its
/// member's role too (#304).
Finder _inYourRole(String text) => find.descendant(
  of: find.byKey(HouseholdDetailScreen.roleKey),
  matching: find.text(text),
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
  ///
  /// [laterCache] carries what the cache says after that first answer, to
  /// every subscriber — for a household that disappears under an open
  /// screen.
  Future<void> pumpHome(
    WidgetTester tester, {
    bool withRepository = true,
    Stream<List<Household>>? laterCache,
    List<Household>? households,
    Map<String, List<HouseholdMember>> rosters = const {},
  }) async {
    final repository = _MockHouseholdRepository();
    when(repository.watchHouseholds).thenAnswer((_) async* {
      yield households ?? [_household(_id)];
      if (laterCache != null) yield* laterCache;
    });
    // A household without a roster of its own has the viewer as its owner.
    List<HouseholdMember> rosterOf(String id) =>
        rosters[id] ?? [_member('u-me', householdId: id)];
    when(() => repository.watchMembers(any())).thenAnswer(
      (invocation) => Stream<List<HouseholdMember>>.value(
        rosterOf(invocation.positionalArguments.first as String),
      ),
    );
    when(() => repository.getCurrentUserMember(any())).thenAnswer(
      (invocation) async =>
          rosterOf(invocation.positionalArguments.first as String)
              .firstWhere((member) => member.userId == 'u-me'),
    );

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
      expect(_inYourRole('Owner'), findsOneWidget);
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

    testWidgets('the not-found way back returns to the list, with home still '
        'beneath it (#308)', (tester) async {
      // Purge (#268) can delete a household under an open detail screen,
      // which is how the ordinary drawer path reaches not-found. That
      // surface's button used to `go` to the list, replacing the whole stack
      // with it: no back button, no drawer, and on desktop no way out.
      final cache = StreamController<List<Household>>.broadcast();
      addTearDown(cache.close);
      await pumpHome(tester, laterCache: cache.stream);
      await openDetailFromTheList(tester);
      expect(find.text('Sunday Crew'), findsOneWidget);

      cache.add(const []);
      await tester.pumpAndSettle();
      expect(find.byKey(HouseholdDetailScreen.notFoundKey), findsOneWidget);

      await tester.tap(find.byKey(HouseholdDetailScreen.notFoundBackKey));
      await tester.pumpAndSettle();

      expect(find.byType(HouseholdListScreen), findsOneWidget);
      expect(find.byType(HouseholdDetailScreen), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('reaches the detail screen with no HouseholdRemoteDataSource '
        '— the read never calls the server (#269 D4)', (tester) async {
      // Nothing in this file registers a remote. Reinstating that
      // requirement in the detail guard would fail here and nowhere else.
      await pumpHome(tester);

      await openDetailFromTheList(tester);

      expect(find.byType(HouseholdDetailScreen), findsOneWidget);
    });

    testWidgets('going from one household straight to another shows the '
        'second (#466)', (tester) async {
      // go_router keeps the page when only the id parameter changes, so the
      // screen is rebuilt in place. A bloc created for the first id would
      // go on showing it under the second id's path.
      await pumpHome(
        tester,
        households: [
          _household('hh_a', name: 'Alpha Crew'),
          _household('hh_b', name: 'Beta Crew'),
        ],
        rosters: {
          'hh_b': [
            _member('u-owner', householdId: 'hh_b'),
            _member(
              'u-me',
              householdId: 'hh_b',
              role: HouseholdRole.householdMember,
            ),
          ],
        },
      );
      final router =
          tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter;

      router.go(AppRoutes.householdDetailOf('hh_a'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha Crew'), findsOneWidget);
      expect(find.text('1 member'), findsOneWidget);
      expect(_inYourRole('Owner'), findsOneWidget);

      router.go(AppRoutes.householdDetailOf('hh_b'));
      await tester.pumpAndSettle();

      expect(find.text('Beta Crew'), findsOneWidget);
      expect(find.text('Alpha Crew'), findsNothing);
      expect(find.text('2 members'), findsOneWidget);
      expect(_inYourRole('Member'), findsOneWidget);
      expect(_inYourRole('Owner'), findsNothing);
    });

    testWidgets('falls back to NotYetAvailable when the per-user repository '
        'is absent (#135)', (tester) async {
      await pumpHome(tester, withRepository: false);

      // The drawer entry is gated too, so navigate the route directly, as
      // a consumed deep link will (#243).
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
