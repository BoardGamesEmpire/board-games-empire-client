import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

BgeApp _app(AppBootstrapCubit cubit) => BgeApp(bootstrapCubit: cubit);

void main() {
  Future<void> noopHydrated(PlatformBootstrap _) async {}

  AppBootstrapCubit buildCubit(FakeAuthRepository repo) => AppBootstrapCubit(
    platformBootstrap: FakePlatformBootstrap(
      activeServerScope: FakeActiveServerScope(buildActiveServer(repo)),
    ),
    hydratedStorageInitializer: noopHydrated,
  );

  testWidgets('a restored session advances the gate to the home '
      'menu (splash → home, no form flash)', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final cubit = buildCubit(repo);
    addTearDown(cubit.close);

    await tester.pumpWidget(_app(cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);
  });

  testWidgets('no session lands on the auth screen', (tester) async {
    final repo = FakeAuthRepository(); // no session
    final cubit = buildCubit(repo);
    addTearDown(cubit.close);

    await tester.pumpWidget(_app(cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('sign-out from home returns to the auth screen', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final cubit = buildCubit(repo);
    addTearDown(cubit.close);

    await tester.pumpWidget(_app(cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);

    // Sign out now lives in the navigation drawer: open it first.
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });
}
