import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/domain.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:interfaces/repositories.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_browser_history.dart';
import '../support/fake_platform_bootstrap.dart';

/// A web reload or bookmark opens the screen the address named, once the
/// app is ready, and Back from it leaves the app (#83, #916).
///
/// The composition is web's: no link lookup and no orchestrator, so the
/// consumer goes straight to the held location.
void main() {
  const coldLoad = '/household/h1';

  Future<void> noopHydrated(PlatformBootstrap _) async {}

  PendingDeepLinkHolder buildHolder() {
    final holder = PendingDeepLinkHolder();
    addTearDown(holder.dispose);
    return holder;
  }

  AppBootstrapCubit buildWebCubit(FakeAuthRepository repo) {
    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        activeServerScope: FakeActiveServerScope(buildActiveServer(repo)),
      ),
      hydratedStorageInitializer: noopHydrated,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  /// Loads the page at [location], as a reload or a bookmark does, and
  /// starts bootstrap.
  Future<void> loadAt(
    WidgetTester tester,
    String location,
    AppBootstrapCubit cubit,
    PendingDeepLinkHolder holder,
  ) async {
    final dispatcher = tester.binding.platformDispatcher
      ..defaultRouteNameTestValue = location;
    addTearDown(dispatcher.clearDefaultRouteNameTestValue);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, pendingDeepLinkHolder: holder),
    );
    await cubit.initialize();
    await tester.pumpAndSettle();
  }

  Future<void> signIn(WidgetTester tester, FakeAuthRepository repo) async {
    repo.emitAuthState(AuthStateAuthenticated(session: testAuthResponse()));
    await tester.pumpAndSettle();
  }

  GoRouter routerOf(WidgetTester tester) =>
      GoRouter.of(tester.element(find.byType(Navigator).first));

  testWidgets('a cold load resumes after sign-in', (tester) async {
    FakeBrowserHistory.install(tester);
    final holder = buildHolder();
    final repo = FakeAuthRepository(); // no session
    final cubit = buildWebCubit(repo);
    await loadAt(tester, coldLoad, cubit, holder);
    expect(cubit.state, isA<AppBootstrapNeedsAuth>());
    expect(holder.peek?.location, coldLoad);

    await signIn(tester, repo);

    expect(cubit.state, isA<AppBootstrapReady>());
    final router = routerOf(tester);
    expect(router.state.fullPath, AppRoutes.householdDetail);
    expect(router.state.uri.toString(), coldLoad);
    expect(holder.peek, isNull);
  });

  testWidgets('resume leaves no bootstrap entries', (tester) async {
    final history = FakeBrowserHistory.install(tester);
    final holder = buildHolder();
    final repo = FakeAuthRepository(); // no session
    final cubit = buildWebCubit(repo);
    await loadAt(tester, coldLoad, cubit, holder);

    await signIn(tester, repo);

    for (final bootstrap in AppRoutes.bootstrapLocations) {
      expect(history.allLocations, isNot(contains(bootstrap)));
    }
    expect(history.locations.last, coldLoad);
  });

  testWidgets('a session that restores at once still resumes', (
    tester,
  ) async {
    final history = FakeBrowserHistory.install(tester);
    final holder = buildHolder();
    final cubit = buildWebCubit(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );

    await loadAt(tester, coldLoad, cubit, holder);

    expect(cubit.state, isA<AppBootstrapReady>());
    expect(routerOf(tester).state.uri.toString(), coldLoad);
    expect(holder.peek, isNull);
    expect(history.allLocations, [coldLoad]);
  });

  testWidgets('a newer link wins over the held location', (tester) async {
    final history = FakeBrowserHistory.install(tester);
    final holder = buildHolder();
    final repo = FakeAuthRepository(); // no session
    final cubit = buildWebCubit(repo);
    await loadAt(tester, coldLoad, cubit, holder);
    const newer = NormalizedDeepLink(
      serverId: webColdLoadServerId,
      location: '/household/h2',
    );

    holder.set(newer);
    await tester.pumpAndSettle();
    await signIn(tester, repo);

    expect(routerOf(tester).state.uri.toString(), newer.location);
    expect(holder.peek, isNull);
    expect(history.reported, isNot(contains(coldLoad)));
    expect(history.reported.where((l) => l == newer.location), hasLength(1));
  });

  // The public link opens signed out, so it has landed: leaving it for
  // sign-in must not bring the visitor back to it afterwards. The visitor
  // left it themselves, so its entry stays, and Back returns to it.
  testWidgets("the public page's Go home leads home after sign-in", (
    tester,
  ) async {
    final history = FakeBrowserHistory.install(tester);
    final holder = buildHolder();
    final repo = FakeAuthRepository(); // no session
    final cubit = buildWebCubit(repo);
    const publicLink = '/server/s1/collection/u1';
    await loadAt(tester, publicLink, cubit, holder);
    expect(find.byType(NotYetAvailableScreen), findsOneWidget);

    await tester.tap(find.byKey(NotYetAvailableScreen.homeButtonKey));
    await tester.pumpAndSettle();
    expect(routerOf(tester).state.uri.toString(), AppRoutes.auth);
    expect(history.locations, [publicLink, AppRoutes.auth]);
    await signIn(tester, repo);

    expect(routerOf(tester).state.uri.toString(), AppRoutes.home);
    expect(history.locations, [publicLink, AppRoutes.home]);
    expect(holder.peek, isNull);

    await history.back();
    await tester.pumpAndSettle();

    expect(routerOf(tester).state.uri.toString(), publicLink);
    expect(find.byType(NotYetAvailableScreen), findsOneWidget);
  });

  testWidgets('back from a resumed screen leaves the app', (tester) async {
    final history = FakeBrowserHistory.install(tester);
    final holder = buildHolder();
    final repo = FakeAuthRepository(); // no session
    final cubit = buildWebCubit(repo);
    await loadAt(tester, coldLoad, cubit, holder);

    await signIn(tester, repo);

    expect(history.locations, [coldLoad]);
  });
}
