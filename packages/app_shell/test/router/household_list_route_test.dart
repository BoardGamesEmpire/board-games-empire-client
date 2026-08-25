import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// A marker the household-list builder returns, so the test can tell the
/// builder's screen from the [NotYetAvailableScreen] fallback.
const _listMarkerKey = Key('household_list_route_marker');
const _createMarkerKey = Key('household_create_route_marker');

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    required AppBootstrapState initialState,
    HouseholdListScreenBuilder? householdListBuilder,
    CreateHouseholdScreenBuilder? createHouseholdBuilder,
  }) async {
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: initialState,
    );
    final listenable = BootstrapStreamListenable(cubit.stream);
    final router = buildAppRouter(
      bootstrapCubit: cubit,
      refreshListenable: listenable,
      householdListBuilder: householdListBuilder,
      createHouseholdBuilder: createHouseholdBuilder,
    );
    addTearDown(() {
      router.dispose();
      listenable.dispose();
    });
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: ShellLocalizations.localizationsDelegates,
        supportedLocales: ShellLocalizations.supportedLocales,
      ),
    );
    await tester.pump();
    return router;
  }

  group('buildAppRouter — household-list route (#269)', () {
    testWidgets('resolves the household-list builder when supplied', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        householdListBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _listMarkerKey)),
      );

      router.go(AppRoutes.household);
      await tester.pumpAndSettle();

      expect(find.byKey(_listMarkerKey), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailable when no builder is supplied', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );

      router.go(AppRoutes.household);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('is not a bootstrap location — a ready app is not bounced '
        'off it', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        householdListBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _listMarkerKey)),
      );

      router.go(AppRoutes.household);
      await tester.pumpAndSettle();

      expect(find.byKey(_listMarkerKey), findsOneWidget);
    });

    testWidgets('is a different route from household-create, not a prefix '
        'match for it', (tester) async {
      // `/household` and `/household/create` differ by one segment. A
      // route table that matched the list for both would silently retire
      // the create flow the FAB pushes.
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        householdListBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _listMarkerKey)),
        createHouseholdBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _createMarkerKey)),
      );

      router.go(AppRoutes.householdCreate);
      await tester.pumpAndSettle();

      expect(find.byKey(_createMarkerKey), findsOneWidget);
      expect(find.byKey(_listMarkerKey), findsNothing);
    });
  });
}
