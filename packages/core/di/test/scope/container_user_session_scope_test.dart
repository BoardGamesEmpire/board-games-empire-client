import 'dart:async';

import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';

const _server = ScopedServer(serverId: 'bge-uuid-1', displayName: 'Origin');

/// Per-user service, so a test can observe that the scope pop disposed it.
class Probe {
  Probe(this.userId);
  final String userId;
  bool disposed = false;
}

/// Records what it was handed and registers a [Probe] keyed to the user.
class RecordingInstaller implements UserScopeInstaller {
  final calls = <({ScopedServer server, String userId})>[];

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    calls.add((server: server, userId: userId));
    final probe = Probe(userId);
    container.registerSingleton<Probe>(
      probe,
      dispose: (p) => p.disposed = true,
    );
  }
}

class ThrowingInstaller implements UserScopeInstaller {
  ThrowingInstaller(this.error);
  final Object error;

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async => throw error;
}

/// Installer that parks until released, for driving overlapping calls.
class GatedInstaller implements UserScopeInstaller {
  final gate = Completer<void>();
  final started = <String>[];

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    started.add(userId);
    await gate.future;
  }
}

/// Registers a service whose `dispose:` callback throws.
class BadTeardownInstaller implements UserScopeInstaller {
  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    container.registerSingleton<String>(
      'boom',
      dispose: (_) => throw StateError('teardown blew up'),
    );
  }
}

