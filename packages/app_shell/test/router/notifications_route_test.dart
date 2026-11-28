import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart' show BgeTopLevelRoute;

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

const _pageKey = Key('notifications_route_marker');
const _shellKey = Key('navigation_shell_marker');

/// #475: the Notifications page. A screen the navigation menu opens, so a
/// section's top inside the navigation shell, where the session's unread
/// count reaches it. Never "Inbox", which is the invite inbox at `/invites`.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() => cubit = _MockAppBootstrapCubit());

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    NotificationsScreenBuilder? notificationsBuilder,
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
      homeBuilder: (_) => const Scaffold(body: Text('Home')),
      navigationShellBuilder: (context, location, child) =>
          KeyedSubtree(key: _shellKey, child: child),
      notificationsBuilder: notificationsBuilder,
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

  testWidgets('/notifications is its own route, a section top inside the '
      'navigation shell', (tester) async {
    final router = await pumpRouter(
      tester,
      notificationsBuilder: (_) =>
          const Scaffold(body: SizedBox(key: _pageKey)),
    );

    router.go(AppRoutes.notifications);
    await tester.pumpAndSettle();

    final page = find.byKey(_pageKey);
    expect(page, findsOneWidget);
    expect(AppRoutes.notifications, '/notifications');
    expect(
      find.descendant(of: find.byKey(_shellKey), matching: page),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: page, matching: find.byType(BgeTopLevelRoute)),
      findsOneWidget,
    );
  });

  testWidgets('a push keeps the page it was opened from beneath', (
    tester,
  ) async {
    final router = await pumpRouter(
      tester,
      notificationsBuilder: (_) =>
          const Scaffold(body: SizedBox(key: _pageKey)),
    );

    router.go(AppRoutes.home);
    await tester.pumpAndSettle();
    final pushed = router.push<void>(AppRoutes.notifications);
    await tester.pumpAndSettle();
    expect(find.byKey(_pageKey), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);
    expect(find.byKey(_pageKey), findsNothing);
    await expectLater(pushed, completes);
  });

  testWidgets('falls back to NotYetAvailable with no builder', (tester) async {
    final router = await pumpRouter(tester);

    router.go(AppRoutes.notifications);
    await tester.pumpAndSettle();

    expect(find.byType(NotYetAvailableScreen), findsOneWidget);
  });

  testWidgets('falls back to NotYetAvailable when the builder has no page', (
    tester,
  ) async {
    final router = await pumpRouter(tester, notificationsBuilder: (_) => null);

    router.go(AppRoutes.notifications);
    await tester.pumpAndSettle();

    expect(find.byType(NotYetAvailableScreen), findsOneWidget);
  });
}
