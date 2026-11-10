import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

const _dashboardMarkerKey = Key('admin_dashboard_route_marker');
const _householdListMarkerKey = Key('admin_household_list_route_marker');

/// The admin dashboard at `/admin` (#684), with the staff households list
/// and one household's detail beneath it (#685). The DataGateway routes
/// beneath it are in `data_gateway_route_test.dart`.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    AdminDashboardScreenBuilder? adminDashboardBuilder,
    AdminHouseholdListScreenBuilder? adminHouseholdListBuilder,
    AdminHouseholdDetailScreenBuilder? adminHouseholdDetailBuilder,
  }) async {
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
    );
    final listenable = BootstrapStreamListenable(cubit.stream);
    final router = buildAppRouter(
      bootstrapCubit: cubit,
      refreshListenable: listenable,
      adminDashboardBuilder: adminDashboardBuilder,
      adminHouseholdListBuilder: adminHouseholdListBuilder,
      adminHouseholdDetailBuilder: adminHouseholdDetailBuilder,
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

  Widget dashboard(BuildContext _) =>
      const Scaffold(body: SizedBox(key: _dashboardMarkerKey));

  Widget householdList(BuildContext _) =>
      const Scaffold(body: SizedBox(key: _householdListMarkerKey));

  group('buildAppRouter: the admin dashboard (#684)', () {
    test('the admin locations', () {
      expect(AppRoutes.admin, '/admin');
      expect(AppRoutes.adminDataGateways, '/admin/data-gateways');
      expect(AppRoutes.adminHouseholds, '/admin/households');
    });

    testWidgets('/admin builds the dashboard', (tester) async {
      final router = await pumpRouter(tester, adminDashboardBuilder: dashboard);

      router.go(AppRoutes.admin);
      await tester.pumpAndSettle();

      expect(find.byKey(_dashboardMarkerKey), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailableScreen with no builder', (
      tester,
    ) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.admin);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailableScreen when the builder answers '
        'null', (tester) async {
      final router = await pumpRouter(
        tester,
        adminDashboardBuilder: (_) => null,
      );

      router.go(AppRoutes.admin);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });
  });

  group('buildAppRouter: the staff households routes (#685)', () {
    testWidgets('/admin/households builds the list, with the dashboard '
        'beneath it', (tester) async {
      final router = await pumpRouter(
        tester,
        adminDashboardBuilder: dashboard,
        adminHouseholdListBuilder: householdList,
      );

      router.go(AppRoutes.adminHouseholds);
      await tester.pumpAndSettle();

      expect(find.byKey(_householdListMarkerKey), findsOneWidget);
      // A deep link builds the dashboard beneath, so leaving is a plain pop.
      expect(router.canPop(), isTrue);
      router.pop();
      await tester.pumpAndSettle();

      expect(find.byKey(_dashboardMarkerKey), findsOneWidget);
      expect(find.byKey(_householdListMarkerKey), findsNothing);
    });

    test('adminHouseholdDetailOf encodes the id', () {
      expect(AppRoutes.adminHouseholdIdParam, 'adminHouseholdId');
      expect(
        AppRoutes.adminHouseholdDetailOf('h/1'),
        '/admin/households/h%2F1',
      );
      expect(AppRoutes.adminHouseholdDetailOf('h_1'), '/admin/households/h_1');
    });

    testWidgets('/admin/households/h%2F1 asks the detail builder for the '
        'decoded id, with the list beneath it', (tester) async {
      String? askedFor;
      final router = await pumpRouter(
        tester,
        adminDashboardBuilder: dashboard,
        adminHouseholdListBuilder: householdList,
        adminHouseholdDetailBuilder: (_, id) {
          askedFor = id;
          return const Scaffold(body: Text('detail'));
        },
      );

      router.go('/admin/households/h%2F1');
      await tester.pumpAndSettle();

      expect(askedFor, 'h/1');
      expect(find.text('detail'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();

      expect(find.byKey(_householdListMarkerKey), findsOneWidget);
    });

    testWidgets('the list falls back to NotYetAvailableScreen with no '
        'builder', (tester) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.adminHouseholds);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('the detail falls back to NotYetAvailableScreen with no '
        'builder', (tester) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.adminHouseholdDetailOf('h_1'));
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('each falls back to NotYetAvailableScreen when its builder '
        'answers null', (tester) async {
      final router = await pumpRouter(
        tester,
        adminHouseholdListBuilder: (_) => null,
        adminHouseholdDetailBuilder: (_, _) => null,
      );

      for (final location in [
        AppRoutes.adminHouseholds,
        AppRoutes.adminHouseholdDetailOf('h_1'),
      ]) {
        router.go(location);
        await tester.pumpAndSettle();

        expect(
          find.byType(NotYetAvailableScreen),
          findsOneWidget,
          reason: location,
        );
      }
    });
  });
}
