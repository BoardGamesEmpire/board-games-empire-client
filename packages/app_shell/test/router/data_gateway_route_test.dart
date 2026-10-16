import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

const _listMarkerKey = Key('data_gateway_list_route_marker');

/// The DataGateway admin routes (#41): the list at `/admin/data-gateways`,
/// with the add and edit forms beneath it.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    DataGatewayListScreenBuilder? dataGatewayListBuilder,
    DataGatewayFormScreenBuilder? dataGatewayFormBuilder,
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
      dataGatewayListBuilder: dataGatewayListBuilder,
      dataGatewayFormBuilder: dataGatewayFormBuilder,
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

  group('buildAppRouter: DataGateway admin routes (#41)', () {
    testWidgets('the list lives at /admin/data-gateways', (tester) async {
      expect(AppRoutes.adminDataGateways, '/admin/data-gateways');

      final router = await pumpRouter(
        tester,
        dataGatewayListBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _listMarkerKey)),
      );

      router.go(AppRoutes.adminDataGateways);
      await tester.pumpAndSettle();

      expect(find.byKey(_listMarkerKey), findsOneWidget);
    });

    testWidgets('the add form is beneath the list, and is asked for no id', (
      tester,
    ) async {
      String? askedFor = 'not called';
      final router = await pumpRouter(
        tester,
        dataGatewayListBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _listMarkerKey)),
        dataGatewayFormBuilder: (_, id) {
          askedFor = id;
          return const Scaffold(body: Text('form'));
        },
      );

      router.go(AppRoutes.dataGatewayAdd);
      await tester.pumpAndSettle();

      expect(askedFor, isNull);
      expect(find.text('form'), findsOneWidget);
      expect(find.byKey(_listMarkerKey, skipOffstage: false), findsOneWidget);
    });

    testWidgets('the edit form is asked for the id the path carried', (
      tester,
    ) async {
      String? askedFor;
      final router = await pumpRouter(
        tester,
        dataGatewayFormBuilder: (_, id) {
          askedFor = id;
          return const Scaffold(body: Text('form'));
        },
      );

      router.go(AppRoutes.dataGatewayEditOf('dg 1'));
      await tester.pumpAndSettle();

      expect(askedFor, 'dg 1');
    });

    testWidgets('falls back to NotYetAvailable when no builder is supplied', (
      tester,
    ) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.adminDataGateways);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });
  });
}
