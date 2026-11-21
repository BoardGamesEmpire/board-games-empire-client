import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ui/ui.dart';

import '../support/server_list_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// Reserved deep-link resource paths (#10). Declared from day one so the
/// resolution machinery exists even before any UI is behind them; every one
/// of them resolves to [NotYetAvailableScreen] in this issue's scope, except
/// the event link, which redirects to the event's detail (#82).
const _reservedDeepLinkPaths = <String>[
  '/server/srv-1/household/hh-1/invite/tok-1',
  '/server/srv-1/event/ev-1/rsvp/tok-2',
  '/server/srv-1/game/game-1',
  '/server/srv-1/collection/user-1',
];

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  PendingDeepLinkHolder buildHolder() {
    final holder = PendingDeepLinkHolder();
    addTearDown(holder.dispose);
    return holder;
  }

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    required AppBootstrapState initialState,
    Stream<AppBootstrapState>? stream,
    AuthScopeBuilder? authScopeBuilder,
    NavigationShellBuilder? navigationShellBuilder,
    PendingDeepLinkHolder? pendingDeepLinkHolder,
    String? coldLoad,
    ServersScreenBuilder? serversBuilder,
  }) async {
    whenListen(
      cubit,
      stream ?? const Stream<AppBootstrapState>.empty(),
      initialState: initialState,
    );
    // The address a web page was loaded at, which go_router starts from.
    if (coldLoad != null) {
      final dispatcher = tester.binding.platformDispatcher
        ..defaultRouteNameTestValue = coldLoad;
      addTearDown(dispatcher.clearDefaultRouteNameTestValue);
    }
    final listenable = BootstrapStreamListenable(cubit.stream);
    final router = buildAppRouter(
      bootstrapCubit: cubit,
      refreshListenable: listenable,
      pendingDeepLinkHolder: pendingDeepLinkHolder,
      // The production home body (HomeScreen) needs an active-server scope
      // this router-level test does not build. Supply a minimal stand-in so
      // the redirect assertions can recognize the home destination — the
      // real builder-null fallback is the (defensive, unreachable)
      // NotYetAvailableScreen, which renders no "Home" text.
      homeBuilder: (_) => const Scaffold(body: Center(child: Text('Home'))),
      authScopeBuilder: authScopeBuilder,
      navigationShellBuilder: navigationShellBuilder,
      serversBuilder: serversBuilder,
    );
    // go_router does not own the listenable; dispose the router first (it
    // removes its listener during dispose) then the listenable.
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
    // Not pumpAndSettle: when the current state is Initializing the splash
    // spinner animates indefinitely and would never settle. Route
    // resolution (including redirects) is synchronous, so one frame is
    // enough.
    await tester.pump();
    return router;
  }

  group('buildAppRouter — bootstrap state routing', () {
    testWidgets('shows the splash screen while initializing', (tester) async {
      await pumpRouter(tester, initialState: const AppBootstrapInitializing());

      expect(find.byType(SplashScreen), findsOneWidget);
    });

    testWidgets('routes to server-add when no server is registered', (
      tester,
    ) async {
      await pumpRouter(tester, initialState: const AppBootstrapNeedsServer());

      expect(find.text('Add a server'), findsOneWidget);
    });

    testWidgets('routes to auth when a server is registered', (tester) async {
      await pumpRouter(tester, initialState: const AppBootstrapNeedsAuth());

      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets('routes to the error screen on bootstrap failure', (
      tester,
    ) async {
      await pumpRouter(
        tester,
        initialState: AppBootstrapFailed(
          error: Exception('boom'),
          attemptCount: 1,
          canOfferReset: false,
        ),
      );

      expect(find.byType(BootstrapErrorScreen), findsOneWidget);
      expect(find.text('Startup failed'), findsOneWidget);
    });

    testWidgets('routes to home when ready', (tester) async {
      await pumpRouter(tester, initialState: const AppBootstrapReady());

      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('re-routes when the cubit emits a new state', (tester) async {
      await pumpRouter(
        tester,
        initialState: const AppBootstrapInitializing(),
        stream: Stream.fromIterable(const [AppBootstrapNeedsAuth()]),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SplashScreen), findsNothing);
      expect(find.text('Sign in'), findsOneWidget);
    });
  });

  group('buildAppRouter — reserved deep-link paths (#10)', () {
    for (final path in _reservedDeepLinkPaths) {
      testWidgets('declares $path and resolves it to NotYetAvailable when '
          'ready', (tester) async {
        final router = await pumpRouter(
          tester,
          initialState: const AppBootstrapReady(),
        );

        router.go(path);
        await tester.pumpAndSettle();

        expect(find.byType(NotYetAvailableScreen), findsOneWidget);
        expect(find.text('Not yet available'), findsOneWidget);
      });

      testWidgets('$path has nothing beneath it, so it offers a way home '
          '(#82)', (tester) async {
        final router = await pumpRouter(
          tester,
          initialState: const AppBootstrapReady(),
        );

        router.go(path);
        await tester.pumpAndSettle();
        final home = find.byKey(NotYetAvailableScreen.homeButtonKey);
        expect(home, findsOneWidget);
        expect(
          find.descendant(of: home, matching: find.text('Go home')),
          findsOneWidget,
        );
        await tester.tap(home);
        await tester.pumpAndSettle();

        expect(find.byType(NotYetAvailableScreen), findsNothing);
        expect(find.text('Home'), findsOneWidget);
        expect(
          router.routerDelegate.currentConfiguration.uri.toString(),
          AppRoutes.home,
        );
      });
    }

    testWidgets('gates deep links behind bootstrap: a reserved path visited '
        'while unauthenticated redirects to auth', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapNeedsAuth(),
      );

      router.go(_reservedDeepLinkPaths.first);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsNothing);
      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets("the reserved event link redirects to the event's detail", (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );

      router.go('/server/srv-1/event/ev-1');
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.uri.toString(),
        '/events/ev-1',
      );
    });

    testWidgets('the reserved event link keeps the tab it names, and drops '
        "a parameter the detail doesn't read", (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );

      router.go('/server/srv-1/event/ev-1?tab=pool&utm=x');
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.uri.toString(),
        AppRoutes.eventDetailOf('ev-1', tab: AppRoutes.eventPoolTab),
      );
    });

    testWidgets('the reserved event link encodes an id that needs it', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );

      router.go('/server/srv-1/event/a%20b');
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.uri.toString(),
        '/events/a%20b',
      );
    });

    testWidgets('the unknown-server link screen is reachable once ready', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );

      router.go(AppRoutes.deepLinkUnknownServer);
      await tester.pumpAndSettle();

      expect(find.byType(UnknownServerLinkScreen), findsOneWidget);
    });

    testWidgets('the unknown-server link screen is gated behind bootstrap', (
      tester,
    ) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapInitializing(),
      );

      router.go(AppRoutes.deepLinkUnknownServer);
      await tester.pump();

      expect(find.byType(UnknownServerLinkScreen), findsNothing);
      expect(find.byType(SplashScreen), findsOneWidget);
    });

    test('publicDeepLinkPathPatterns names only the collection link, and '
        'every entry is reserved', () {
      expect(publicDeepLinkPathPatterns, {
        '/server/:serverId/collection/:userId',
      });
      expect(
        reservedDeepLinkPathPatterns,
        containsAll(publicDeepLinkPathPatterns),
      );
    });

    test('appDeepLinkLocations names settings and its export page', () {
      expect(appDeepLinkLocations, {
        AppRoutes.settings,
        AppRoutes.settingsExport,
      });
    });

    for (final location in appDeepLinkLocations) {
      testWidgets('the app link location $location is a declared route', (
        tester,
      ) async {
        final router = await pumpRouter(
          tester,
          initialState: const AppBootstrapReady(),
        );
        router.go(location);
        await tester.pumpAndSettle();

        expect(router.routerDelegate.currentConfiguration.uri.path, location);
        expect(find.byType(RouteNotFoundScreen), findsNothing);
      });
    }
  });

  group('buildAppRouter — a web cold load (#83)', () {
    testWidgets('a cold load at a declared location is held', (tester) async {
      final holder = buildHolder();

      await pumpRouter(
        tester,
        initialState: const AppBootstrapInitializing(),
        pendingDeepLinkHolder: holder,
        coldLoad: '/household/h1',
      );

      expect(holder.peek!.location, '/household/h1');
      expect(holder.peek, isA<AppDeepLink>());
      expect(find.byType(SplashScreen), findsOneWidget);
    });

    testWidgets('a cold load keeps its query and token', (tester) async {
      final holder = buildHolder();

      await pumpRouter(
        tester,
        initialState: const AppBootstrapInitializing(),
        pendingDeepLinkHolder: holder,
        coldLoad: '/server/s1/event/e1/rsvp/tok?c=1',
      );

      expect(holder.peek!.location, '/server/s1/event/e1/rsvp/tok?c=1');
    });

    testWidgets('a cold load at an unknown path is not held', (tester) async {
      final holder = buildHolder();

      await pumpRouter(
        tester,
        initialState: const AppBootstrapInitializing(),
        pendingDeepLinkHolder: holder,
        coldLoad: '/nope',
      );

      expect(holder.peek, isNull);
    });

    for (final location in [AppRoutes.home, AppRoutes.auth]) {
      testWidgets('a cold load at $location is not held', (tester) async {
        final holder = buildHolder();

        await pumpRouter(
          tester,
          initialState: const AppBootstrapInitializing(),
          pendingDeepLinkHolder: holder,
          coldLoad: location,
        );

        expect(holder.peek, isNull);
      });
    }

    testWidgets('only the first location is held', (tester) async {
      final holder = buildHolder();
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapInitializing(),
        stream: Stream.fromIterable(const [AppBootstrapNeedsAuth()]),
        pendingDeepLinkHolder: holder,
        coldLoad: '/household/h1',
      );
      await tester.pumpAndSettle();
      final held = holder.peek;

      router.go(AppRoutes.household);
      await tester.pumpAndSettle();

      expect(find.text('Sign in'), findsOneWidget);
      expect(holder.peek, same(held));
    });

    testWidgets('a location reached after the cold load is never held', (
      tester,
    ) async {
      final holder = buildHolder();
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapInitializing(),
        stream: Stream.fromIterable(const [AppBootstrapNeedsAuth()]),
        pendingDeepLinkHolder: holder,
      );
      await tester.pumpAndSettle();

      router.go(AppRoutes.household);
      await tester.pumpAndSettle();

      expect(holder.peek, isNull);
    });
  });

  group('buildAppRouter — a public link before sign-in (#83)', () {
    const publicLink = '/server/s1/collection/u1';

    for (final location in [publicLink, '$publicLink?x=1']) {
      testWidgets('a cold load at $location opens it signed out', (
        tester,
      ) async {
        await pumpRouter(
          tester,
          initialState: const AppBootstrapNeedsAuth(),
          coldLoad: location,
        );

        expect(find.byType(NotYetAvailableScreen), findsOneWidget);
        expect(find.text('Sign in'), findsNothing);
      });
    }

    for (final location in [
      '/server/s1/event/e1',
      '/server/s1/game/g1',
      '/server/s1/collection',
      '/server/s1/collection/u1/extra',
      '/collection/u1',
    ]) {
      testWidgets('a cold load at $location waits for sign-in', (
        tester,
      ) async {
        await pumpRouter(
          tester,
          initialState: const AppBootstrapNeedsAuth(),
          coldLoad: location,
        );

        expect(find.byType(NotYetAvailableScreen), findsNothing);
        expect(find.text('Sign in'), findsOneWidget);
      });
    }

    testWidgets('the public link opens while the app is still starting', (
      tester,
    ) async {
      await pumpRouter(
        tester,
        initialState: const AppBootstrapInitializing(),
        coldLoad: publicLink,
      );

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(find.byType(SplashScreen), findsNothing);
    });

    // A web page always starts in Initializing, so this is the order a
    // signed-out visitor meets.
    testWidgets('the public link stays open from start-up through to '
        'sign-in', (tester) async {
      final states = StreamController<AppBootstrapState>();
      addTearDown(states.close);
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapInitializing(),
        stream: states.stream,
        coldLoad: publicLink,
      );
      expect(find.byType(NotYetAvailableScreen), findsOneWidget);

      states.add(const AppBootstrapNeedsAuth());
      await tester.pumpAndSettle();

      expect(find.text('Sign in'), findsNothing);
      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(
        router.routerDelegate.currentConfiguration.uri.toString(),
        publicLink,
      );
    });

    for (final state in const <AppBootstrapState>[
      AppBootstrapInitializing(),
      AppBootstrapNeedsAuth(),
    ]) {
      testWidgets('a public cold load that opens in ${state.runtimeType} is '
          'not held: it has landed', (tester) async {
        final holder = buildHolder();

        await pumpRouter(
          tester,
          initialState: state,
          pendingDeepLinkHolder: holder,
          coldLoad: publicLink,
        );

        expect(find.byType(NotYetAvailableScreen), findsOneWidget);
        expect(holder.peek, isNull);
      });
    }

    // A web page starts in Initializing, so the public link has opened
    // before the start fails.
    testWidgets('a public cold load a failed start pins away is held', (
      tester,
    ) async {
      final holder = buildHolder();
      final states = StreamController<AppBootstrapState>();
      addTearDown(states.close);
      await pumpRouter(
        tester,
        initialState: const AppBootstrapInitializing(),
        stream: states.stream,
        pendingDeepLinkHolder: holder,
        coldLoad: publicLink,
      );
      expect(holder.peek, isNull);

      states.add(
        AppBootstrapFailed(
          error: Exception('boom'),
          attemptCount: 1,
          canOfferReset: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(BootstrapErrorScreen), findsOneWidget);
      expect(holder.peek?.location, publicLink);
    });

    testWidgets('a public cold load the visitor left is not held when the '
        'start fails', (tester) async {
      final holder = buildHolder();
      final states = StreamController<AppBootstrapState>();
      addTearDown(states.close);
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapInitializing(),
        stream: states.stream,
        pendingDeepLinkHolder: holder,
        coldLoad: publicLink,
      );

      router.go(AppRoutes.home);
      // Splash's spinner never settles.
      await tester.pump();
      expect(find.byType(SplashScreen), findsOneWidget);
      states.add(
        AppBootstrapFailed(
          error: Exception('boom'),
          attemptCount: 1,
          canOfferReset: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(BootstrapErrorScreen), findsOneWidget);
      expect(holder.peek, isNull);
    });

    testWidgets('a public cold load stays open and unheld once ready', (
      tester,
    ) async {
      final holder = buildHolder();
      final states = StreamController<AppBootstrapState>();
      addTearDown(states.close);
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapInitializing(),
        stream: states.stream,
        pendingDeepLinkHolder: holder,
        coldLoad: publicLink,
      );

      states.add(const AppBootstrapReady());
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.uri.toString(),
        publicLink,
      );
      expect(holder.peek, isNull);
    });

    testWidgets('a failed start still shows the error over the public link', (
      tester,
    ) async {
      await pumpRouter(
        tester,
        initialState: AppBootstrapFailed(
          error: Exception('boom'),
          attemptCount: 1,
          canOfferReset: false,
        ),
        coldLoad: publicLink,
      );

      expect(find.byType(BootstrapErrorScreen), findsOneWidget);
    });
  });

  group('buildAppRouter — redirect discipline when ready', () {
    for (final bootstrapRoute in const [
      '/',
      '/error',
      '/server-add',
      '/auth',
    ]) {
      testWidgets('bounces $bootstrapRoute to home once ready', (tester) async {
        final router = await pumpRouter(
          tester,
          initialState: const AppBootstrapReady(),
        );

        router.go(bootstrapRoute);
        await tester.pumpAndSettle();

        expect(find.text('Home'), findsOneWidget);
      });
    }
  });

  group('buildAppRouter — navigation shell (#414)', () {
    testWidgets('every signed-in route builds inside the navigation shell', (
      tester,
    ) async {
      final wrapped = <String>[];
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        navigationShellBuilder: (context, location, child) {
          wrapped.add(location);
          return child;
        },
      );

      for (final route in const [
        '/home',
        '/settings',
        '/feedback',
        '/household',
        '/household/create',
        '/invites',
        '/collection',
        '/games',
        '/events',
        '/stuck-changes',
        '/admin',
      ]) {
        wrapped.clear();
        unawaited(router.push<void>(route));
        await tester.pumpAndSettle();

        expect(wrapped, contains(route), reason: route);
      }
    });

    testWidgets('/auth is not inside the navigation shell', (tester) async {
      var built = false;
      await pumpRouter(
        tester,
        initialState: const AppBootstrapNeedsAuth(),
        navigationShellBuilder: (context, location, child) {
          built = true;
          return child;
        },
      );

      expect(built, isFalse);
    });

    testWidgets('the navigation shell is inside the auth scope', (
      tester,
    ) async {
      const scopeKey = Key('auth-scope');
      const shellKey = Key('nav-shell');
      await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        authScopeBuilder: (context, child) =>
            KeyedSubtree(key: scopeKey, child: child),
        navigationShellBuilder: (context, location, child) =>
            KeyedSubtree(key: shellKey, child: child),
      );

      expect(
        find.descendant(
          of: find.byKey(scopeKey),
          matching: find.byKey(shellKey),
        ),
        findsOneWidget,
      );
    });
  });

  // #611: where the browser owns Back, a section's top shows the menu
  // however it was reached, and a page under one shows no arrow. The router
  // is what knows which is which.
  group("buildAppRouter — a section's top (#611)", () {
    Finder marked(Finder page) =>
        find.ancestor(of: page, matching: find.byType(BgeTopLevelRoute));

    /// The paths of the routes directly under the navigation shell: the
    /// `ShellRoute` holding home. Read from the router's own table, so a
    /// route added there later is checked too.
    List<String> shellChildren(GoRouter router) {
      Iterable<RouteBase> all(List<RouteBase> routes) sync* {
        for (final route in routes) {
          yield route;
          yield* all(route.routes);
        }
      }

      final shell = all(router.configuration.routes)
          .whereType<ShellRoute>()
          .singleWhere(
            (shell) => shell.routes.whereType<GoRoute>().any(
              (route) => route.path == AppRoutes.home,
            ),
          );
      return [
        for (final route in shell.routes.whereType<GoRoute>()) route.path,
      ];
    }

    testWidgets('every route directly under the navigation shell marks its '
        'page', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );
      final routes = shellChildren(router);
      // The walk found the shell: the routes it holds today are among them.
      expect(
        routes,
        containsAll(const [
          '/home',
          '/settings',
          '/feedback',
          '/household',
          '/invites',
          '/collection',
          '/games',
          '/events',
          '/stuck-changes',
          '/admin',
        ]),
      );

      for (final route in routes) {
        router.go(route);
        await tester.pumpAndSettle();

        final page = route == '/home'
            ? find.text('Home')
            : find.byType(NotYetAvailableScreen);
        expect(marked(page), findsOneWidget, reason: route);
      }
    });

    testWidgets('a page under a section is not marked', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
      );

      for (final route in const [
        '/household/create',
        '/household/hh-1',
        '/household/hh-1/invites',
        '/household/hh-1/edit',
        '/invites/sent',
        '/collection/entry-1',
        '/games/search',
        '/games/game-1',
        '/events/upcoming',
        '/events/create',
        '/events/ev-1',
        '/events/ev-1/availability',
        '/admin/data-gateways',
        '/admin/data-gateways/new',
        '/admin/households',
        '/admin/households/hh-1',
      ]) {
        router.go(route);
        await tester.pumpAndSettle();

        // The page on top; the section's own is offstage beneath it.
        final page = find.byType(NotYetAvailableScreen);
        expect(page, findsOneWidget, reason: route);
        expect(marked(page), findsNothing, reason: route);
      }
    });
  });

  group('buildAppRouter — pop-ups over the navigation shell (#414)', () {
    testWidgets('a page pushed inside the shell from a pop-up removes the '
        'pop-up once it has arrived', (tester) async {
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        navigationShellBuilder: (context, location, child) => child,
      );
      final homeContext = tester.element(find.text('Home'));
      unawaited(
        showBgePopup<void>(
          homeContext,
          semanticLabel: 'Probe pop-up',
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => unawaited(
                GoRouter.of(context)
                    .push<void>(AppRoutes.collectionEntryOf('c1')),
              ),
              child: const Text('Open entry'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Open entry'), findsOneWidget);

      // No collectionEntryBuilder: the entry's route builds the
      // NotYetAvailableScreen, which is page enough for the hand-off.
      await tester.tap(find.text('Open entry'));
      await tester.pumpAndSettle();

      expect(find.text('Open entry'), findsNothing);
      expect(router.state.uri.path, '/collection/c1');

      router.pop();
      await tester.pumpAndSettle();

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Open entry'), findsNothing);
    });
  });

  group('buildAppRouter — error screen wiring', () {
    testWidgets('retry on the routed error screen calls cubit.retry()', (
      tester,
    ) async {
      when(() => cubit.retry()).thenAnswer((_) async {});
      await pumpRouter(
        tester,
        initialState: AppBootstrapFailed(
          error: Exception('boom'),
          attemptCount: 1,
          canOfferReset: false,
        ),
      );

      await tester.tap(find.byKey(BootstrapErrorScreen.retryButtonKey));
      await tester.pumpAndSettle();

      verify(() => cubit.retry()).called(1);
    });

    testWidgets('confirmed reset on the routed error screen calls '
        'cubit.resetAndRetry()', (tester) async {
      when(() => cubit.resetAndRetry()).thenAnswer((_) async {});
      await pumpRouter(
        tester,
        initialState: AppBootstrapFailed(
          error: Exception('boom'),
          attemptCount: 3,
          canOfferReset: true,
        ),
      );

      await tester.tap(find.byKey(BootstrapErrorScreen.resetButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(BootstrapErrorScreen.resetConfirmButtonKey));
      await tester.pumpAndSettle();

      verify(() => cubit.resetAndRetry()).called(1);
    });
  });

  group('BootstrapStreamListenable', () {
    test('notifies on every stream event', () async {
      final controller = StreamController<int>();
      final listenable = BootstrapStreamListenable(controller.stream);
      var notifications = 0;
      listenable.addListener(() => notifications++);

      controller
        ..add(1)
        ..add(2);
      await Future<void>.delayed(Duration.zero);

      expect(notifications, 2);

      listenable.dispose();
      await controller.close();
    });

    test('dispose() cancels the stream subscription (go_router never '
        'disposes its refreshListenable)', () async {
      final controller = StreamController<int>();
      final listenable = BootstrapStreamListenable(controller.stream);
      expect(controller.hasListener, isTrue);

      listenable.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(controller.hasListener, isFalse);
      await controller.close();
    });

    test('construction over a stream that completes synchronously does not '
        'throw (regression: onDone must not touch the late subscription '
        'field during listen)', () {
      expect(
        () => BootstrapStreamListenable(
          Stream<Object?>.multi((controller) => controller.closeSync()),
        ),
        returnsNormally,
      );
    });

    test('dispose() after the source stream has completed is safe', () async {
      final controller = StreamController<int>();
      final listenable = BootstrapStreamListenable(controller.stream);

      await controller.close();
      await Future<void>.delayed(Duration.zero);

      expect(listenable.dispose, returnsNormally);
    });
  });

  // #134: the server manager belongs to the device, not to a server's
  // session, so on native it opens while signed out. Web has no
  // orchestrator, and its redirect is unchanged.
  group('buildAppRouter — the server manager (#134)', () {
    testWidgets('the manager opens while signed out on native', (
      tester,
    ) async {
      when(() => cubit.orchestrator).thenReturn(FakeServerOrchestrator());
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapNeedsAuth(),
      );
      expect(find.text('Sign in'), findsOneWidget);

      // Pushed over sign-in, as its link will push it, and then the add
      // route beneath it. Neither builder is given: each falls back to the
      // not-found page.
      unawaited(router.push<void>(AppRoutes.servers));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, AppRoutes.servers);
      expect(find.byType(RouteNotFoundScreen), findsOneWidget);

      unawaited(router.push<void>(AppRoutes.serversAdd));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, AppRoutes.serversAdd);
      expect(find.byType(RouteNotFoundScreen), findsOneWidget);

      // Back returns through the manager to sign-in.
      router.pop();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, AppRoutes.servers);
      router.pop();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, AppRoutes.auth);
      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets('on web the signed-out redirect still sends /servers to '
        '/auth', (tester) async {
      when(() => cubit.orchestrator).thenReturn(null);
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapNeedsAuth(),
      );

      for (final location in const [AppRoutes.servers, AppRoutes.serversAdd]) {
        router.go(location);
        await tester.pumpAndSettle();

        expect(router.state.uri.path, AppRoutes.auth, reason: location);
        expect(find.text('Sign in'), findsOneWidget, reason: location);
      }
    });

    // Web has no manager, so its location is unknown there, as it was
    // before the route existed: the not-found page and its way home.
    testWidgets('on web a signed-in visitor at /servers gets the not-found '
        'screen', (tester) async {
      when(() => cubit.orchestrator).thenReturn(null);
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        // BgeApp's builder, without an orchestrator.
        serversBuilder: (_) => null,
      );

      for (final location in const [AppRoutes.servers, AppRoutes.serversAdd]) {
        router.go(location);
        await tester.pumpAndSettle();

        expect(router.state.uri.path, location, reason: location);
        expect(find.byType(RouteNotFoundScreen), findsOneWidget);
        expect(find.byType(NotYetAvailableScreen), findsNothing);

        await tester.tap(
          find.descendant(
            of: find.byType(RouteNotFoundScreen),
            matching: find.byType(FilledButton),
          ),
        );
        await tester.pumpAndSettle();

        expect(router.state.uri.path, AppRoutes.home, reason: location);
        expect(find.text('Home'), findsOneWidget, reason: location);
      }
    });

    testWidgets('a ready app stays on /servers', (tester) async {
      when(() => cubit.orchestrator).thenReturn(FakeServerOrchestrator());
      const scopeKey = Key('auth-scope');
      const shellKey = Key('nav-shell');
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapReady(),
        authScopeBuilder: (context, child) =>
            KeyedSubtree(key: scopeKey, child: child),
        navigationShellBuilder: (context, location, child) =>
            KeyedSubtree(key: shellKey, child: child),
        serversBuilder: (_) => const Scaffold(body: Text('Servers')),
      );

      unawaited(router.push<void>(AppRoutes.servers));
      await tester.pumpAndSettle();

      expect(router.state.uri.path, AppRoutes.servers);
      expect(find.text('Servers'), findsOneWidget);
      // Outside both shells: it needs no server's session.
      for (final shell in [scopeKey, shellKey]) {
        expect(
          find.ancestor(of: find.text('Servers'), matching: find.byKey(shell)),
          findsNothing,
          reason: '$shell',
        );
      }

      // Back returns to home, beneath it.
      router.pop();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, AppRoutes.home);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('with no server registered /servers goes to /server-add', (
      tester,
    ) async {
      when(() => cubit.orchestrator).thenReturn(FakeServerOrchestrator());
      final router = await pumpRouter(
        tester,
        initialState: const AppBootstrapNeedsServer(),
      );

      for (final location in const [AppRoutes.servers, AppRoutes.serversAdd]) {
        router.go(location);
        await tester.pumpAndSettle();

        expect(router.state.uri.path, AppRoutes.serverAdd, reason: location);
        expect(find.text('Add a server'), findsOneWidget, reason: location);
      }
    });
  });

  group('AppRoutes link-carrying locations', () {
    // Escapes, a query of its own, and an address: the parts a link's
    // location carries that a hand-built query would mangle (#971).
    const linkLocation = '/server/a%2Fb/event/1?address=x&tab=games';

    test('deepLinkUnknownServerOf carries the link intact', () {
      final uri = Uri.parse(AppRoutes.deepLinkUnknownServerOf(linkLocation));

      expect(AppRoutes.deepLinkParam, 'link');
      expect(uri.path, AppRoutes.deepLinkUnknownServer);
      expect(uri.queryParameters.keys, ['link']);
      expect(uri.queryParameters['link'], linkLocation);
    });

    test('serversAddOf carries the link intact', () {
      final uri = Uri.parse(AppRoutes.serversAddOf(linkLocation));

      expect(uri.path, AppRoutes.serversAdd);
      expect(uri.queryParameters.keys, ['link']);
      expect(uri.queryParameters['link'], linkLocation);
    });
  });

  group('AppRoutes.isServerManager', () {
    test('is the manager and everything under it', () {
      expect(AppRoutes.serversAdd, '${AppRoutes.servers}/add');
      for (final location in [
        AppRoutes.servers,
        AppRoutes.serversAdd,
        '${AppRoutes.servers}?from=drawer',
      ]) {
        expect(AppRoutes.isServerManager(location), isTrue, reason: location);
      }
    });

    test('is not a sibling that shares its prefix, or anywhere else', () {
      for (final location in [
        '/serversx',
        AppRoutes.serverAdd,
        AppRoutes.home,
        AppRoutes.splash,
      ]) {
        expect(AppRoutes.isServerManager(location), isFalse, reason: location);
      }
    });
  });
}
