import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
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

void main() {
  group('WebPlatformBootstrap', () {
    const bootstrap = WebPlatformBootstrap();

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
}
