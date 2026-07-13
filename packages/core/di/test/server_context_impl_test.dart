import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:di/di.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';
import 'package:mocktail/mocktail.dart';

class MockDependencyContainer extends Mock implements DependencyContainer {}

/// Probe registered by [RecordingInstaller]; its dispose callback flips
/// [disposed] so tests can observe scope teardown.
class Probe {
  bool disposed = false;
}

/// [ServerScopeInstaller] that records every install call and registers a
/// fresh [Probe] with a teardown callback.
class RecordingInstaller implements ServerScopeInstaller {
  final installs = <ServerConfig>[];
  final probes = <Probe>[];

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    installs.add(config);
    final probe = Probe();
    probes.add(probe);
    container.registerSingleton<Probe>(
      probe,
      dispose: (p) => p.disposed = true,
    );
  }
}

/// Installer that always throws, for activation-failure paths.
class FailingInstaller implements ServerScopeInstaller {
  var calls = 0;

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    calls++;
    throw StateError('installer boom');
  }
}

ServerConfig _makeConfig({String id = 'server-local-1'}) => ServerConfig(
  id: id,
  displayName: 'Test Server',
  serverUrl: 'https://api.example.com',
  connectionState: ConnectionState.disconnected,
  bgeServerId: '550e8400-e29b-41d4-a716-446655440000',
  cachedIdentity: ServerIdentity(
    serverId: '550e8400-e29b-41d4-a716-446655440000',
    issuer: 'https://api.example.com',
    wellKnownSchemaVersion: 1,
    name: 'Test BGE Server',
    deviceAuthorizationEndpoint: 'https://api.example.com/api/auth/device',
    authBasePath: 'https://api.example.com/api/auth',
    sessionEndpoint: 'https://api.example.com/api/auth/get-session',
    signOutEndpoint: 'https://api.example.com/api/auth/sign-out',
    passkeySupported: true,
    twoFactorSupported: true,
    anonymousAuthSupported: true,
  ),
  lastIdentityFetchedAt: DateTime.now().toUtc(),
);

