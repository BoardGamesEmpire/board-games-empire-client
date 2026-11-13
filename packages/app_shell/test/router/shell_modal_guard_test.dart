import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ui/ui.dart';

import '../support/fake_browser_history.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// A modal on the root navigator leaves with the navigation shell page it
/// was opened over (#414).
///
/// Every signed-in page is in the navigation shell's nested navigator, and
/// every modal goes on the root navigator, above the shell. Flutter takes a
/// modal down with the page it sits on, and on the root navigator that page
/// is the auth shell's, which stays while signed in. The router puts the
/// rule back for the shell's own pages.
void main() {
  late _MockAppBootstrapCubit cubit;
  late StreamController<AppBootstrapState> states;
  late AppBootstrapState current;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  // The flag [FakeBrowserHistory] sets is global, and test order is random.
  tearDown(() => GoRouter.optionURLReflectsImperativeAPIs = false);

  /// Pumps the app's router at [initial], with the bootstrap stream fed by
  /// hand through [emit]: `whenListen` would emit before the router's
  /// refresh listenable subscribes.
  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    AppBootstrapState initial = const AppBootstrapReady(),
  }) async {
    states = StreamController<AppBootstrapState>.broadcast();
    addTearDown(states.close);
    current = initial;
    when(() => cubit.stream).thenAnswer((_) => states.stream);
    when(() => cubit.state).thenAnswer((_) => current);
    final listenable = BootstrapStreamListenable(cubit.stream);
    final router = buildAppRouter(
      bootstrapCubit: cubit,
      refreshListenable: listenable,
      homeBuilder: (_) => const Scaffold(body: Center(child: Text('Home'))),
      navigationShellBuilder: (context, location, child) => child,
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

  Future<void> emit(WidgetTester tester, AppBootstrapState state) async {
    current = state;
    states.add(state);
    await tester.pumpAndSettle();
  }

  Future<void> push(
    WidgetTester tester,
    GoRouter router,
    String location,
  ) async {
    unawaited(router.push<void>(location));
    await tester.pumpAndSettle();
  }

  /// Opens a dialog the way the app does: `showDialog`, on the root
  /// navigator by default.
  Future<void> openDialog(WidgetTester tester, Finder over) async {
    unawaited(
      showDialog<void>(
        context: tester.element(over),
        builder: (_) => const AlertDialog(content: Text('Dialog')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Dialog'), findsOneWidget);
  }

  final home = find.text('Home');
  final dialog = find.text('Dialog');
  final notYetAvailable = find.byType(NotYetAvailableScreen);

  testWidgets('browser Back with a dialog open removes the dialog with its '
      'page', (tester) async {
    final history = FakeBrowserHistory.install(tester);
    final router = await pumpRouter(tester);
    await push(tester, router, AppRoutes.settings);
    await openDialog(tester, notYetAvailable);

    await history.back();

    expect(router.state.uri.path, AppRoutes.home);
    expect(dialog, findsNothing);
    expect(home, findsOneWidget);
  });

  testWidgets('a go elsewhere with a sheet open removes the sheet', (
    tester,
  ) async {
    final router = await pumpRouter(tester);
    unawaited(
      showModalBottomSheet<void>(
        context: tester.element(home),
        useRootNavigator: true,
        builder: (_) => const Text('Sheet'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sheet'), findsOneWidget);

    router.go(AppRoutes.settings);
    await tester.pumpAndSettle();

    expect(find.text('Sheet'), findsNothing);
    expect(notYetAvailable, findsOneWidget);
  });

  // go_router keys a page it builds from the location by its route's
  // pattern, so a go between two ids of one route keeps the page and only
  // rebuilds it: the shell's navigator reports no pop and no remove.
  testWidgets('a go to another id of the same route removes a dialog opened '
      'over the first', (tester) async {
    final router = await pumpRouter(tester);
    router.go(AppRoutes.householdDetailOf('a'));
    await tester.pumpAndSettle();
    await openDialog(tester, notYetAvailable);

    router.go(AppRoutes.householdDetailOf('b'));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, AppRoutes.householdDetailOf('b'));
    expect(dialog, findsNothing);
    expect(notYetAvailable, findsOneWidget);
  });

  testWidgets('a go elsewhere removes every modal opened over the page: a '
      'dialog over a sheet too', (tester) async {
    final router = await pumpRouter(tester);
    unawaited(
      showModalBottomSheet<void>(
        context: tester.element(home),
        useRootNavigator: true,
        builder: (_) => const Text('Sheet'),
      ),
    );
    await tester.pumpAndSettle();
    await openDialog(tester, find.text('Sheet'));

    router.go(AppRoutes.settings);
    await tester.pumpAndSettle();

    expect(dialog, findsNothing);
    expect(find.text('Sheet'), findsNothing);
    expect(notYetAvailable, findsOneWidget);
  });

  testWidgets('a dialog that replaces another on the root navigator still '
      'goes with the page', (tester) async {
    final router = await pumpRouter(tester);
    await openDialog(tester, home);
    Navigator.of(tester.element(dialog), rootNavigator: true).pushReplacement(
      DialogRoute<void>(
        context: tester.element(home),
        builder: (_) => const AlertDialog(content: Text('Replacement')),
      ),
    );
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(find.text('Replacement'), findsOneWidget);

    router.go(AppRoutes.settings);
    await tester.pumpAndSettle();

    expect(find.text('Replacement'), findsNothing);
    expect(notYetAvailable, findsOneWidget);
  });

  // #707's hand-off: the pop-up waits for the page it opened to arrive.
  testWidgets('a pop-up stays when a page is pushed over its opener, and goes '
      'once it has arrived', (tester) async {
    final router = await pumpRouter(tester);
    unawaited(
      showBgePopup<void>(
        tester.element(home),
        semanticLabel: 'Probe pop-up',
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => unawaited(
              GoRouter.of(context).push<void>(AppRoutes.settings),
            ),
            child: const Text('Open settings'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Open settings'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('Open settings'), findsNothing);
    expect(router.state.uri.path, AppRoutes.settings);

    router.pop();
    await tester.pumpAndSettle();

    expect(home, findsOneWidget);
    expect(find.text('Open settings'), findsNothing);
  });

  // The modal is its opener's, not any page's: a page it opened leaving
  // before it arrived takes nothing with it.
  testWidgets('browser Back to the opener while a page a pop-up opened is '
      'arriving leaves the pop-up over its opener', (tester) async {
    final history = FakeBrowserHistory.install(tester);
    final router = await pumpRouter(tester);
    unawaited(
      showBgePopup<void>(
        tester.element(home),
        semanticLabel: 'Probe pop-up',
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => unawaited(
              GoRouter.of(context).push<void>(AppRoutes.settings),
            ),
            child: const Text('Open settings'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(history.locations.last, AppRoutes.settings);

    await history.back();

    expect(router.state.uri.path, AppRoutes.home);
    expect(notYetAvailable, findsNothing);
    expect(home, findsOneWidget);
    expect(find.text('Open settings'), findsOneWidget);
  });

  testWidgets('over a pushed page, Back closes the dialog first, then pops '
      'the page', (tester) async {
    final router = await pumpRouter(tester);
    await push(tester, router, AppRoutes.settings);
    await openDialog(tester, notYetAvailable);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(dialog, findsNothing);
    expect(notYetAvailable, findsOneWidget);
    expect(router.state.uri.path, AppRoutes.settings);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(home, findsOneWidget);
    expect(router.state.uri.path, AppRoutes.home);
  });

  testWidgets('a dialog opened over a page stays while that page stays, and '
      'Back closes the dialog first', (tester) async {
    final router = await pumpRouter(tester);
    await openDialog(tester, home);

    router
      ..refresh()
      ..go(AppRoutes.home);
    await tester.pumpAndSettle();

    expect(dialog, findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(dialog, findsNothing);
    expect(home, findsOneWidget);
    expect(router.state.uri.path, AppRoutes.home);
  });

  testWidgets('the sign-out redirect removes an open dialog', (tester) async {
    final router = await pumpRouter(tester);
    await openDialog(tester, home);

    await emit(tester, const AppBootstrapNeedsAuth());

    expect(router.state.uri.path, AppRoutes.auth);
    expect(dialog, findsNothing);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('a root modal opened while no shell page exists is left alone', (
    tester,
  ) async {
    final router = await pumpRouter(
      tester,
      initial: const AppBootstrapNeedsAuth(),
    );
    await openDialog(tester, find.text('Sign in'));

    await emit(tester, const AppBootstrapReady());

    expect(router.state.uri.path, AppRoutes.home);
    expect(dialog, findsOneWidget);
  });
}
