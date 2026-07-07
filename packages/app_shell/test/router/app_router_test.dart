import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

/// Reserved deep-link resource paths (#10). Declared from day one so the
/// resolution machinery exists even before any UI is behind them; every one
/// of them resolves to [NotYetAvailableScreen] in this issue's scope.
const _reservedDeepLinkPaths = <String>[
  '/server/srv-1/household/hh-1/invite/tok-1',
  '/server/srv-1/event/ev-1',
  '/server/srv-1/event/ev-1/rsvp/tok-2',
  '/server/srv-1/game/game-1',
  '/server/srv-1/collection/user-1',
];

void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
  });

  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    required AppBootstrapState initialState,
    Stream<AppBootstrapState>? stream,
  }) async {
    whenListen(
      cubit,
      stream ?? const Stream<AppBootstrapState>.empty(),
      initialState: initialState,
    );
    final router = buildAppRouter(bootstrapCubit: cubit);
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
}
