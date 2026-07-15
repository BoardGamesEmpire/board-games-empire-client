import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fake_platform_bootstrap.dart';

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

/// Pins the #37 auth transitions on [AppBootstrapCubit]:
/// `onAuthenticated` (NeedsAuth → Ready) and `onSignedOut`
/// (Ready → NeedsAuth), mirroring the `onServerRegistered` guarded
/// fire-and-forget pattern — idempotent, and no-ops from any other state.
void main() {
  Future<void> noopHydrated(PlatformBootstrap _) async {}

  AppBootstrapCubit buildCubit({required FakePlatformBootstrap bootstrap}) =>
      AppBootstrapCubit(
        platformBootstrap: bootstrap,
        hydratedStorageInitializer: noopHydrated,
      );

  /// A native-shaped bootstrap with a registered server → initialize
  /// lands on [AppBootstrapNeedsAuth].
  FakePlatformBootstrap serverRegistered() =>
      FakePlatformBootstrap(orchestrator: _MockServerOrchestrator());

  group('onAuthenticated()', () {
    blocTest<AppBootstrapCubit, AppBootstrapState>(
      'advances NeedsAuth → Ready (sign-in / sign-up / restore all arrive '
      'here identically)',
      build: () => buildCubit(bootstrap: serverRegistered()),
      act: (cubit) async {
        await cubit.initialize();
        cubit.onAuthenticated();
      },
      expect: () => const [AppBootstrapNeedsAuth(), AppBootstrapReady()],
    );

    blocTest<AppBootstrapCubit, AppBootstrapState>(
      'is idempotent — a duplicate signal from Ready is a no-op (the '
      'repository mirror re-confirming a session must not throw or '
      're-emit)',
      build: () => buildCubit(bootstrap: serverRegistered()),
      act: (cubit) async {
        await cubit.initialize();
        cubit.onAuthenticated();
        cubit.onAuthenticated();
      },
      expect: () => const [AppBootstrapNeedsAuth(), AppBootstrapReady()],
    );

    blocTest<AppBootstrapCubit, AppBootstrapState>(
      'is a no-op from NeedsServer — no server means no auth leg to '
      'advance past',
      build: () => buildCubit(
        bootstrap: FakePlatformBootstrap(
          outcomes: const [BootstrapResult(hasServer: false)],
        ),
      ),
      act: (cubit) async {
        await cubit.initialize();
        cubit.onAuthenticated();
      },
      expect: () => const [AppBootstrapNeedsServer()],
    );

    test('is a no-op before initialize() (Initializing state)', () {
      final cubit = buildCubit(bootstrap: FakePlatformBootstrap());
      addTearDown(cubit.close);

      cubit.onAuthenticated();

      expect(cubit.state, const AppBootstrapInitializing());
    });
  });

  group('onSignedOut()', () {
    blocTest<AppBootstrapCubit, AppBootstrapState>(
      'returns Ready → NeedsAuth on sign-out',
      build: () => buildCubit(bootstrap: serverRegistered()),
      act: (cubit) async {
        await cubit.initialize();
        cubit.onAuthenticated();
        cubit.onSignedOut();
      },
      expect: () => const [
        AppBootstrapNeedsAuth(),
        AppBootstrapReady(),
        AppBootstrapNeedsAuth(),
      ],
    );

    blocTest<AppBootstrapCubit, AppBootstrapState>(
      'is a no-op from NeedsAuth — an unauthenticated signal during the '
      'auth leg (a restore finding no session) leaves the app where it '
      'already is',
      build: () => buildCubit(bootstrap: serverRegistered()),
      act: (cubit) async {
        await cubit.initialize();
        cubit.onSignedOut();
        cubit.onSignedOut();
      },
      expect: () => const [AppBootstrapNeedsAuth()],
    );

    test('is a no-op before initialize() (Initializing state)', () {
      final cubit = buildCubit(bootstrap: FakePlatformBootstrap());
      addTearDown(cubit.close);

      cubit.onSignedOut();

      expect(cubit.state, const AppBootstrapInitializing());
    });
  });

  group('re-authentication round trip', () {
    blocTest<AppBootstrapCubit, AppBootstrapState>(
      'NeedsAuth → Ready → NeedsAuth → Ready (mid-session token expiry, '
      'then a fresh sign-in)',
      build: () => buildCubit(bootstrap: serverRegistered()),
      act: (cubit) async {
        await cubit.initialize();
        cubit.onAuthenticated();
        cubit.onSignedOut();
        cubit.onAuthenticated();
      },
      expect: () => const [
        AppBootstrapNeedsAuth(),
        AppBootstrapReady(),
        AppBootstrapNeedsAuth(),
        AppBootstrapReady(),
      ],
    );
  });
}