void main() {
  group('ContainerUserSessionScope', () {
    late DependencyContainer parent;
    late UserScopeHost host;
    late RecordingInstaller installer;
    late ContainerUserSessionScope scope;

    ContainerUserSessionScope build(List<UserScopeInstaller> installers) =>
        ContainerUserSessionScope(
          host: host,
          installers: installers,
          server: _server,
        );

    setUp(() {
      parent = DependencyContainerImpl();
      host = UserScopeHost(parent: () => parent);
      installer = RecordingInstaller();
      scope = build([installer]);
    });

    test('starts with no active session', () {
      expect(scope.activeUserId, isNull);
      expect(scope.isDisposed, isFalse);
      expect(host.isActive, isFalse);
    });

    test('activate runs the installers and records the user', () async {
      await scope.activate('user-a');

      expect(scope.activeUserId, 'user-a');
      expect(host.isActive, isTrue);
      expect(installer.calls, hasLength(1));
      expect(installer.calls.single.userId, 'user-a');
      expect(host.maybeGet<Probe>()?.userId, 'user-a');
    });

    test('installers are told about the server, not the config', () async {
      await scope.activate('user-a');

      expect(installer.calls.single.server, _server);
      expect(installer.calls.single.server.serverId, 'bge-uuid-1');
    });

    test('installers run in list order', () async {
      final order = <String>[];
      final first = _OrderInstaller('first', order);
      final second = _OrderInstaller('second', order);
      await build([first, second]).activate('user-a');

      expect(order, ['first', 'second']);
    });

    test('re-activating the same user is a no-op', () async {
      await scope.activate('user-a');
      final probe = host.maybeGet<Probe>();

      await scope.activate('user-a');

      expect(installer.calls, hasLength(1), reason: 'installers did not rerun');
      expect(host.maybeGet<Probe>(), same(probe));
      expect(probe!.disposed, isFalse);
    });

    test('a different user tears the previous scope down first', () async {
      await scope.activate('user-a');
      final first = host.maybeGet<Probe>()!;

      await scope.activate('user-b');

      expect(first.disposed, isTrue, reason: 'a missed pop cannot leak');
      expect(scope.activeUserId, 'user-b');
      expect(host.maybeGet<Probe>()!.userId, 'user-b');
      expect(installer.calls.map((c) => c.userId), ['user-a', 'user-b']);
    });

    test('deactivate disposes the scope and clears the user', () async {
      await scope.activate('user-a');
      final probe = host.maybeGet<Probe>()!;

      await scope.deactivate();

      expect(probe.disposed, isTrue);
      expect(scope.activeUserId, isNull);
      expect(host.isActive, isFalse);
    });

    test(
      'deactivate is idempotent and never throws for nothing to do',
      () async {
        await scope.deactivate();
        await scope.deactivate();

        expect(scope.activeUserId, isNull);
      },
    );

    test('deactivate leaves the parent scope untouched', () async {
      final base = Probe('base');
      parent.registerSingleton<Probe>(base, dispose: (p) => p.disposed = true);

      await scope.activate('user-a');
      await scope.deactivate();

      expect(base.disposed, isFalse);
      expect(parent.get<Probe>(), same(base));
    });

    test('a session can be rebuilt after deactivate', () async {
      await scope.activate('user-a');
      await scope.deactivate();
      await scope.activate('user-a');

      expect(scope.activeUserId, 'user-a');
      expect(host.maybeGet<Probe>()!.disposed, isFalse);
    });

    test('an installer failure propagates and leaves no session', () async {
      final failing = build([
        installer,
        ThrowingInstaller(ArgumentError('no')),
      ]);

      await expectLater(failing.activate('user-a'), throwsArgumentError);

      expect(failing.activeUserId, isNull);
      expect(host.isActive, isFalse, reason: 'partial scope discarded');
      expect(parent.isRegistered<Probe>(), isFalse, reason: 'parent untouched');
    });

    test('a retry after a failed activation starts clean', () async {
      var shouldFail = true;
      final flaky = build([installer, _ConditionalInstaller(() => shouldFail)]);

      await expectLater(flaky.activate('user-a'), throwsStateError);
      shouldFail = false;
      await flaky.activate('user-a');

      expect(flaky.activeUserId, 'user-a');
      expect(installer.calls, hasLength(2));
    });

    test('a throwing teardown still ends the session', () async {
      // The alternative is a sign-out that fails because some repository's
      // dispose callback threw, leaving the user signed in to a scope
      // nobody can use.
      final bad = build([BadTeardownInstaller()]);
      await bad.activate('user-a');

      await bad.deactivate();

      expect(bad.activeUserId, isNull);
      expect(host.isActive, isFalse);
    });

    group('serialization', () {
      test('overlapping activate/deactivate cannot interleave', () async {
        // The shell fires both handlers unawaited, so this overlap is
        // reachable in production, not just in a test.
        final gated = GatedInstaller();
        final serialized = build([gated, installer]);

        final activating = serialized.activate('user-a');
        // The chain picks the operation up on a microtask, so an activation
        // is not in flight the instant `activate` returns. Native's
        // `_enqueueScopeOp` behaves identically; the property that matters
        // is what happens to a *second* call once the first is running.
        await Future<void>.delayed(Duration.zero);
        expect(gated.started, ['user-a']);

        // Queued behind the in-flight activation rather than racing it.
        final deactivating = serialized.deactivate();

        expect(serialized.activeUserId, isNull, reason: 'still activating');

        gated.gate.complete();
        await activating;
        await deactivating;

        // The deactivation observed the completed activation and undid it,
        // rather than running against a half-built scope.
        expect(serialized.activeUserId, isNull);
        expect(host.isActive, isFalse);
        expect(installer.calls, hasLength(1));
      });

      test('a failed operation does not poison the chain', () async {
        final failing = build([ThrowingInstaller(StateError('boom'))]);

        await expectLater(failing.activate('user-a'), throwsStateError);
        // The next operation still runs rather than inheriting the error.
        await failing.deactivate();

        expect(failing.activeUserId, isNull);
      });
    });

    group('terminal state', () {
      test('dispose ends a live session', () async {
        await scope.activate('user-a');
        final probe = host.maybeGet<Probe>()!;

        await scope.dispose();

        expect(probe.disposed, isTrue);
        expect(scope.activeUserId, isNull);
        expect(scope.isDisposed, isTrue);
        expect(host.isActive, isFalse);
      });

      test(
        'activate after dispose throws rather than orphaning a scope',
        () async {
          // The obligation UserScopeHost hands to every owner: close() ends a
          // session, never the host, so without this guard an activation here
          // would build a child scope nothing will ever dispose.
          await scope.dispose();

          await expectLater(scope.activate('user-a'), throwsStateError);
          expect(host.isActive, isFalse);
          expect(installer.calls, isEmpty);
        },
      );

      test('deactivate after dispose is a no-op, not a throw', () async {
        await scope.dispose();

        await scope.deactivate();

        expect(scope.activeUserId, isNull);
      });

      test('dispose is idempotent', () async {
        await scope.activate('user-a');

        await scope.dispose();
        await scope.dispose();

        expect(scope.isDisposed, isTrue);
      });
    });

    test('wired as a container dispose hook, it ends the session', () async {
      // The composition contract: the server scope's teardown closes the
      // holder permanently, which is where its terminal state comes from.
      final container = DependencyContainerImpl();
      container.registerSingleton<UserSessionScope>(
        scope,
        dispose: (s) => (s as ContainerUserSessionScope).dispose(),
      );
      await scope.activate('user-a');
      final probe = host.maybeGet<Probe>()!;

      await container.dispose();

      expect(probe.disposed, isTrue);
      expect(scope.isDisposed, isTrue);
    });
  });
}

class _OrderInstaller implements UserScopeInstaller {
  _OrderInstaller(this.name, this.order);
  final String name;
  final List<String> order;

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async => order.add(name);
}

class _ConditionalInstaller implements UserScopeInstaller {
  _ConditionalInstaller(this.shouldFail);
  final bool Function() shouldFail;

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    if (shouldFail()) throw StateError('installer failed');
  }
}