void main() {
  late ServerContextImpl context;
  late MockDependencyContainer mockContainer;

  setUp(() {
    mockContainer = MockDependencyContainer();
    when(() => mockContainer.dispose()).thenAnswer((_) async {});
    context = ServerContextImpl(
      config: _makeConfig(),
      containerFactory: () => mockContainer,
    );
  });

  tearDown(() async => context.dispose());

  group('ServerContextImpl', () {
    group('initial state', () {
      test('starts in initializing state', () {
        expect(context.state, ServerContextState.initializing);
      });

      test('exposes correct serverId', () {
        expect(context.serverId, 'server-local-1');
      });

      test('container delegates to the factory-provided container', () async {
        when(() => mockContainer.isRegistered<Probe>()).thenReturn(true);

        expect(context.container.isRegistered<Probe>(), isTrue);
        verify(() => mockContainer.isRegistered<Probe>()).called(1);
      });
    });

    group('activate()', () {
      test('transitions initializing → active', () async {
        await context.activate();
        expect(context.state, ServerContextState.active);
      });

      test('transitions monitoring → active', () async {
        await context.activate(); // initializing → active
        await context.background(); // active → backgrounding
        await context.suspend(); // backgrounding → monitoring
        await context.activate(); // monitoring → active
        expect(context.state, ServerContextState.active);
      });

      test('transitions backgrounding → active', () async {
        await context.activate(); // initializing → active
        await context.background(); // active → backgrounding
        await context.activate(); // backgrounding → active
        expect(context.state, ServerContextState.active);
      });

      test('throws when already active', () async {
        await context.activate();
        expect(() => context.activate(), throwsStateError);
      });

      test('throws when disposed', () async {
        await context.dispose();
        expect(() => context.activate(), throwsStateError);
      });
    });

    group('background()', () {
      test('transitions active → backgrounding', () async {
        await context.activate();
        await context.background();
        expect(context.state, ServerContextState.backgrounding);
      });

      test('throws when not active', () {
        expect(() => context.background(), throwsStateError);
      });

      test('throws when monitoring', () async {
        await context.activate();
        await context.background();
        await context.suspend();
        expect(() => context.background(), throwsStateError);
      });
    });

    group('suspend()', () {
      test('transitions backgrounding → monitoring', () async {
        await context.activate();
        await context.background();
        await context.suspend();
        expect(context.state, ServerContextState.monitoring);
      });

      test('throws when active (must background first)', () async {
        await context.activate();
        expect(() => context.suspend(), throwsStateError);
      });

      test('throws when initializing', () {
        expect(() => context.suspend(), throwsStateError);
      });
    });

    group('dispose()', () {
      test('transitions to disposed', () async {
        await context.activate();
        await context.dispose();
        expect(context.state, ServerContextState.disposed);
      });

      test('disposes the underlying container once one exists', () async {
        when(() => mockContainer.isRegistered<Probe>()).thenReturn(false);
        context.container.isRegistered<Probe>(); // materialize the inner

        await context.dispose();

        verify(() => mockContainer.dispose()).called(1);
      });

      test('does not construct a container just to dispose it', () async {
        var factoryCalls = 0;
        final untouched = ServerContextImpl(
          config: _makeConfig(),
          containerFactory: () {
            factoryCalls++;
            return mockContainer;
          },
        );

        await untouched.dispose();

        expect(factoryCalls, 0);
        verifyNever(() => mockContainer.dispose());
      });

      test('is idempotent', () async {
        when(() => mockContainer.isRegistered<Probe>()).thenReturn(false);
        context.container.isRegistered<Probe>(); // materialize the inner

        await context.dispose();
        await expectLater(context.dispose(), completes);
        verify(() => mockContainer.dispose()).called(1);
      });

      test('container use after dispose throws StateError', () async {
        await context.dispose();
        expect(() => context.container.isRegistered<Probe>(), throwsStateError);
      });
    });

    group('watchState()', () {
      test('replays current state immediately', () async {
        await expectLater(
          context.watchState().take(1),
          emits(ServerContextState.initializing),
        );
      });

      test('emits full lifecycle sequence', () async {
        final states = <ServerContextState>[];
        final sub = context.watchState().listen(states.add);

        await context.activate();
        await context.background();
        await context.suspend();
        await context.dispose();

        await sub.cancel();

        expect(
          states,
          containsAllInOrder([
            ServerContextState.initializing,
            ServerContextState.transitioning,
            ServerContextState.active,
            ServerContextState.transitioning,
            ServerContextState.backgrounding,
            ServerContextState.transitioning,
            ServerContextState.monitoring,
            ServerContextState.disposed,
          ]),
        );
      });
    });

    group('concurrent transition guard', () {
      test('throws on concurrent activation attempt', () async {
        // Start an activate and immediately try another.
        final first = context.activate();
        expect(() => context.activate(), throwsStateError);
        await first;
      });
    });
  });

  group('scope lifecycle (installers + real container)', () {
    late RecordingInstaller installer;
    late ServerContextImpl scoped;

    setUp(() {
      installer = RecordingInstaller();
      scoped = ServerContextImpl(
        config: _makeConfig(),
        installers: [installer],
      );
    });

    tearDown(() async => scoped.dispose());

    test('activate runs installers with the context config', () async {
      await scoped.activate();

      expect(installer.installs, hasLength(1));
      expect(installer.installs.single.id, 'server-local-1');
      expect(scoped.container.get<Probe>(), same(installer.probes.single));
    });

    test('installers run in order', () async {
      final order = <String>[];
      final first = _OrderInstaller('first', order);
      final second = _OrderInstaller('second', order);
      final ordered = ServerContextImpl(
        config: _makeConfig(),
        installers: [first, second],
      );
      addTearDown(ordered.dispose);

      await ordered.activate();

      expect(order, ['first', 'second']);
    });

    test('backgrounding → active does NOT re-run installers', () async {
      await scoped.activate();
      await scoped.background();
      await scoped.activate();

      expect(installer.installs, hasLength(1));
      // The retained probe is still registered and untouched.
      expect(scoped.container.get<Probe>().disposed, isFalse);
    });

    test(
      'suspend disposes the scope (registration dispose callbacks run)',
      () async {
        await scoped.activate();
        final probe = scoped.container.get<Probe>();

        await scoped.background();
        await scoped.suspend();

        expect(probe.disposed, isTrue);
        expect(scoped.container.isRegistered<Probe>(), isFalse);
      },
    );

    test('monitoring → active re-installs into a fresh scope', () async {
      await scoped.activate();
      final firstProbe = scoped.container.get<Probe>();
      await scoped.background();
      await scoped.suspend();

      await scoped.activate();

      expect(installer.installs, hasLength(2));
      final secondProbe = scoped.container.get<Probe>();
      expect(secondProbe, isNot(same(firstProbe)));
      expect(firstProbe.disposed, isTrue);
      expect(secondProbe.disposed, isFalse);
    });

    test('container identity is stable across the whole lifecycle', () async {
      final handle = scoped.container;

      await scoped.activate();
      expect(scoped.container, same(handle));
      await scoped.background();
      await scoped.suspend();
      expect(scoped.container, same(handle));
      await scoped.activate();
      expect(scoped.container, same(handle));

      // The stable handle resolves services registered after suspend.
      expect(handle.get<Probe>(), same(installer.probes.last));
    });

    test('installer failure rolls state back and resets the scope', () async {
      final failing = ServerContextImpl(
        config: _makeConfig(),
        installers: [RecordingInstaller(), FailingInstaller()],
      );
      addTearDown(failing.dispose);

      await expectLater(failing.activate(), throwsStateError);

      expect(failing.state, ServerContextState.initializing);
      // Partial registrations from the first installer were discarded.
      expect(failing.container.isRegistered<Probe>(), isFalse);
    });

    test('activate can be retried after an installer failure', () async {
      final flaky = _FlakyInstaller(failuresBeforeSuccess: 1);
      final retried = ServerContextImpl(
        config: _makeConfig(),
        installers: [flaky],
      );
      addTearDown(retried.dispose);

      await expectLater(retried.activate(), throwsStateError);
      expect(retried.state, ServerContextState.initializing);

      await retried.activate();

      expect(retried.state, ServerContextState.active);
      expect(flaky.calls, 2);
    });

    test('dispose during an in-flight activate waits, then wins', () async {
      final slow = _SlowInstaller();
      final racing = ServerContextImpl(
        config: _makeConfig(),
        installers: [slow],
      );

      final activation = racing.activate();
      final disposal = racing.dispose(); // issued mid-install

      slow.release();
      await activation;
      await disposal;

      expect(racing.state, ServerContextState.disposed);
      // The scope the activation built was torn down by the disposal.
      expect(slow.probe!.disposed, isTrue);
    });

    test('a failed activate cannot resurrect a disposed context', () async {
      final slow = _SlowInstaller(failOnRelease: true);
      final racing = ServerContextImpl(
        config: _makeConfig(),
        installers: [slow],
      );

      final activation = racing.activate();
      final disposal = racing.dispose();

      slow.release();
      await expectLater(activation, throwsStateError);
      await disposal;

      expect(racing.state, ServerContextState.disposed);
    });

    test(
      'installer failure is not masked by a throwing dispose callback',
      () async {
        final masked = ServerContextImpl(
          config: _makeConfig(),
          installers: [_ThrowingTeardownInstaller(), FailingInstaller()],
        );
        addTearDown(() async {
          try {
            await masked.dispose();
          } catch (_) {}
        });

        await expectLater(
          masked.activate(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'installer boom',
            ),
          ),
        );
        expect(masked.state, ServerContextState.initializing);
      },
    );
  });
}

