import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// A marker the settings builder returns so the test can assert the route
/// resolved to the builder rather than the [NotYetAvailableScreen]
/// fallback.
const _settingsMarkerKey = Key('settings_route_marker');

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    required AppBootstrapState initialState,
    SettingsScreenBuilder? settingsBuilder,
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
      settingsBuilder: settingsBuilder,
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

  group('buildAppRouter — settings route (#120)', () {
    testWidgets('resolves the settings builder when ready', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        settingsBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _settingsMarkerKey)),
      );

      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();

      expect(find.byKey(_settingsMarkerKey), findsOneWidget);
    });

    testWidgets('falls back to NotYetAvailable when no settings builder is '
        'supplied', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );

      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
    });

    testWidgets('is not a bootstrap location — a ready app is not bounced off '
        'it', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        settingsBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _settingsMarkerKey)),
      );

      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();

      expect(find.byKey(_settingsMarkerKey), findsOneWidget);
      expect(find.text('Home'), findsNothing);
    });

    testWidgets('is gated behind bootstrap: visiting it while unauthenticated '
        'redirects to auth', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapNeedsAuth(),
        settingsBuilder: (_) =>
            const Scaffold(body: SizedBox(key: _settingsMarkerKey)),
      );

      router.go(AppRoutes.settings);
      await tester.pumpAndSettle();

      expect(find.byKey(_settingsMarkerKey), findsNothing);
      expect(find.text('Sign in'), findsOneWidget);
    });
  });
}
