import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

/// #98 shell wiring: a session restored offline reaches home with the
/// unverified-session banner, and a confirming revalidation clears the
/// banner without re-running the session-start machinery.
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

  Future<AppBootstrapCubit> pumpApp(
    WidgetTester tester,
    FakeAuthRepository repo,
  ) async {
    final cubit = buildCubit(repo);
    addTearDown(cubit.close);
    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    return cubit;
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
    // SessionUnreachableView for AuthSessionCheckFailed.
    expect(find.byType(SessionUnreachableView), findsOneWidget);
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
}
