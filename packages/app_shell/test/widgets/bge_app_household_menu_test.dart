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
/// entry appears only when **both** household dependencies resolve from the
/// active server's container (the same registration check
/// `_buildCreateHouseholdRoute` applies), so it can never dead-end on the
/// back-button-less NotYetAvailableScreen.
///
/// The two dependencies now live in *different* scopes (#135), so the gate
/// is genuinely two-sided rather than one check written twice:
///
/// - [HouseholdRemoteDataSource] is per-**server** (`registerServerNetwork`),
///   so it is registered from boot onward.
/// - [HouseholdRepository] is per-**user session** — installed on sign-in by
///   `HouseholdScopeInstaller` in the user tier, disposed on sign-out.
///
/// "Remote registered, repository absent" is therefore a real reachable
/// native state (signed out, or a session whose activation failed), not a
/// hypothetical: the tests below cover it directly. Web currently has
/// neither until its user tier lands (#137).
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

  /// Pumps the home drawer with each household dependency independently
  /// present or absent, so a regression that drops either half of the gate
  /// fails a test.
  Future<void> pumpHomeDrawer(
    WidgetTester tester, {
    required bool withRepository,
    required bool withRemote,
  }) async {
    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          householdRepository: withRepository
              ? _MockHouseholdRepository()
              : null,
          householdRemoteDataSource: withRemote
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
    testWidgets('shows create-household when both household dependencies '
        'are registered', (tester) async {
      await pumpHomeDrawer(tester, withRepository: true, withRemote: true);

      expect(
        find.byKey(HomeScreen.entryKey('create_household')),
        findsOneWidget,
      );
    });

    testWidgets('hides create-household when the per-user repository is '
        'absent but the per-server remote is registered — the real '
        'signed-out native state (#135)', (tester) async {
      await pumpHomeDrawer(tester, withRepository: false, withRemote: true);

      // Dropping `isRegistered<HouseholdRepository>()` from the gate would
      // pass every other test in this file but fail here.
      expect(find.byKey(HomeScreen.entryKey('create_household')), findsNothing);
      expect(find.byKey(HomeScreen.entryKey('send_feedback')), findsOneWidget);
    });

    testWidgets('hides create-household when the per-server remote is absent '
        'but a repository is registered', (tester) async {
      await pumpHomeDrawer(tester, withRepository: true, withRemote: false);

      // The mirror case: dropping the remote half of the gate would pass
      // every other test in this file but fail here.
      expect(find.byKey(HomeScreen.entryKey('create_household')), findsNothing);
      expect(find.byKey(HomeScreen.entryKey('send_feedback')), findsOneWidget);
    });

    testWidgets('hides create-household when neither is registered — web '
        'until its user tier lands (#137)', (tester) async {
      await pumpHomeDrawer(tester, withRepository: false, withRemote: false);

      expect(find.byKey(HomeScreen.entryKey('create_household')), findsNothing);
      // The scope-independent entries still render.
      expect(find.byKey(HomeScreen.entryKey('send_feedback')), findsOneWidget);
    });
  });
}
