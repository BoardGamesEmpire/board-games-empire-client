import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// A marker the create-household builder returns so the test can assert the
/// route resolved to the builder rather than the [NotYetAvailableScreen]
/// fallback.
const _householdMarkerKey = Key('household_create_route_marker');

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    required AppBootstrapState initialState,
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

  group('buildAppRouter — household-create route (#129)', () {
    testWidgets('resolves the create-household builder when supplied', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        createHouseholdBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _householdMarkerKey)),
      );

      router.go(AppRoutes.householdCreate);
      await tester.pumpAndSettle();

      expect(find.byKey(_householdMarkerKey), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailable when no builder is supplied', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );

      router.go(AppRoutes.householdCreate);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('is not a bootstrap location — a ready app is not bounced '
        'off it', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        createHouseholdBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _householdMarkerKey)),
      );

      router.go(AppRoutes.householdCreate);
      await tester.pumpAndSettle();

      // Present ⟹ we stayed on the route; a bounce to /home would render
      // the fallback instead of the marker.
      expect(find.byKey(_householdMarkerKey), findsOneWidget);
    });
  });
}
