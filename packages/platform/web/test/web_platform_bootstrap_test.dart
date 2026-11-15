// Runs on the VM: this suite exercises the platform-neutral half of the
// composition root (`web.dart`). Tagged explicitly since #288 added a
// browser-only suite beside it — `melos run test:web` runs Chrome over the
// whole package, and a widget test has no business being re-run there.
@TestOn('vm')
library;

import 'dart:async';

import 'package:app_shell/app_shell.dart' show LocalDataInUseError;
import 'package:bge_test_support/domain.dart';
import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:web_platform/web.dart';

/// A stand-in [ActiveServerScope] for the [WebPlatformBootstrap.initialize]
/// seam tests. The production builder (`bootstrapWebServerScope`) performs a
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
  void Function()? onDispose;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    onDispose?.call();
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
    identity: testServerIdentity(),
    container: container,
  );

  @override
  Stream<ActiveServer?> watchActive() => Stream.value(active);
}

/// A [WebStorageReset] that records its calls.
class _FakeStorageReset implements WebStorageReset {
  _FakeStorageReset({this.answering, this.onDeleteAll});

  final bool Function(Object error)? answering;
  final Future<void> Function()? onDeleteAll;
  int deleteAllCalls = 0;

  @override
  bool answers(Object error) => answering?.call(error) ?? false;

  @override
  Future<void> deleteAll() async {
    deleteAllCalls++;
    await onDeleteAll?.call();
  }
}

void main() {
  group('WebPlatformBootstrap', () {
    final bootstrap = WebPlatformBootstrap();

    test("the browser's own Back is the way back (#611)", () {
      expect(bootstrap.browserOwnsBack, isTrue);
    });

    test('without a storage reset, it cannot reset, and reset throws '
        'UnsupportedError', () async {
      expect(bootstrap.supportsReset, isFalse);
      expect(bootstrap.countsTowardReset(StateError('x')), isFalse);
      await expectLater(bootstrap.reset(), throwsUnsupportedError);
    });

    test('with one, it supports reset and counts only what the reset '
        'answers', () {
      final withReset = WebPlatformBootstrap(
        storageReset: _FakeStorageReset(answering: (e) => e is FormatException),
      );

      expect(withReset.supportsReset, isTrue);
      expect(withReset.countsTowardReset(const FormatException()), isTrue);
      expect(withReset.countsTowardReset(StateError('x')), isFalse);
    });
  });

  // #793
  group('WebPlatformBootstrap.reset', () {
    test('releases the held server, then deletes', () async {
      final calls = <String>[];
      final container = _SpyContainer()..onDispose = () => calls.add('release');
      final storageReset = _FakeStorageReset(
        onDeleteAll: () async => calls.add('deleteAll'),
      );
      final bootstrap = WebPlatformBootstrap(
        serverScopeBuilder: () async => _FakeServerScope(container),
        storageReset: storageReset,
      );
      await bootstrap.initialize();

      await bootstrap.reset();

      expect(calls, ['release', 'deleteAll']);
      expect(container.disposeCalls, 1);
    });

    test('a delete that throws propagates, and leaves the bootstrap '
        'usable', () async {
      final bootstrap = WebPlatformBootstrap(
        serverScopeBuilder: () async => _FakeServerScope(_SpyContainer()),
        storageReset: _FakeStorageReset(
          onDeleteAll: () async => throw StateError('the delete failed'),
        ),
      );
      await bootstrap.initialize();

      await expectLater(bootstrap.reset(), throwsStateError);

      expect((await bootstrap.initialize()).hasServer, isTrue);
      await bootstrap.dispose();
    });

    test('after a blocked reset, initialize deletes again first, and '
        'fails the same way while the other tabs still hold on', () async {
      var builds = 0;
      var blocked = true;
      final storageReset = _FakeStorageReset(
        onDeleteAll: () async {
          if (blocked) throw const LocalDataInUseError();
        },
      );
      final bootstrap = WebPlatformBootstrap(
        serverScopeBuilder: () async {
          builds++;
          return _FakeServerScope(_SpyContainer());
        },
        storageReset: storageReset,
      );
      addTearDown(bootstrap.dispose);

      await expectLater(
        bootstrap.reset(),
        throwsA(isA<LocalDataInUseError>()),
      );
      // Pressing Retry with the tabs still open: an answer, not an open
      // that waits behind the queued delete.
      await expectLater(
        bootstrap.initialize(),
        throwsA(isA<LocalDataInUseError>()),
      );
      expect(builds, 0);
      expect(storageReset.deleteAllCalls, 2);

      blocked = false;
      expect((await bootstrap.initialize()).hasServer, isTrue);
      expect(storageReset.deleteAllCalls, 3);
      expect(builds, 1);

      // Once a delete went through, later attempts just open.
      await bootstrap.initialize();
      expect(storageReset.deleteAllCalls, 3);
      expect(builds, 2);
    });

    test('after dispose throws StateError, without deleting', () async {
      final storageReset = _FakeStorageReset();
      final bootstrap = WebPlatformBootstrap(storageReset: storageReset);
      await bootstrap.dispose();

      await expectLater(bootstrap.reset(), throwsStateError);
      expect(storageReset.deleteAllCalls, 0);
    });

    test('dispose waits for a reset in flight', () async {
      final deleting = Completer<void>();
      final bootstrap = WebPlatformBootstrap(
        storageReset: _FakeStorageReset(onDeleteAll: () => deleting.future),
      );

      final reset = bootstrap.reset();
      await pumpEventQueue();
      var disposed = false;
      final disposal = bootstrap.dispose().then((_) => disposed = true);
      await pumpEventQueue();
      expect(disposed, isFalse);

      deleting.complete();
      await reset;
      await disposal;
      expect(disposed, isTrue);
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
