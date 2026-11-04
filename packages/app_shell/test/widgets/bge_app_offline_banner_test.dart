import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:di/di.dart' show DependencyContainerImpl;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ui/ui.dart' show BgeOfflineStrip;

import '../support/active_server_fakes.dart';
import '../support/fake_connectivity.dart';
import '../support/fake_platform_bootstrap.dart';
import '../support/stub_feedback_service.dart';

class _MockStorage extends Mock implements Storage {}

/// Every label a screen reader can reach, merged nodes included.
List<String> _semanticsLabels(WidgetTester tester) {
  final labels = <String>[];
  void visit(SemanticsNode node) {
    labels.add(node.getSemanticsData().label);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return labels;
}

/// #98 shell wiring: a session restored offline reaches home with the
/// unverified-session banner, and a confirming revalidation clears the
/// banner without re-running the session-start machinery. #49 puts the
/// offline strip above every route: the banner steps aside for it, and the
/// crash flow's barrier covers it.
void main() {
  Future<void> noopHydrated(PlatformBootstrap _) async {}

  AppBootstrapCubit buildCubit(FakeAuthRepository repo) => AppBootstrapCubit(
    platformBootstrap: FakePlatformBootstrap(
      activeServerScope: FakeActiveServerScope(buildActiveServer(repo)),
    ),
    hydratedStorageInitializer: noopHydrated,
  );

  const bannerMessage =
      "Can't reach the server — using your saved sign-in. Changes will "
      'sync when the connection returns.';

  const offlineMessage =
      "You're offline. Changes will sync when you reconnect.";
  const backOnlineMessage = 'Back online';

  /// Pumps the app signed in through [repo]. With [connectivity], the root
  /// container carries it, as both platforms register it.
  Future<AppBootstrapCubit> pumpApp(
    WidgetTester tester,
    FakeAuthRepository repo, {
    FakeConnectivity? connectivity,
    FeedbackUncaughtErrorReporter? feedbackReporter,
  }) async {
    final cubit = buildCubit(repo);
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(
        bootstrapCubit: cubit,
        rootContainer: connectivity == null
            ? null
            : (DependencyContainerImpl()
                ..registerSingleton<ConnectivityService>(connectivity)),
        feedbackReporter: feedbackReporter,
      ),
    );
    await cubit.initialize();
    await tester.pumpAndSettle();
    return cubit;
  }

  /// Moves [connectivity] to [state] and draws the frame the app asks for.
  Future<void> go(
    WidgetTester tester,
    FakeConnectivity connectivity,
    ConnectivityState state,
  ) async {
    connectivity.change(state);
    await tester.pump(Duration.zero);
  }

  testWidgets('an indeterminate session check with restorable material '
      'enters home WITH the banner — the #98 end-to-end path', (tester) async {
    final repo = FakeAuthRepository(
      sessionCheckError: const AuthNetworkException(message: 'offline'),
      restorableSession: sampleSession(),
    );

    await pumpApp(tester, repo);

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text(bannerMessage), findsOneWidget);
  });

  testWidgets('a verified session shows home WITHOUT the banner', (
    tester,
  ) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());

    await pumpApp(tester, repo);

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text(bannerMessage), findsNothing);
  });

  testWidgets('an indeterminate check with NOTHING restorable keeps the '
      'retry view — #98 narrows the failure state, it does not remove it', (
    tester,
  ) async {
    final repo = FakeAuthRepository(
      sessionCheckError: const AuthNetworkException(message: 'offline'),
    );

    await pumpApp(tester, repo);

    expect(find.byType(HomeScreen), findsNothing);
    expect(find.text(bannerMessage), findsNothing);
    // The #37 retryable view, not the sign-in form (AuthScreen): the stored
    // session was not rejected, we just couldn't ask — showing the form
    // would wrongly imply the session is gone. AuthGate renders
    // SessionCheckFailedView for AuthSessionCheckFailed.
    expect(find.byType(SessionCheckFailedView), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);
  });

  testWidgets('a confirming revalidation clears the banner and home '
      'survives — the verification-only transition must reach presentation '
      'but must NOT re-run session-start wiring', (tester) async {
    final repo = FakeAuthRepository(
      sessionCheckError: const AuthNetworkException(message: 'offline'),
      restorableSession: sampleSession(),
    );

    await pumpApp(tester, repo);
    expect(find.text(bannerMessage), findsOneWidget);

    // Connectivity returns; revalidation succeeds. Modelled at the
    // repository seam: the real repository re-emits the SAME session as
    // verified, which the bloc mirrors by value (#98). If the shell's
    // entry/exit listener wrongly re-fired here, the second
    // onAuthenticated() against an already-Ready bootstrap cubit — or a
    // second user-scope activation — would surface as an exception or a
    // remount below.
    repo.emitAuthState(AuthStateAuthenticated(session: sampleSession()));
    await tester.pumpAndSettle();

    expect(find.text(bannerMessage), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rejecting revalidation signs the user out — home is left, '
      'the auth screen returns', (tester) async {
    final repo = FakeAuthRepository(
      sessionCheckError: const AuthNetworkException(message: 'offline'),
      restorableSession: sampleSession(),
    );

    await pumpApp(tester, repo);
    expect(find.byType(HomeScreen), findsOneWidget);

    // Reconnect finds the session gone: the repository settles
    // unauthenticated (the 401-clear path), which the bloc mirrors and the
    // shell routes on.
    repo.emitAuthState(const AuthStateUnauthenticated());
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.text(bannerMessage), findsNothing);
  });

  testWidgets('the banner consumes the top inset ONCE — content below has '
      'it removed while the banner shows, restored when it clears (#98 '
      'review F4)', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 60);
    addTearDown(tester.view.reset);

    final repo = FakeAuthRepository(
      sessionCheckError: const AuthNetworkException(message: 'offline'),
      restorableSession: sampleSession(),
    );

    await pumpApp(tester, repo);
    expect(find.text(bannerMessage), findsOneWidget);

    // While the banner shows (and has itself consumed the window inset via
    // its SafeArea), the shell content below must see NO top padding —
    // otherwise every route's app bar insets a second status-bar height.
    final homeContext = tester.element(find.byType(HomeScreen));
    expect(MediaQuery.of(homeContext).padding.top, 0);

    // Verified: banner clears, and the content gets its inset back.
    repo.emitAuthState(AuthStateAuthenticated(session: sampleSession()));
    await tester.pumpAndSettle();
    expect(find.text(bannerMessage), findsNothing);
    final clearedContext = tester.element(find.byType(HomeScreen));
    expect(MediaQuery.of(clearedContext).padding.top, greaterThan(0));
  });

  testWidgets('a dismissed banner stays dismissed for the episode, and the '
      'content inset is restored immediately on dismissal', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 60);
    addTearDown(tester.view.reset);

    final repo = FakeAuthRepository(
      sessionCheckError: const AuthNetworkException(message: 'offline'),
      restorableSession: sampleSession(),
    );

    await pumpApp(tester, repo);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text(bannerMessage), findsNothing);
    // Dismissal and inset compensation share an owner: no banner means no
    // removed padding, or content underlaps the status bar.
    final homeContext = tester.element(find.byType(HomeScreen));
    expect(MediaQuery.of(homeContext).padding.top, greaterThan(0));
  });

  testWidgets('dismissing the banner keeps the session and the home '
      'screen', (tester) async {
    final repo = FakeAuthRepository(
      sessionCheckError: const AuthNetworkException(message: 'offline'),
      restorableSession: sampleSession(),
    );

    await pumpApp(tester, repo);
    expect(find.text(bannerMessage), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text(bannerMessage), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('the banner reaches a screen reader over the shell routes', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    // Online but the server is unreachable: the banner shows on its own,
    // with the strip hidden.
    final connectivity = FakeConnectivity();
    addTearDown(connectivity.close);
    await pumpApp(
      tester,
      FakeAuthRepository(
        sessionCheckError: const AuthNetworkException(message: 'offline'),
        restorableSession: sampleSession(),
      ),
      connectivity: connectivity,
    );
    expect(find.text(bannerMessage), findsOneWidget);
    expect(find.text(offlineMessage), findsNothing);

    expect(
      tester.getSemantics(find.text(bannerMessage)),
      matchesSemantics(label: bannerMessage, isLiveRegion: true),
    );
    expect(
      _semanticsLabels(tester).where((l) => l.contains(bannerMessage)),
      hasLength(1),
      reason: 'one node, read once',
    );
    expect(
      _semanticsLabels(tester),
      contains('Dismiss'),
      reason: 'its only action is reachable too',
    );
    handle.dispose();
  });

  testWidgets('the strip shows on a route outside the auth shell', (
    tester,
  ) async {
    // Settings builds once the app-level settings controllers exist, and
    // those need hydrated storage.
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
    addTearDown(() => HydratedBloc.storage = null);
    final connectivity = FakeConnectivity();
    addTearDown(connectivity.close);

    await pumpApp(
      tester,
      FakeAuthRepository(initialSession: sampleSession()),
      connectivity: connectivity,
    );
    (tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
            as GoRouter)
        .go(AppRoutes.settings);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    await go(tester, connectivity, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));

    expect(find.text(offlineMessage), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('the unverified banner steps aside while the strip shows, and '
      'returns after the hold if still unverified', (tester) async {
    final connectivity = FakeConnectivity();
    addTearDown(connectivity.close);
    await pumpApp(
      tester,
      FakeAuthRepository(
        sessionCheckError: const AuthNetworkException(message: 'offline'),
        restorableSession: sampleSession(),
      ),
      connectivity: connectivity,
    );
    expect(find.text(bannerMessage), findsOneWidget);
    final home = tester.element(find.byType(HomeScreen));

    await go(tester, connectivity, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(offlineMessage), findsOneWidget);
    expect(find.text(bannerMessage), findsNothing);

    // Reconnecting asks the server again; it is still unreachable, so the
    // session stays unverified.
    await go(tester, connectivity, ConnectivityState.online);
    await tester.pump();
    expect(find.text(backOnlineMessage), findsOneWidget);
    expect(find.text(bannerMessage), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text(backOnlineMessage), findsNothing);
    expect(find.text(bannerMessage), findsOneWidget);
    expect(
      identical(tester.element(find.byType(HomeScreen)), home),
      isTrue,
      reason: 'neither notice remounts the screen below it',
    );
  });

  testWidgets('the crash barrier covers the strip', (tester) async {
    final handle = tester.ensureSemantics();
    final connectivity = FakeConnectivity();
    addTearDown(connectivity.close);
    final reporter = FeedbackUncaughtErrorReporter(
      service: StubFeedbackService(),
    );

    await pumpApp(
      tester,
      FakeAuthRepository(initialSession: sampleSession()),
      connectivity: connectivity,
      feedbackReporter: reporter,
    );
    await go(tester, connectivity, ConnectivityState.offline);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(
      _semanticsLabels(tester).where((l) => l.contains(offlineMessage)),
      hasLength(1),
      reason: 'read out before the crash',
    );

    reporter.report(
      UncaughtErrorRecord.capture(
        StateError('bad state'),
        StackTrace.fromString('#0 main (file.dart:1)'),
      ),
    );
    await tester.pump();

    expect(find.byType(CrashReportPrompt), findsOneWidget);
    final blocker = find.byKey(BgeApp.contentSemanticsBlockerKey);
    expect(tester.widget<BlockSemantics>(blocker).blocking, isTrue);
    expect(
      find.descendant(of: blocker, matching: find.byType(BgeOfflineStrip)),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.byType(BgeOfflineStrip),
        matching: find.byWidgetPredicate(
          (widget) => widget is ExcludeFocus && widget.excluding,
        ),
      ),
      findsOneWidget,
      reason: "outside the crash flow's focus scope",
    );
    expect(
      _semanticsLabels(tester).where((l) => l.contains(offlineMessage)),
      isEmpty,
    );
    handle.dispose();
  });
}
