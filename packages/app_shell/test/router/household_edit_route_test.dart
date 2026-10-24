import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

const _editKey = Key('household_edit_route_marker');
const _detailKey = Key('household_detail_route_marker');

/// #476: the household edit route, a child of the household's detail route
/// beside its invites, so a `go` to it builds the detail screen beneath it
/// and leaving is a plain pop.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() => cubit = _MockAppBootstrapCubit());

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    EditHouseholdScreenBuilder? editHouseholdBuilder,
    HouseholdDetailScreenBuilder? householdDetailBuilder,
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
      editHouseholdBuilder: editHouseholdBuilder,
      householdDetailBuilder: householdDetailBuilder,
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

  Widget marker(Key key) => Scaffold(body: SizedBox(key: key));

  test('householdEditOf encodes the id', () {
    expect(AppRoutes.householdEditOf('hh 1/a'), '/household/hh%201%2Fa/edit');
    expect(AppRoutes.householdEdit, '/household/:householdId/edit');
  });

  testWidgets('the edit route builds the edit screen, over its detail '
      'screen', (tester) async {
    String? seen;
    final router = await pumpRouter(
      tester,
      householdDetailBuilder: (_, _) => marker(_detailKey),
      editHouseholdBuilder: (_, id) {
        seen = id;
        return marker(_editKey);
      },
    );

    router.go(AppRoutes.householdEditOf('hh 1/a'));
    await tester.pumpAndSettle();

    expect(find.byKey(_editKey), findsOneWidget);
    expect(seen, 'hh 1/a');
    expect(find.byKey(_detailKey, skipOffstage: false), findsOneWidget);
  });

  testWidgets('no builder falls back to NotYetAvailableScreen', (tester) async {
    final router = await pumpRouter(tester);

    router.go(AppRoutes.householdEditOf('hh_1'));
    await tester.pumpAndSettle();

    expect(find.byType(NotYetAvailableScreen), findsOneWidget);
  });

  testWidgets('a builder that answers null falls back too', (tester) async {
    final router = await pumpRouter(
      tester,
      editHouseholdBuilder: (_, _) => null,
    );

    router.go(AppRoutes.householdEditOf('hh_1'));
    await tester.pumpAndSettle();

    expect(find.byType(NotYetAvailableScreen), findsOneWidget);
  });
}
