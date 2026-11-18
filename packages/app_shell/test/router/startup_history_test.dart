import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/fake_browser_history.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// Pins what startup, sign-in and sign-out report to the browser (#916).
///
/// The bootstrap locations are screens the app passes through, so none of
/// them keeps a history entry: arriving at one takes the current entry's
/// place, and leaving one for home takes its place in turn. Back after a
/// fresh load then leaves the app, and Back after signing in never returns
/// to the sign-in form.
void main() {
  late _MockAppBootstrapCubit cubit;
  late StreamController<AppBootstrapState> states;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    states = StreamController<AppBootstrapState>.broadcast();
    addTearDown(states.close);
  });

  Future<GoRouter> pumpStartup(
    WidgetTester tester, {
    AppBootstrapState initialState = const AppBootstrapInitializing(),
  }) async {
    whenListen(cubit, states.stream, initialState: initialState);
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
    await _settle(tester);
    return router;
  }

  Future<void> emit(WidgetTester tester, AppBootstrapState state) async {
    states.add(state);
    await _settle(tester);
  }

  testWidgets('a signed-in fresh load leaves one history entry', (
    tester,
  ) async {
    final history = FakeBrowserHistory.install(tester);
    await pumpStartup(tester);

    await emit(tester, const AppBootstrapReady());

    expect(history.locations, [AppRoutes.home]);
    expect(history.allLocations, [AppRoutes.home]);
  });

  testWidgets('signing in does not leave the sign-in form behind', (
    tester,
  ) async {
    final history = FakeBrowserHistory.install(tester);
    await pumpStartup(tester);

    await emit(tester, const AppBootstrapNeedsAuth());
    expect(history.allLocations, [AppRoutes.auth]);

    await emit(tester, const AppBootstrapReady());

    expect(history.allLocations, isNot(contains(AppRoutes.auth)));
    expect(history.locations, [AppRoutes.home]);
  });

  testWidgets('browser Back after signing in does not land on the sign-in '
      'form', (tester) async {
    final history = FakeBrowserHistory.install(tester);
    final router = await pumpStartup(
      tester,
      initialState: const AppBootstrapReady(),
    );
    unawaited(router.push<void>(AppRoutes.household));
    await _settle(tester);
    await emit(tester, const AppBootstrapNeedsAuth());
    await emit(tester, const AppBootstrapReady());

    await history.back();

    expect(history.locations, [AppRoutes.home]);
    expect(history.allLocations, isNot(contains(AppRoutes.auth)));
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('a sign-out reaches /auth without leaving a pushed entry', (
    tester,
  ) async {
    final history = FakeBrowserHistory.install(tester);
    final router = await pumpStartup(
      tester,
      initialState: const AppBootstrapReady(),
    );
    unawaited(router.push<void>(AppRoutes.household));
    await _settle(tester);
    expect(history.allLocations, [AppRoutes.home, AppRoutes.household]);

    await emit(tester, const AppBootstrapNeedsAuth());

    expect(history.allLocations, [AppRoutes.home, AppRoutes.auth]);
  });

  testWidgets('every bootstrap location takes the entry it reaches', (
    tester,
  ) async {
    final history = FakeBrowserHistory.install(tester);
    await pumpStartup(tester);

    await emit(
      tester,
      AppBootstrapFailed(
        error: Exception('boom'),
        attemptCount: 1,
        canOfferReset: false,
      ),
    );
    expect(history.allLocations, [AppRoutes.error]);
    await emit(tester, const AppBootstrapInitializing());
    expect(history.allLocations, [AppRoutes.splash]);
    await emit(tester, const AppBootstrapNeedsServer());
    expect(history.allLocations, [AppRoutes.serverAdd]);
    await emit(tester, const AppBootstrapNeedsAuth());
    expect(history.allLocations, [AppRoutes.auth]);
    await emit(tester, const AppBootstrapReady());

    expect(history.allLocations, [AppRoutes.home]);
  });

  testWidgets('a location reached while signed out reports no entry of its '
      'own', (tester) async {
    final history = FakeBrowserHistory.install(tester);
    final router = await pumpStartup(
      tester,
      initialState: const AppBootstrapNeedsAuth(),
    );

    router.go(AppRoutes.household);
    await _settle(tester);

    expect(history.allLocations, [AppRoutes.auth]);
  });
}

/// Delivers a state, builds the frame it routes to, and lets the router's
/// post-frame report reach the browser. Not pumpAndSettle: the splash
/// spinner never settles.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}
