import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

Household _household(String id) => Household(
  id: id,
  name: 'Sunday Crew',
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

/// Exercises the #300 retry wiring through the real composition: the route
/// builders resolving [HouseholdRefresher] off the active server's
/// container, and the banner button reaching it.
///
/// The screens' own behaviour is pinned in the household package; what can
/// only be checked here is that the callback the screens are handed is the
/// one the session actually registered — and that a container without one
/// still renders a working screen (#137).
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

  /// Pumps the app with a cache holding one household and a hydrate whose
  /// last pass **failed** — the state the banner and its retry live in.
  Future<HouseholdHydrationStatus> pumpHome(
    WidgetTester tester, {
    HouseholdRefresher? refresher,
  }) async {
    final repository = _MockHouseholdRepository();
    when(
      repository.watchHouseholds,
    ).thenAnswer((_) => Stream<List<Household>>.value([_household(_id)]));
    when(
      () => repository.watchMembers(any()),
    ).thenAnswer((_) => Stream<List<HouseholdMember>>.value([_member('u-me')]));
    when(
      () => repository.getCurrentUserMember(any()),
    ).thenAnswer((_) async => _member('u-me'));

    final status = HouseholdHydrationStatus()
      ..started()
      ..finished(HydrateOutcome.failed);
    addTearDown(status.close);

    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          householdRepository: repository,
          householdHydrationStatus: status,
          householdRefresher: refresher,
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
    return status;
  }

  Future<void> openTheList(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(HomeScreen.entryKey('households')));
    await tester.pumpAndSettle();
  }

  group('BgeApp household retry wiring (#300)', () {
    testWidgets('the list banner reaches the session refresher', (
      tester,
    ) async {
      var calls = 0;
      await pumpHome(
        tester,
        refresher: HouseholdRefresher(() async => calls++),
      );
      await openTheList(tester);

      expect(find.byKey(HouseholdListScreen.refreshBannerKey), findsOneWidget);
      await tester.tap(find.byKey(HouseholdListScreen.refreshRetryKey));
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('the detail banner reaches the same refresher (#300 D10)', (
      tester,
    ) async {
      var calls = 0;
      await pumpHome(
        tester,
        refresher: HouseholdRefresher(() async => calls++),
      );
      await openTheList(tester);
      await tester.tap(find.byKey(HouseholdListScreen.rowKey(_id)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(HouseholdDetailScreen.refreshRetryKey));
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('a container with no refresher still renders the banner', (
      tester,
    ) async {
      // Web until #137, and any composition that runs no drain: the banner
      // still reports the stale list, and simply offers nothing to press.
      await pumpHome(tester);
      await openTheList(tester);

      expect(find.byKey(HouseholdListScreen.refreshBannerKey), findsOneWidget);
      expect(find.byKey(HouseholdListScreen.refreshRetryKey), findsNothing);
    });
  });
}
