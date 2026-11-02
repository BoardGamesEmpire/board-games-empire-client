import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

const _listMarkerKey = Key('data_gateway_list_route_marker');

/// The DataGateway admin routes (#41): the list at `/admin/data-gateways`,
/// with the add and edit forms and one DataGateway's own page (#457) beneath
/// it.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    DataGatewayListScreenBuilder? dataGatewayListBuilder,
    DataGatewayFormScreenBuilder? dataGatewayFormBuilder,
    DataGatewayDetailScreenBuilder? dataGatewayDetailBuilder,
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
      dataGatewayDetailBuilder: dataGatewayDetailBuilder,
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

  group('buildAppRouter: one DataGateway at its own location (#457)', () {
    testWidgets('the detail lives at /admin/data-gateways/:id, with the id '
        'decoded', (tester) async {
      expect(
        AppRoutes.dataGatewayDetail,
        '/admin/data-gateways/:dataGatewayId',
      );

      String? askedFor;
      final router = await pumpRouter(
        tester,
        dataGatewayListBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _listMarkerKey)),
        dataGatewayDetailBuilder: (_, id) {
          askedFor = id;
          return const Scaffold(body: Text('detail'));
        },
      );

      router.go(AppRoutes.dataGatewayDetailOf('dg 1/a'));
      await tester.pumpAndSettle();

      expect(askedFor, 'dg 1/a');
      expect(find.text('detail'), findsOneWidget);
      // A child of the list, so a deep link builds the list beneath it and
      // leaving it is a plain pop.
      expect(find.byKey(_listMarkerKey, skipOffstage: false), findsOneWidget);
    });

    testWidgets('new still opens the add form, not a detail with id "new"', (
      tester,
    ) async {
      final details = <String>[];
      String? formAskedFor = 'not called';
      final router = await pumpRouter(
        tester,
        dataGatewayFormBuilder: (_, id) {
          formAskedFor = id;
          return const Scaffold(body: Text('form'));
        },
        dataGatewayDetailBuilder: (_, id) {
          details.add(id);
          return const Scaffold(body: Text('detail'));
        },
      );

      router.go(AppRoutes.dataGatewayAdd);
      await tester.pumpAndSettle();

      expect(find.text('form'), findsOneWidget);
      expect(formAskedFor, isNull);
      expect(details, isEmpty);
    });

    testWidgets('edit still opens the edit form', (tester) async {
      final details = <String>[];
      String? formAskedFor;
      final router = await pumpRouter(
        tester,
        dataGatewayFormBuilder: (_, id) {
          formAskedFor = id;
          return const Scaffold(body: Text('form'));
        },
        dataGatewayDetailBuilder: (_, id) {
          details.add(id);
          return const Scaffold(body: Text('detail'));
        },
      );

      router.go(AppRoutes.dataGatewayEditOf('dg_1'));
      await tester.pumpAndSettle();

      expect(find.text('form'), findsOneWidget);
      expect(formAskedFor, 'dg_1');
      expect(details, isEmpty);
    });

    test('dataGatewayDetailOf encodes the id', () {
      expect(
        AppRoutes.dataGatewayDetailOf('dg 1/a'),
        '/admin/data-gateways/dg%201%2Fa',
      );
      expect(
        AppRoutes.dataGatewayDetailOf('dg_1'),
        '/admin/data-gateways/dg_1',
      );
    });

    testWidgets('falls back to NotYetAvailableScreen with no builder', (
      tester,
    ) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.dataGatewayDetailOf('dg_1'));
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailableScreen when the builder answers '
        'null', (tester) async {
      final router = await pumpRouter(
        tester,
        dataGatewayDetailBuilder: (_, _) => null,
      );

      router.go(AppRoutes.dataGatewayDetailOf('dg_1'));
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });
  });
}
