import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Pins the page type every route builds (#465).
///
/// go_router 18 picks its default page by looking for `material_ui`'s
/// `MaterialApp`. Under Flutter's `MaterialApp.router` it finds none and
/// falls back to [NoTransitionPage], so no route animated. Routes the user
/// opens now build a [MaterialPage]; routes the bootstrap redirect lands
/// on keep no transition.
class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    required AppBootstrapState initialState,
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
      homeBuilder: (_) => const Scaffold(body: Center(child: Text('Home'))),
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
    // One frame: the splash spinner never settles.
    await tester.pump();
    return router;
  }

  /// The root navigator's pages, the ones every route outside the auth
  /// [ShellRoute] is built into.
  List<Page<Object?>> rootPages(GoRouter router) =>
      router.routerDelegate.navigatorKey.currentState!.widget.pages;

  /// The innermost navigator's pages: the auth [ShellRoute]'s, when auth or
  /// home is on top.
  List<Page<Object?>> innermostPages(WidgetTester tester) =>
      tester.widget<Navigator>(find.byType(Navigator).last).pages;

  testWidgets('a pushed route is built as a MaterialPage, not a '
      'NoTransitionPage (#465)', (tester) async {
    final router = await pumpRouter(
      tester,
      initialState: const AppBootstrapReady(),
    );

    unawaited(router.push(AppRoutes.feedback));
    await tester.pumpAndSettle();

    expect(rootPages(router).last, isA<MaterialPage<void>>());
    expect(rootPages(router).last, isNot(isA<NoTransitionPage<void>>()));
  });

  // A NoTransitionPage has no back swipe; a MaterialPage on iOS gets the
  // Cupertino transition, and the swipe with it.
  testWidgets(
    'an edge swipe pops a pushed route on iOS',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );
      final depth = rootPages(router).length;
      unawaited(router.push(AppRoutes.feedback));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(const Offset(2, 300));
      await gesture.moveBy(const Offset(400, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(rootPages(router), hasLength(depth));
      expect(find.text('Home'), findsOneWidget);
    },
  );

  // A route declared with `builder:` gets go_router's default page, which
  // under this app is a NoTransitionPage. The list below names locations,
  // so it can't see a route nobody added to it; this walks the tree.
  testWidgets('every GoRoute builds its own page', (tester) async {
    final router = await pumpRouter(
      tester,
      initialState: const AppBootstrapReady(),
    );

    Iterable<GoRoute> goRoutes(List<RouteBase> routes) sync* {
      for (final route in routes) {
        if (route is GoRoute) yield route;
        yield* goRoutes(route.routes);
      }
    }

    final routes = goRoutes(router.configuration.routes).toList();
    expect(routes, isNotEmpty);
    for (final route in routes) {
      expect(route.pageBuilder, isNotNull, reason: route.path);
      expect(route.builder, isNull, reason: route.path);
    }
  });

  testWidgets('every user-opened route is a MaterialPage', (tester) async {
    final router = await pumpRouter(
      tester,
      initialState: const AppBootstrapReady(),
    );

    final locations = [
      AppRoutes.feedback,
      AppRoutes.settings,
      AppRoutes.household,
      AppRoutes.householdCreate,
      AppRoutes.householdDetailOf('h1'),
      AppRoutes.householdInvitesOf('h1'),
      AppRoutes.householdInviteSendOf('h1'),
      AppRoutes.householdEditOf('h1'),
      AppRoutes.invites,
      AppRoutes.invitesSent,
      AppRoutes.collection,
      AppRoutes.games,
      AppRoutes.gameSearch,
      AppRoutes.gameDetailOf('g1'),
      AppRoutes.events,
      AppRoutes.eventGroupOf('upcoming'),
      AppRoutes.eventCreate,
      AppRoutes.eventCreateOf(householdId: 'h1'),
      AppRoutes.eventDetailOf('e1'),
      AppRoutes.stuckChanges,
      AppRoutes.adminDataGateways,
      AppRoutes.dataGatewayAdd,
      AppRoutes.dataGatewayEditOf('d1'),
      '/server/srv-1/event/ev-1',
    ];
    for (final location in locations) {
      router.go(location);
      await tester.pumpAndSettle();

      expect(
        rootPages(router).last,
        isA<MaterialPage<void>>(),
        reason: location,
      );
    }
  });

  group('routes the bootstrap redirect lands on keep no transition', () {
    final cases = <String, (AppBootstrapState, bool)>{
      'splash': (const AppBootstrapInitializing(), false),
      'error': (
        AppBootstrapFailed(
          error: StateError('boom'),
          attemptCount: 1,
          canOfferReset: false,
        ),
        false,
      ),
      'server-add': (const AppBootstrapNeedsServer(), false),
      // Auth and home sit in the auth ShellRoute's own navigator.
      'auth': (const AppBootstrapNeedsAuth(), true),
      'home': (const AppBootstrapReady(), true),
    };
    for (final MapEntry(key: name, value: (state, inShell)) in cases.entries) {
      testWidgets(name, (tester) async {
        final router = await pumpRouter(tester, initialState: state);

        final pages = inShell ? innermostPages(tester) : rootPages(router);
        expect(pages.last, isA<NoTransitionPage<void>>());
      });
    }
  });

  testWidgets('an unknown location shows RouteNotFoundScreen, and Go to home '
      'goes home', (tester) async {
    final router = await pumpRouter(
      tester,
      initialState: const AppBootstrapReady(),
    );

    router.go('/no-such-place');
    await tester.pumpAndSettle();

    expect(find.byType(RouteNotFoundScreen), findsOneWidget);
    expect(rootPages(router).last, isA<MaterialPage<void>>());

    await tester.tap(find.text('Go to home'));
    await tester.pumpAndSettle();

    expect(find.byType(RouteNotFoundScreen), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });
}
