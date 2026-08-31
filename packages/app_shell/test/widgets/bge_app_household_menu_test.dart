import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockHouseholdRemoteDataSource extends Mock
    implements HouseholdRemoteDataSource {}

/// Exercises the household menu gate in `_buildHomeRoute`.
///
/// The entry is the **household list** (#269), replacing #129's
/// create-household entry — create moved to the list's own FAB. That
/// changes the gate, and the change is the point of this file: the list
/// reads the local cache, so it is gated on [HouseholdRepository] **alone**
/// (#269 D4), where create needed a [HouseholdRemoteDataSource] as well.
///
/// The two dependencies live in *different* scopes (#135), which is what
/// makes the distinction observable rather than theoretical:
///
/// - [HouseholdRemoteDataSource] is per-**server** (`registerServerNetwork`),
///   so it is registered from boot onward.
/// - [HouseholdRepository] is per-**user session** — installed on sign-in by
///   `UserSessionScopeInstaller` in the user tier, disposed on sign-out.
///
/// "Repository registered, remote absent" is the case that separates the
/// old gate from the new one: under #129's rule the entry vanished, under
/// #269's it stays and the list simply offers no create affordance.
///
/// Since #137 that case is no longer hypothetical: web's user tier registers
/// the repository and its server scope registers no household client until
/// #125, so web is the one composition that actually reaches it. Native does
/// not — `registerServerNetwork` registers the client unconditionally. The
/// consequence on web (an entry onto a permanently empty list) is recorded
/// at the gate in `bge_app.dart`; it is #269's decision to revisit, not this
/// file's to quietly change.
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
    final repository = _MockHouseholdRepository();
    // The list screen's bloc subscribes as soon as the route builds.
    when(repository.watchHouseholds)
        .thenAnswer((_) => Stream<List<Household>>.value(const []));

    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          householdRepository: withRepository ? repository : null,
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

  group('BgeApp home household gate (#269)', () {
    testWidgets('shows the households entry when the repository resolves', (
      tester,
    ) async {
      await pumpHomeDrawer(tester, withRepository: true, withRemote: true);

      expect(find.byKey(HomeScreen.entryKey('households')), findsOneWidget);
    });

    testWidgets('shows the households entry with no household client — the '
        'list reads the cache (#269 D4)', (tester) async {
      await pumpHomeDrawer(tester, withRepository: true, withRemote: false);

      // The case the old create-only gate got wrong. Reinstating
      // `isRegistered<HouseholdRemoteDataSource>()` in this gate would
      // pass every other test in this file but fail here.
      expect(find.byKey(HomeScreen.entryKey('households')), findsOneWidget);
    });

    testWidgets('hides the households entry when the per-user repository is '
        'absent — the real signed-out native state (#135)', (tester) async {
      await pumpHomeDrawer(tester, withRepository: false, withRemote: true);

      expect(find.byKey(HomeScreen.entryKey('households')), findsNothing);
      expect(find.byKey(HomeScreen.entryKey('send_feedback')), findsOneWidget);
    });

    testWidgets('hides the households entry when neither is registered — the '
        'web signed-out state, which carries no household client either '
        '(#137)', (tester) async {
      await pumpHomeDrawer(tester, withRepository: false, withRemote: false);

      expect(find.byKey(HomeScreen.entryKey('households')), findsNothing);
      // The scope-independent entries still render.
      expect(find.byKey(HomeScreen.entryKey('send_feedback')), findsOneWidget);
    });

    testWidgets('retires the create-household entry — create is the list '
        "screen's FAB now", (tester) async {
      await pumpHomeDrawer(tester, withRepository: true, withRemote: true);

      expect(find.byKey(HomeScreen.entryKey('create_household')), findsNothing);
    });

    testWidgets('opens the list from the drawer', (tester) async {
      await pumpHomeDrawer(tester, withRepository: true, withRemote: true);

      await tester.tap(find.byKey(HomeScreen.entryKey('households')));
      await tester.pumpAndSettle();

      // The container carries a repository, so the route resolves its real
      // screen rather than the NotYetAvailable fallback.
      expect(find.byType(HouseholdListScreen), findsOneWidget);
    });
  });
}
