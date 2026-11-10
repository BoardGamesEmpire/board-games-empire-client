import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

class _MockActiveServerScope extends Mock implements ActiveServerScope {}

class _MockWellKnownClient extends Mock implements WellKnownClient {}

class _MockConnectivityService extends Mock implements ConnectivityService {}

final _rebuiltServer = ServerConfig(
  id: 'server-local-1',
  displayName: 'Game Night Server',
  serverUrl: 'https://api.example.com',
  connectionState: ConnectionState.active,
  bgeServerId: '550e8400-e29b-41d4-a716-446655440000',
  cachedIdentity: serverIdentity(),
  lastIdentityFetchedAt: DateTime.utc(2026, 10, 20),
);

/// Counting [HydratedStorageInitializer] that never touches real storage.
class _HydratedSpy {
  _HydratedSpy({this.failFirstCall = false});

  final bool failFirstCall;
  int callCount = 0;

  Future<void> call(PlatformBootstrap _) async {
    callCount++;
    if (failFirstCall && callCount == 1) {
      throw StateError('hydrated storage init failed');
    }
  }
}

void main() {
  final bootFailure = Exception('meta db open failed');

  AppBootstrapCubit buildCubit({
    required FakePlatformBootstrap bootstrap,
    _HydratedSpy? hydrated,
    int resetOfferThreshold = 3,
  }) => AppBootstrapCubit(
    platformBootstrap: bootstrap,
    hydratedStorageInitializer: (hydrated ?? _HydratedSpy()).call,
    resetOfferThreshold: resetOfferThreshold,
  );

  group('AppBootstrapCubit', () {
    test('starts in AppBootstrapInitializing', () {
      final cubit = buildCubit(bootstrap: FakePlatformBootstrap());
      addTearDown(cubit.close);

      expect(cubit.state, const AppBootstrapInitializing());
    });

    group('initialize()', () {
      blocTest<AppBootstrapCubit, AppBootstrapState>(
        'emits NeedsServer when the platform reports no registered server',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(
            outcomes: const [BootstrapResult(hasServer: false)],
          ),
        ),
        act: (cubit) => cubit.initialize(),
        expect: () => const [AppBootstrapNeedsServer()],
      );

      blocTest<AppBootstrapCubit, AppBootstrapState>(
        'emits NeedsAuth when a server is registered — never Ready from '
        'bootstrap (the authenticated → home leg belongs to #37)',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(
            orchestrator: _MockServerOrchestrator(),
          ),
        ),
        act: (cubit) => cubit.initialize(),
        expect: () => const [AppBootstrapNeedsAuth()],
      );

      blocTest<AppBootstrapCubit, AppBootstrapState>(
        'emits NeedsAuth for a web-shaped bootstrap '
        '(hasServer true, no orchestrator)',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(
            outcomes: const [BootstrapResult(hasServer: true)],
            supportsReset: false,
          ),
        ),
        act: (cubit) => cubit.initialize(),
        expect: () => const [AppBootstrapNeedsAuth()],
      );

      test(
        'exposes the platform orchestrator after a successful run',
        () async {
          final orchestrator = _MockServerOrchestrator();
          final cubit = buildCubit(
            bootstrap: FakePlatformBootstrap(orchestrator: orchestrator),
          );
          addTearDown(cubit.close);

          expect(cubit.orchestrator, isNull);
          await cubit.initialize();

          expect(cubit.orchestrator, same(orchestrator));
        },
      );

      // #428: the shell tells the user about a database rebuilt during boot.
      blocTest<AppBootstrapCubit, AppBootstrapState>(
        'emits NeedsAuth carrying the servers rebuilt during the boot',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(
            outcomes: [
              BootstrapResult(
                hasServer: true,
                recoveredServers: [_rebuiltServer],
              ),
            ],
          ),
        ),
        act: (cubit) => cubit.initialize(),
        expect: () => [
          AppBootstrapNeedsAuth(recoveredServers: [_rebuiltServer]),
        ],
      );

      test('orchestrator stays null for a web-shaped bootstrap', () async {
        final cubit = buildCubit(
          bootstrap: FakePlatformBootstrap(
            outcomes: const [BootstrapResult(hasServer: true)],
            supportsReset: false,
          ),
        );
        addTearDown(cubit.close);

        await cubit.initialize();

        expect(cubit.orchestrator, isNull);
      });

      blocTest<AppBootstrapCubit, AppBootstrapState>(
        'emits Failed(attemptCount: 1, canOfferReset: false) when the '
        'platform initialize throws',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(outcomes: [bootFailure]),
        ),
        act: (cubit) => cubit.initialize(),
        expect: () => [
          AppBootstrapFailed(
            error: bootFailure,
            attemptCount: 1,
            canOfferReset: false,
          ),
        ],
      );

      blocTest<AppBootstrapCubit, AppBootstrapState>(
        'emits Failed when hydrated storage initialization throws',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(),
          hydrated: _HydratedSpy(failFirstCall: true),
        ),
        act: (cubit) => cubit.initialize(),
        expect: () => [
          isA<AppBootstrapFailed>()
              .having((s) => s.attemptCount, 'attemptCount', 1)
              .having((s) => s.canOfferReset, 'canOfferReset', isFalse),
        ],
      );

      test('a second initialize() throws StateError and does not re-run '
          'the platform bootstrap', () async {
        final bootstrap = FakePlatformBootstrap();
        final cubit = buildCubit(bootstrap: bootstrap);
        addTearDown(cubit.close);

        await cubit.initialize();
        await expectLater(cubit.initialize(), throwsStateError);

        expect(bootstrap.initializeCallCount, 1);
      });
    });

    group('onServerRegistered()', () {
      blocTest<AppBootstrapCubit, AppBootstrapState>(
        'advances NeedsServer → NeedsAuth after onboarding succeeds (#36)',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(
            outcomes: const [BootstrapResult(hasServer: false)],
          ),
        ),
        act: (cubit) async {
          await cubit.initialize();
          cubit.onServerRegistered();
        },
        expect: () => const [
          AppBootstrapNeedsServer(),
          AppBootstrapNeedsAuth(),
        ],
      );

      blocTest<AppBootstrapCubit, AppBootstrapState>(
        'is a no-op outside NeedsServer (duplicate/late success signals '
        'must not throw or re-emit)',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(
            orchestrator: _MockServerOrchestrator(),
          ),
        ),
        act: (cubit) async {
          await cubit.initialize(); // → NeedsAuth
          cubit
            ..onServerRegistered() // already past server-add
            ..onServerRegistered();
        },
        expect: () => const [AppBootstrapNeedsAuth()],
      );

      test('is a no-op before initialize() (Initializing state)', () {
        final cubit = buildCubit(bootstrap: FakePlatformBootstrap());
        addTearDown(cubit.close);

        cubit.onServerRegistered();

        expect(cubit.state, const AppBootstrapInitializing());
      });
    });

    group('retry()', () {
      blocTest<AppBootstrapCubit, AppBootstrapState>(
        're-emits Initializing, then the outcome; attemptCount accumulates '
        'across consecutive failures',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(outcomes: [bootFailure]),
        ),
        act: (cubit) async {
          await cubit.initialize();
          await cubit.retry();
        },
        expect: () => [
          AppBootstrapFailed(
            error: bootFailure,
            attemptCount: 1,
            canOfferReset: false,
          ),
          const AppBootstrapInitializing(),
          AppBootstrapFailed(
            error: bootFailure,
            attemptCount: 2,
            canOfferReset: false,
          ),
        ],
      );

      blocTest<AppBootstrapCubit, AppBootstrapState>(
        'succeeds after a failure and leaves the failure behind',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(
            outcomes: [bootFailure, const BootstrapResult(hasServer: false)],
          ),
        ),
        act: (cubit) async {
          await cubit.initialize();
          await cubit.retry();
        },
        expect: () => [
          isA<AppBootstrapFailed>(),
          const AppBootstrapInitializing(),
          const AppBootstrapNeedsServer(),
        ],
      );

      blocTest<AppBootstrapCubit, AppBootstrapState>(
        'offers reset once attemptCount reaches the threshold on a platform '
        'that supports it',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(outcomes: [bootFailure]),
        ),
        act: (cubit) async {
          await cubit.initialize();
          await cubit.retry();
          await cubit.retry();
        },
        expect: () => [
          isA<AppBootstrapFailed>()
              .having((s) => s.attemptCount, 'attemptCount', 1)
              .having((s) => s.canOfferReset, 'canOfferReset', isFalse),
          const AppBootstrapInitializing(),
          isA<AppBootstrapFailed>()
              .having((s) => s.attemptCount, 'attemptCount', 2)
              .having((s) => s.canOfferReset, 'canOfferReset', isFalse),
          const AppBootstrapInitializing(),
          isA<AppBootstrapFailed>()
              .having((s) => s.attemptCount, 'attemptCount', 3)
              .having((s) => s.canOfferReset, 'canOfferReset', isTrue),
        ],
      );

      blocTest<AppBootstrapCubit, AppBootstrapState>(
        'never offers reset when the platform does not support it '
        '(web), no matter how many attempts fail',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(
            outcomes: [bootFailure],
            supportsReset: false,
          ),
          resetOfferThreshold: 2,
        ),
        act: (cubit) async {
          await cubit.initialize();
          await cubit.retry();
          await cubit.retry();
        },
        verify: (cubit) {
          final state = cubit.state;
          expect(state, isA<AppBootstrapFailed>());
          state as AppBootstrapFailed;
          expect(state.attemptCount, 3);
          expect(state.canOfferReset, isFalse);
        },
      );

      test('is a no-op outside a failed state (no throw, no re-run)', () async {
        final bootstrap = FakePlatformBootstrap();
        final cubit = buildCubit(bootstrap: bootstrap);
        addTearDown(cubit.close);

        // Before initialize() — still Initializing.
        await cubit.retry();
        expect(bootstrap.initializeCallCount, 0);

        await cubit.initialize();
        expect(cubit.state, const AppBootstrapNeedsAuth());

        // After success — nothing to retry.
        await cubit.retry();
        expect(cubit.state, const AppBootstrapNeedsAuth());
        expect(bootstrap.initializeCallCount, 1);
      });

      test('a rapid double-tap does not throw: the second retry() lands '
          'while initializing and no-ops', () async {
        final bootstrap = FakePlatformBootstrap(
          outcomes: [bootFailure, const BootstrapResult(hasServer: false)],
        );
        final cubit = buildCubit(bootstrap: bootstrap);
        addTearDown(cubit.close);

        await cubit.initialize(); // attempt 1 fails
        expect(cubit.state, isA<AppBootstrapFailed>());

        // Fire-and-forget, twice, without awaiting in between — exactly
        // what two fast taps on the retry button produce.
        final first = cubit.retry();
        final second = cubit.retry();
        await Future.wait([first, second]);

        expect(cubit.state, const AppBootstrapNeedsServer());
        // Initial attempt + one retry; the double-tap did not re-run.
        expect(bootstrap.initializeCallCount, 2);
      });
    });

    group('hydrated storage initialization', () {
      test('runs once across retries after it has succeeded', () async {
        final hydrated = _HydratedSpy();
        final cubit = buildCubit(
          bootstrap: FakePlatformBootstrap(
            outcomes: [bootFailure, const BootstrapResult(hasServer: true)],
          ),
          hydrated: hydrated,
        );
        addTearDown(cubit.close);

        await cubit.initialize(); // hydrated ok, platform fails
        await cubit.retry(); // platform succeeds

        expect(hydrated.callCount, 1);
      });

      test('is re-attempted on retry after it failed', () async {
        final hydrated = _HydratedSpy(failFirstCall: true);
        final cubit = buildCubit(
          bootstrap: FakePlatformBootstrap(
            outcomes: const [BootstrapResult(hasServer: true)],
          ),
          hydrated: hydrated,
        );
        addTearDown(cubit.close);

        await cubit.initialize(); // hydrated throws
        expect(cubit.state, isA<AppBootstrapFailed>());

        await cubit.retry(); // hydrated succeeds this time

        expect(hydrated.callCount, 2);
        expect(cubit.state, const AppBootstrapNeedsAuth());
      });
    });

    group('resetAndRetry()', () {
      blocTest<AppBootstrapCubit, AppBootstrapState>(
        'calls platform reset() before re-initializing and restarts the '
        'attempt counter',
        build: () => buildCubit(
          bootstrap: FakePlatformBootstrap(
            outcomes: [bootFailure, bootFailure, bootFailure],
          ),
          resetOfferThreshold: 2,
        ),
        act: (cubit) async {
          await cubit.initialize(); // attempt 1
          await cubit.retry(); // attempt 2 → reset offered
          await cubit.resetAndRetry(); // reset, then attempt fails again
        },
        verify: (cubit) {
          final state = cubit.state;
          expect(state, isA<AppBootstrapFailed>());
          state as AppBootstrapFailed;
          // Counter restarted after the reset.
          expect(state.attemptCount, 1);
          expect(state.canOfferReset, isFalse);
        },
      );

      test('invokes reset() exactly once, before the re-initialize', () async {
        final bootstrap = FakePlatformBootstrap(
          outcomes: [
            bootFailure,
            bootFailure,
            const BootstrapResult(hasServer: false),
          ],
        );
        final cubit = buildCubit(bootstrap: bootstrap, resetOfferThreshold: 2);
        addTearDown(cubit.close);

        await cubit.initialize();
        await cubit.retry();
        await cubit.resetAndRetry();

        expect(bootstrap.calls, [
          'initialize',
          'initialize',
          'reset',
          'initialize',
        ]);
        expect(cubit.state, const AppBootstrapNeedsServer());
      });

      test(
        'is a no-op and performs no reset when the offer is not active',
        () async {
          final bootstrap = FakePlatformBootstrap(outcomes: [bootFailure]);
          final cubit = buildCubit(
            bootstrap: bootstrap,
          );
          addTearDown(cubit.close);

          await cubit.initialize(); // attempt 1 — below threshold
          final stateBefore = cubit.state;
          await cubit.resetAndRetry();

          expect(bootstrap.resetCallCount, 0);
          expect(cubit.state, stateBefore);
          expect(bootstrap.initializeCallCount, 1);
        },
      );

      test('a failed reset is a failed attempt that keeps the reset offer '
          'open, and runs no initialize', () async {
        final resetFailure = Exception('meta db delete failed');
        final bootstrap = FakePlatformBootstrap(
          outcomes: [bootFailure, bootFailure],
        )..resetError = resetFailure;
        final cubit = buildCubit(bootstrap: bootstrap, resetOfferThreshold: 2);
        addTearDown(cubit.close);

        await cubit.initialize();
        await cubit.retry(); // attempt 2 → reset offered
        await cubit.resetAndRetry();

        final state = cubit.state;
        expect(state, isA<AppBootstrapFailed>());
        state as AppBootstrapFailed;
        expect(state.error, same(resetFailure));
        expect(state.attemptCount, 3);
        expect(state.canOfferReset, isTrue);
        expect(bootstrap.calls, ['initialize', 'initialize', 'reset']);
      });
    });
  });

  group('server-add composition check (#218)', () {
    const noServer = BootstrapResult(hasServer: false);

    ServerOnboardingDeps deps() => ServerOnboardingDeps(
      wellKnownClient: _MockWellKnownClient(),
      versionNegotiator: const VersionNegotiatorImpl(),
      connectivityService: _MockConnectivityService(),
      buildInfo: BuildInfo.unknown,
    );

    DependencyContainerImpl rootContainer() {
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);
      return container;
    }

    AppBootstrapCubit cubitOver(
      FakePlatformBootstrap bootstrap,
      DependencyContainer? root, {
      int resetOfferThreshold = 3,
    }) {
      final cubit = AppBootstrapCubit(
        platformBootstrap: bootstrap,
        hydratedStorageInitializer: _HydratedSpy().call,
        resetOfferThreshold: resetOfferThreshold,
        rootContainer: root,
      );
      addTearDown(cubit.close);
      return cubit;
    }

    Matcher compositionFailure(Object causeMatcher) => isA<AppBootstrapFailed>()
        .having((s) => s.canOfferReset, 'canOfferReset', isFalse)
        .having(
          (s) => s.error,
          'error',
          isA<ServerAddCompositionError>().having(
            (e) => e.cause,
            'cause',
            causeMatcher,
          ),
        );

    test('emits NeedsServer when the bundle resolves', () async {
      final root = rootContainer()
        ..registerLazySingleton<ServerOnboardingDeps>(deps);
      final cubit = cubitOver(
        FakePlatformBootstrap(outcomes: [noServer]),
        root,
      );

      await cubit.initialize();

      expect(cubit.state, const AppBootstrapNeedsServer());
    });

    test('emits Failed with ServerAddCompositionError when the bundle is not '
        'registered', () async {
      final cubit = cubitOver(
        FakePlatformBootstrap(outcomes: [noServer]),
        rootContainer(),
      );

      await cubit.initialize();

      expect(cubit.state, compositionFailure(isStateError));
    });

    test("emits Failed with the factory's error as cause when the bundle "
        'factory throws', () async {
      final boom = Exception('boom');
      final root = rootContainer()
        ..registerLazySingleton<ServerOnboardingDeps>(() => throw boom);
      final cubit = cubitOver(
        FakePlatformBootstrap(outcomes: [noServer]),
        root,
      );

      await cubit.initialize();

      expect(cubit.state, compositionFailure(same(boom)));
    });

    test('the error names its cause, so the log line carries the absent '
        'member', () async {
      final cubit = cubitOver(
        FakePlatformBootstrap(outcomes: [noServer]),
        rootContainer(),
      );

      await cubit.initialize();

      final error = (cubit.state as AppBootstrapFailed).error;
      expect(
        error.toString(),
        allOf(
          startsWith('ServerAddCompositionError: '),
          contains('ServerOnboardingDeps'),
        ),
      );
    });

    test('never offers reset for a composition failure', () async {
      final cubit = cubitOver(
        FakePlatformBootstrap(outcomes: [noServer]),
        rootContainer(),
        resetOfferThreshold: 1,
      );

      await cubit.initialize();
      expect(cubit.state, compositionFailure(isStateError));
      await cubit.retry();

      final failed = cubit.state as AppBootstrapFailed;
      expect(failed.attemptCount, 2);
      expect(failed.canOfferReset, isFalse);
    });

    test('composition failures do not count toward the reset offer', () async {
      final cubit = cubitOver(
        FakePlatformBootstrap(
          outcomes: [
            noServer,
            noServer,
            StateError('meta db'),
            StateError('meta db'),
            StateError('meta db'),
          ],
        ),
        rootContainer(),
      );

      await cubit.initialize();
      await cubit.retry();
      await cubit.retry();
      final firstStorageFailure = cubit.state as AppBootstrapFailed;
      await cubit.retry();
      final secondStorageFailure = cubit.state as AppBootstrapFailed;
      await cubit.retry();
      final thirdStorageFailure = cubit.state as AppBootstrapFailed;

      expect(firstStorageFailure.attemptCount, 3);
      expect(firstStorageFailure.canOfferReset, isFalse);
      expect(secondStorageFailure.canOfferReset, isFalse);
      expect(thirdStorageFailure.attemptCount, 5);
      expect(thirdStorageFailure.canOfferReset, isTrue);
    });

    test(
      'control: any other failure at the same threshold offers reset',
      () async {
        final cubit = cubitOver(
          FakePlatformBootstrap(outcomes: [StateError('meta db')]),
          rootContainer(),
          resetOfferThreshold: 1,
        );

        await cubit.initialize();

        expect((cubit.state as AppBootstrapFailed).canOfferReset, isTrue);
      },
    );

    test('publishes no orchestrator or scope when the check fails', () async {
      final cubit = cubitOver(
        FakePlatformBootstrap(
          outcomes: [
            BootstrapResult(
              hasServer: false,
              orchestrator: _MockServerOrchestrator(),
              activeServerScope: _MockActiveServerScope(),
            ),
          ],
        ),
        rootContainer(),
      );

      await cubit.initialize();

      expect(cubit.state, compositionFailure(isStateError));
      expect(cubit.orchestrator, isNull);
      expect(cubit.activeServerScope, isNull);
    });

    test('retry reaches NeedsServer once the factory stops throwing', () async {
      var calls = 0;
      final root = rootContainer()
        ..registerLazySingleton<ServerOnboardingDeps>(() {
          calls++;
          if (calls == 1) throw StateError('transient');
          return deps();
        });
      final cubit = cubitOver(
        FakePlatformBootstrap(outcomes: [noServer]),
        root,
      );

      await cubit.initialize();
      expect(cubit.state, isA<AppBootstrapFailed>());
      await cubit.retry();

      expect(cubit.state, const AppBootstrapNeedsServer());
    });

    test('skips the check when initialize reports a server', () async {
      final cubit = cubitOver(
        FakePlatformBootstrap(
          outcomes: const [BootstrapResult(hasServer: true)],
        ),
        rootContainer(),
      );

      await cubit.initialize();

      expect(cubit.state, const AppBootstrapNeedsAuth());
    });

    test('skips the check with no root container', () async {
      final cubit = cubitOver(
        FakePlatformBootstrap(outcomes: [noServer]),
        null,
      );

      await cubit.initialize();

      expect(cubit.state, const AppBootstrapNeedsServer());
    });
  });

  group('logging', () {
    test('a failed bootstrap attempt emits an error-level record for the '
        'breadcrumb trail feedback reports rely on', () async {
      final records = <LogRecord>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(() async {
        await subscription.cancel();
        Logger.root.level = previousLevel;
      });

      final cubit = buildCubit(
        bootstrap: FakePlatformBootstrap(outcomes: [bootFailure]),
      );
      addTearDown(cubit.close);

      await cubit.initialize();

      expect(
        records.where(
          (r) =>
              r.loggerName == 'bge.shell.bootstrap' &&
              r.level == Level.SEVERE &&
              r.error == bootFailure,
        ),
        hasLength(1),
      );
    });
  });
}
