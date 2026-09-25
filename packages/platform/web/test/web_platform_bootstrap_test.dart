// Runs on the VM: this suite exercises the platform-neutral half of the
// composition root (`web.dart`). Tagged explicitly since #288 added a
// browser-only suite beside it — `melos run test:web` runs Chrome over the
// whole package, and a widget test has no business being re-run there.
@TestOn('vm')
library;

import 'dart:async';

import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';
import 'package:web_platform/web.dart';

/// A stand-in [ActiveServerScope] for the [WebPlatformBootstrap.initialize]
/// seam tests. The production builder ([bootstrapWebServerScope]) performs a
/// live same-origin well-known fetch, which is unavailable on the test VM
/// (and `Uri.base` has no origin there) — the constant-holder semantics of
/// the real web scope are covered by `web_network`'s own tests. These tests
/// only assert that `initialize` returns whatever the builder produces.
class _FakeActiveServerScope implements ActiveServerScope {
  @override
  ActiveServer? get active => null;

  @override
  Stream<ActiveServer?> watchActive() => const Stream.empty();
}

/// A per-server container that counts its disposals, and whose disposal can
/// be held open on [closing].
class _SpyContainer extends DependencyContainerImpl {
  int disposeCalls = 0;
  Future<void>? closing;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await closing;
    await super.dispose();
  }
}

/// The shape `bootstrapWebServerScope` returns: one server, over [container].
class _FakeServerScope implements ActiveServerScope {
  _FakeServerScope(this.container);

  final _SpyContainer container;

  @override
  ActiveServer get active => ActiveServer(
    serverId: 'server-uuid-1',
    displayName: 'Test BGE Server',
    identity: _identity,
    container: container,
  );

  @override
  Stream<ActiveServer?> watchActive() => Stream.value(active);
}

const _identity = ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://bge.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '/api/auth/device',
  authBasePath: '/api/auth',
  sessionEndpoint: '/api/auth/get-session',
  signOutEndpoint: '/api/auth/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: [],
);

void main() {
  group('WebPlatformBootstrap', () {
    final bootstrap = WebPlatformBootstrap();

    test('never supports the destructive reset', () {
      expect(bootstrap.supportsReset, isFalse);
    });

    test('reset() throws UnsupportedError', () async {
      await expectLater(bootstrap.reset(), throwsUnsupportedError);
    });
  });

  group('WebPlatformBootstrap.initialize', () {
    test('a server is present by construction (the serving origin), there '
        'is no orchestrator, and the scope comes from the builder', () async {
      final scope = _FakeActiveServerScope();
      final bootstrap = WebPlatformBootstrap(
        serverScopeBuilder: () async => scope,
      );

      final result = await bootstrap.initialize();

      expect(result.hasServer, isTrue);
      expect(result.orchestrator, isNull);
      expect(result.activeServerScope, same(scope));
    });

    test(
      'propagates a scope-builder failure unchanged — the shell surfaces '
      'it as the retryable bootstrap-failure state, never "needs server"',
      () async {
        final bootstrap = WebPlatformBootstrap(
          serverScopeBuilder: () async =>
              throw StateError('well-known unreachable'),
        );

        await expectLater(bootstrap.initialize(), throwsStateError);
      },
    );
  });

  // #384: web's scope holds the drift/wasm database and the user session
  // (#288, #137), so web has something to release too.
  group('WebPlatformBootstrap.dispose', () {
    test('disposes the per-server container initialize() built', () async {
      final container = _SpyContainer();
      final bootstrap = WebPlatformBootstrap(
        serverScopeBuilder: () async => _FakeServerScope(container),
      );
      await bootstrap.initialize();

      await bootstrap.dispose();

      expect(container.disposeCalls, 1);
    });

    test('a second initialize() releases the server the first one built, '
        'as native does', () async {
      final first = _SpyContainer();
      final second = _SpyContainer();
      final containers = [first, second];
      final bootstrap = WebPlatformBootstrap(
        serverScopeBuilder: () async =>
            _FakeServerScope(containers.removeAt(0)),
      );
      await bootstrap.initialize();

      await bootstrap.initialize();

      expect(first.disposeCalls, 1);
      await bootstrap.dispose();
      expect(second.disposeCalls, 1);
    });

    test('a second caller waits for the teardown the first caller '
        'started', () async {
      final closing = Completer<void>();
      final container = _SpyContainer()..closing = closing.future;
      final bootstrap = WebPlatformBootstrap(
        serverScopeBuilder: () async => _FakeServerScope(container),
      );
      await bootstrap.initialize();

      unawaited(bootstrap.dispose());
      var secondReturned = false;
      final second = bootstrap.dispose().then((_) => secondReturned = true);
      await pumpEventQueue();
      expect(secondReturned, isFalse);

      closing.complete();
      await second;
      expect(container.disposeCalls, 1);
    });

    test('is terminal: initialize() afterwards throws without building a '
        'scope', () async {
      var built = 0;
      final bootstrap = WebPlatformBootstrap(
        serverScopeBuilder: () async {
          built++;
          return _FakeServerScope(_SpyContainer());
        },
      );

      await bootstrap.dispose();

      await expectLater(bootstrap.initialize(), throwsStateError);
      expect(built, 0);
    });

    test('during initialize(), waits for the attempt — which disposes the '
        'scope it built instead of committing it', () async {
      final building = Completer<ActiveServerScope>();
      final container = _SpyContainer();
      final bootstrap = WebPlatformBootstrap(
        serverScopeBuilder: () => building.future,
      );

      final attempt = bootstrap.initialize();
      await pumpEventQueue();
      var disposed = false;
      final disposal = bootstrap.dispose().then((_) => disposed = true);
      await pumpEventQueue();
      expect(disposed, isFalse);

      building.complete(_FakeServerScope(container));
      await expectLater(attempt, throwsStateError);
      await disposal;
      expect(container.disposeCalls, 1);
    });
  });
}
