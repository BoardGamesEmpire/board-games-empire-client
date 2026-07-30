import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockHouseholdRemoteDataSource extends Mock
    implements HouseholdRemoteDataSource {}

/// Exercises the #129 create-household menu gate in `_buildHomeRoute`: the
/// entry appears only where the per-server household scope is installed (the
/// same registration check `_buildCreateHouseholdRoute` applies), so it can
/// never dead-end on the back-button-less NotYetAvailableScreen — web never
/// wires the scope, and native only wires it once #128 lands.
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

  Future<void> pumpHomeDrawer(
    WidgetTester tester, {
    required bool withHouseholdScope,
  }) async {
    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          householdRepository: withHouseholdScope
              ? _MockHouseholdRepository()
              : null,
          householdRemoteDataSource: withHouseholdScope
              ? _MockHouseholdRemoteDataSource()
              : null,
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
    // Menu entries live in the (closed) navigation drawer — open it.
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
  }

  group('BgeApp home create-household gate (#129)', () {
    testWidgets('shows create-household when the household scope is '
        'registered', (tester) async {
      await pumpHomeDrawer(tester, withHouseholdScope: true);

      expect(
        find.byKey(HomeScreen.entryKey('create_household')),
        findsOneWidget,
      );
    });

    testWidgets('hides create-household when the scope is not registered', (
      tester,
    ) async {
      await pumpHomeDrawer(tester, withHouseholdScope: false);

      expect(find.byKey(HomeScreen.entryKey('create_household')), findsNothing);
      // The scope-independent entries still render.
      expect(find.byKey(HomeScreen.entryKey('send_feedback')), findsOneWidget);
    });
  });
}