/// Records install order under a shared list.
class _OrderInstaller implements ServerScopeInstaller {
  _OrderInstaller(this.name, this.order);

  final String name;
  final List<String> order;

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    order.add(name);
  }
}

/// Fails the first [failuresBeforeSuccess] install calls, then succeeds.
class _FlakyInstaller implements ServerScopeInstaller {
  _FlakyInstaller({required this.failuresBeforeSuccess});

  final int failuresBeforeSuccess;
  var calls = 0;

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    calls++;
    if (calls <= failuresBeforeSuccess) {
      throw StateError('flaky installer failure #$calls');
    }
  }
}

/// Installer that blocks until [release] is called, so tests can interleave
/// other lifecycle calls mid-install. Registers a [Probe] on success.
class _SlowInstaller implements ServerScopeInstaller {
  _SlowInstaller({this.failOnRelease = false});

  final bool failOnRelease;
  final _gate = Completer<void>();
  Probe? probe;

  void release() => _gate.complete();

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    await _gate.future;
    if (failOnRelease) throw StateError('slow installer failure');
    probe = Probe();
    container.registerSingleton<Probe>(
      probe!,
      dispose: (p) => p.disposed = true,
    );
  }
}

/// Marker type for [_ThrowingTeardownInstaller] — GetIt refuses `Object`
/// registrations.
class _TeardownBomb {}

/// Registers a singleton whose dispose callback throws, to prove scope
/// reset cannot mask the original installer error.
class _ThrowingTeardownInstaller implements ServerScopeInstaller {
  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    container.registerSingleton<_TeardownBomb>(
      _TeardownBomb(),
      dispose: (_) => throw StateError('teardown boom'),
    );
  }
}
