import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:bge_test_support/domain.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:interfaces/repositories.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_browser_history.dart';
import '../support/fake_platform_bootstrap.dart';

/// A web page as a test loads it: its history, the pending-link slot, the
/// session behind it and the bootstrap that runs it.
typedef _WebPage = ({
  FakeBrowserHistory history,
  PendingDeepLinkHolder holder,
  FakeAuthRepository repo,
  AppBootstrapCubit cubit,
});

/// A web reload or bookmark opens the screen the address named, once the
/// app is ready, and Back from it leaves the app (#83, #916).
///
/// The composition is web's: no link lookup and no orchestrator, so the
/// consumer goes straight to the held location.
void main() {
  const coldLoad = '/household/h1';

  Future<void> noopHydrated(PlatformBootstrap _) async {}

  /// Loads the page at [location], as a reload or a bookmark does, and
  /// starts bootstrap. Signed out unless [signedIn], when the session
  /// restores at once.
  Future<_WebPage> loadAt(
    WidgetTester tester,
    String location, {
    bool signedIn = false,
  }) async {
    final history = FakeBrowserHistory.install(tester);
    final holder = PendingDeepLinkHolder();
    addTearDown(holder.dispose);
    final repo = FakeAuthRepository(
      initialSession: signedIn ? testAuthResponse() : null,
    );
    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        activeServerScope: FakeActiveServerScope(buildActiveServer(repo)),
      ),
      hydratedStorageInitializer: noopHydrated,
    );
    addTearDown(cubit.close);
    final dispatcher = tester.binding.platformDispatcher
      ..defaultRouteNameTestValue = location;
    addTearDown(dispatcher.clearDefaultRouteNameTestValue);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, pendingDeepLinkHolder: holder),
    );
    await cubit.initialize();
    await tester.pumpAndSettle();
    return (history: history, holder: holder, repo: repo, cubit: cubit);
  }

  Future<void> signIn(WidgetTester tester, FakeAuthRepository repo) async {
    repo.emitAuthState(AuthStateAuthenticated(session: testAuthResponse()));
    await tester.pumpAndSettle();
  }

  GoRouter routerOf(WidgetTester tester) =>
      GoRouter.of(tester.element(find.byType(Navigator).first));

  testWidgets('a cold load resumes after sign-in', (tester) async {
    final page = await loadAt(tester, coldLoad);
    expect(page.cubit.state, isA<AppBootstrapNeedsAuth>());
    expect(page.holder.peek?.location, coldLoad);

    await signIn(tester, page.repo);

    expect(page.cubit.state, isA<AppBootstrapReady>());
    final router = routerOf(tester);
    expect(router.state.fullPath, AppRoutes.householdDetail);
    expect(router.state.uri.toString(), coldLoad);
    expect(page.holder.peek, isNull);
  });

  testWidgets('resume leaves no bootstrap entries', (tester) async {
    final page = await loadAt(tester, coldLoad);

    await signIn(tester, page.repo);

    for (final bootstrap in AppRoutes.bootstrapLocations) {
      expect(page.history.allLocations, isNot(contains(bootstrap)));
    }
    expect(page.history.locations.last, coldLoad);
  });

  testWidgets('a session that restores at once still resumes', (
    tester,
  ) async {
    final page = await loadAt(tester, coldLoad, signedIn: true);

    expect(page.cubit.state, isA<AppBootstrapReady>());
    expect(routerOf(tester).state.uri.toString(), coldLoad);
    expect(page.holder.peek, isNull);
    expect(page.history.allLocations, [coldLoad]);
  });

  testWidgets('a newer link wins over the held location', (tester) async {
    final page = await loadAt(tester, coldLoad);
    const newer = AppDeepLink(location: '/household/h2');

    page.holder.set(newer);
    await tester.pumpAndSettle();
    await signIn(tester, page.repo);

    expect(routerOf(tester).state.uri.toString(), newer.location);
    expect(page.holder.peek, isNull);
    expect(page.history.reported, isNot(contains(coldLoad)));
    expect(
      page.history.reported.where((l) => l == newer.location),
      hasLength(1),
    );
  });

  // The public link opens signed out, so it has landed: leaving it for
  // sign-in must not bring the visitor back to it afterwards. The visitor
  // left it themselves, so its entry stays, and Back returns to it.
  testWidgets("the public page's Go home leads home after sign-in", (
    tester,
  ) async {
    const publicLink = '/server/s1/collection/u1';
    final page = await loadAt(tester, publicLink);
    final history = page.history;
    expect(find.byType(NotYetAvailableScreen), findsOneWidget);

    await tester.tap(find.byKey(NotYetAvailableScreen.homeButtonKey));
    await tester.pumpAndSettle();
    expect(routerOf(tester).state.uri.toString(), AppRoutes.auth);
    expect(history.locations, [publicLink, AppRoutes.auth]);
    await signIn(tester, page.repo);

    expect(routerOf(tester).state.uri.toString(), AppRoutes.home);
    expect(history.locations, [publicLink, AppRoutes.home]);
    expect(page.holder.peek, isNull);

    await history.back();
    await tester.pumpAndSettle();

    expect(routerOf(tester).state.uri.toString(), publicLink);
    expect(find.byType(NotYetAvailableScreen), findsOneWidget);
  });

  testWidgets('back from a resumed screen leaves the app', (tester) async {
    final page = await loadAt(tester, coldLoad);
    await signIn(tester, page.repo);
    expect(page.history.locations, [coldLoad]);

    await page.history.back();

    expect(page.history.leftApp, isTrue);
  });

  // A provider link returns the browser to the Sign-in methods screen, so a
  // load there must land on it, signed in now or once the session restores
  // (#582). The return's id is gone before the router sees the address.
  group('at /settings/sign-in-methods (#582)', () {
    testWidgets('resumes there after sign-in', (tester) async {
      final page = await loadAt(tester, AppRoutes.settingsSignInMethods);
      expect(page.cubit.state, isA<AppBootstrapNeedsAuth>());
      expect(page.holder.peek?.location, AppRoutes.settingsSignInMethods);

      await signIn(tester, page.repo);

      final router = routerOf(tester);
      expect(router.state.fullPath, AppRoutes.settingsSignInMethods);
      expect(router.state.uri.toString(), AppRoutes.settingsSignInMethods);
      expect(find.byType(SignInMethodsScreen), findsOneWidget);
      expect(page.holder.peek, isNull);
      expect(page.history.locations.last, AppRoutes.settingsSignInMethods);
    });

    testWidgets('opens there when the session restores at once', (
      tester,
    ) async {
      final page = await loadAt(
        tester,
        AppRoutes.settingsSignInMethods,
        signedIn: true,
      );

      expect(page.cubit.state, isA<AppBootstrapReady>());
      expect(
        routerOf(tester).state.uri.toString(),
        AppRoutes.settingsSignInMethods,
      );
      expect(find.byType(SignInMethodsScreen), findsOneWidget);
      expect(page.holder.peek, isNull);
      expect(page.history.allLocations, [AppRoutes.settingsSignInMethods]);
    });
  });
}
