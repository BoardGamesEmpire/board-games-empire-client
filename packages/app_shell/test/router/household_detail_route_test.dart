import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

const _detailMarkerKey = Key('household_detail_route_marker');
const _createMarkerKey = Key('household_create_route_marker');
const _listMarkerKey = Key('household_list_route_marker');

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    required AppBootstrapState initialState,
    HouseholdListScreenBuilder? householdListBuilder,
    HouseholdDetailScreenBuilder? householdDetailBuilder,
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
      householdDetailBuilder: householdDetailBuilder,
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

  group('buildAppRouter — household-detail route (#270)', () {
    testWidgets('resolves the detail builder with the id from the path', (
      tester,
    ) async {
      String? seen;
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        householdDetailBuilder: (_, id) {
          seen = id;
          return const Scaffold(body: SizedBox(key: _detailMarkerKey));
        },
      );

      router.go(AppRoutes.householdDetailOf('hh_abc123'));
      await tester.pumpAndSettle();

      expect(find.byKey(_detailMarkerKey), findsOneWidget);
      expect(seen, 'hh_abc123');
    });

    testWidgets('falls back to NotYetAvailable when no builder is supplied', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );

      router.go(AppRoutes.householdDetailOf('hh_abc123'));
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('is not a bootstrap location — a ready app is not bounced '
        'off it', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        householdDetailBuilder: (_, _) =>
            const Scaffold(body: SizedBox(key: _detailMarkerKey)),
      );

      router.go(AppRoutes.householdDetailOf('hh_abc123'));
      await tester.pumpAndSettle();

      expect(find.byKey(_detailMarkerKey), findsOneWidget);
    });

    testWidgets('/household/create still reaches the create flow, not the '
        'detail screen', (tester) async {
      // The hazard this route introduces. `create` is a legal
      // `:householdId`, so both routes match `/household/create` and
      // go_router takes the first declared. Create is declared first; if
      // that order is ever disturbed, the create flow silently becomes a
      // detail screen and this test is what says so.
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        householdDetailBuilder: (_, _) =>
            const Scaffold(body: SizedBox(key: _detailMarkerKey)),
        createHouseholdBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _createMarkerKey)),
      );

      router.go(AppRoutes.householdCreate);
      await tester.pumpAndSettle();

      expect(find.byKey(_createMarkerKey), findsOneWidget);
      expect(find.byKey(_detailMarkerKey), findsNothing);
    });

    testWidgets('the list route is unaffected by the id route beneath it', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        householdListBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _listMarkerKey)),
        householdDetailBuilder: (_, _) =>
            const Scaffold(body: SizedBox(key: _detailMarkerKey)),
      );

      router.go(AppRoutes.household);
      await tester.pumpAndSettle();

      expect(find.byKey(_listMarkerKey), findsOneWidget);
      expect(find.byKey(_detailMarkerKey), findsNothing);
    });

    testWidgets('an id needing encoding survives the round trip', (
      tester,
    ) async {
      String? seen;
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        householdDetailBuilder: (_, id) {
          seen = id;
          return const Scaffold(body: SizedBox(key: _detailMarkerKey));
        },
      );

      // Not a cuid2, and not expected to be one — the point is that
      // householdDetailOf builds a location the router can take apart
      // again, so a future id format cannot quietly break the route.
      router.go(AppRoutes.householdDetailOf('a b/c'));
      await tester.pumpAndSettle();

      expect(seen, 'a b/c');
    });
  });

  group('AppRoutes.householdDetailOf', () {
    test('builds a location under the list, not beside it', () {
      expect(
        AppRoutes.householdDetailOf('hh_1'),
        equals('${AppRoutes.household}/hh_1'),
      );
    });

    test('percent-encodes a segment that would otherwise split the path', () {
      expect(AppRoutes.householdDetailOf('a/b'), equals('/household/a%2Fb'));
    });
  });
}
