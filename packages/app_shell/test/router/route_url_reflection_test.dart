import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Pins the location the router reports for the address bar (#321).
///
/// The web composition calls [reflectPushedRoutesInUrl], so a push shows in
/// the address bar and browser Back returns to the screen beneath. Native
/// never calls it, and keeps reporting the declarative location.
class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  // The flag is global, and test order is random.
  tearDown(() => GoRouter.optionURLReflectsImperativeAPIs = false);

  Future<GoRouter> pumpRouter(WidgetTester tester) async {
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
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
    await tester.pumpAndSettle();
    return router;
  }

  /// The location the router hands the browser for its address bar.
  String reportedLocation(GoRouter router) => router.routeInformationParser
      .restoreRouteInformation(router.routerDelegate.currentConfiguration)!
      .uri
      .toString();

  Future<void> push(
    WidgetTester tester,
    GoRouter router,
    String location,
  ) async {
    unawaited(router.push<void>(location));
    await tester.pumpAndSettle();
  }

  testWidgets('after reflectPushedRoutesInUrl, a push reports the pushed '
      'location (#321)', (tester) async {
    reflectPushedRoutesInUrl();
    final router = await pumpRouter(tester);

    await push(tester, router, AppRoutes.household);
    await push(tester, router, AppRoutes.householdDetailOf('h1'));

    expect(reportedLocation(router), '/household/h1');
  });

  testWidgets('a pop reports the location beneath', (tester) async {
    reflectPushedRoutesInUrl();
    final router = await pumpRouter(tester);
    await push(tester, router, AppRoutes.household);
    await push(tester, router, AppRoutes.householdDetailOf('h1'));

    router.pop();
    await tester.pumpAndSettle();

    expect(reportedLocation(router), '/household');
  });

  testWidgets('a pushReplacement reports the replacement', (tester) async {
    reflectPushedRoutesInUrl();
    final router = await pumpRouter(tester);
    await push(tester, router, AppRoutes.household);
    await push(tester, router, AppRoutes.householdCreate);

    unawaited(router.pushReplacement<void>(AppRoutes.householdDetailOf('h2')));
    await tester.pumpAndSettle();

    expect(reportedLocation(router), '/household/h2');
  });

  testWidgets('a pushed query string is kept', (tester) async {
    reflectPushedRoutesInUrl();
    final router = await pumpRouter(tester);
    await push(tester, router, AppRoutes.events);

    await push(tester, router, AppRoutes.eventCreateOf(householdId: 'h1'));

    expect(reportedLocation(router), '/events/create?household=h1');
  });

  // Browser Back and Forward hand the router a history entry it reported
  // earlier, location and state together, over the same channel the web
  // engine uses on popstate. The state carries the pushed stack, so the
  // screens beneath come back with it rather than the location alone.
  testWidgets('browser Back and Forward restore the pushed stack', (
    tester,
  ) async {
    reflectPushedRoutesInUrl();
    final router = await pumpRouter(tester);
    RouteInformation reported() => router.routeInformationParser
        .restoreRouteInformation(router.routerDelegate.currentConfiguration)!;
    List<Page<Object?>> pages() =>
        router.routerDelegate.navigatorKey.currentState!.widget.pages;

    final history = [reported()];
    await push(tester, router, AppRoutes.household);
    history.add(reported());
    await push(tester, router, AppRoutes.householdDetailOf('h1'));
    history.add(reported());
    final depth = pages().length;

    Future<void> browserMovesTo(RouteInformation entry) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/navigation',
        const JSONMethodCodec().encodeMethodCall(
          MethodCall('pushRouteInformation', {
            'location': entry.uri.toString(),
            'state': entry.state,
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await browserMovesTo(history[1]);
    expect(reportedLocation(router), '/household');
    expect(pages(), hasLength(depth - 1));

    await browserMovesTo(history[0]);
    expect(reportedLocation(router), '/home');
    expect(pages(), hasLength(depth - 2));

    await browserMovesTo(history[1]);
    expect(reportedLocation(router), '/household');
    expect(pages(), hasLength(depth - 1));

    await browserMovesTo(history[2]);
    expect(reportedLocation(router), '/household/h1');
    expect(pages(), hasLength(depth));
  });

  testWidgets('without the call, a push still reports /home', (tester) async {
    final router = await pumpRouter(tester);

    await push(tester, router, AppRoutes.feedback);

    expect(reportedLocation(router), '/home');
  });
}
