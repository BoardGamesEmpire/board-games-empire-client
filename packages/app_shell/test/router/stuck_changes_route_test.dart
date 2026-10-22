import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// A marker the stuck-changes builder returns, so the test can tell the
/// builder's screen from the [NotYetAvailableScreen] fallback.
const _listMarkerKey = Key('stuck_changes_route_marker');

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() => cubit = _MockAppBootstrapCubit());

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    StuckChangesScreenBuilder? stuckChangesBuilder,
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
      stuckChangesBuilder: stuckChangesBuilder,
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

  group('buildAppRouter — stuck-changes route (#190)', () {
    testWidgets('resolves the stuck-changes builder when supplied', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        stuckChangesBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _listMarkerKey)),
      );

      router.go(AppRoutes.stuckChanges);
      await tester.pumpAndSettle();

      // Also proves a ready app is not bounced off it: it is not a
      // bootstrap location.
      expect(find.byKey(_listMarkerKey), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailable when no builder is supplied', (
      tester,
    ) async {
      final router = await pumpRouter(tester);

      router.go(AppRoutes.stuckChanges);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });
  });
}
