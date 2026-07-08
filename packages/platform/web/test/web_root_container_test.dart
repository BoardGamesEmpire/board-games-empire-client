import 'package:flutter_test/flutter_test.dart';
import 'package:web_platform/web.dart';

/// Red-phase tests for the web `createRootContainer` leg (issue #72).
///
/// Same contract as the native leg: each call returns a freshly built,
/// functional root container with no shared global GetIt state.
/// Registration content is owned by the web root module (near-empty in
/// the #72 shell; #35 populates it — the web client version read).
///
/// First test file in `web_platform` — CI's dynamic test discovery
/// (`find packages apps -type d -name test`) picks the package up
/// automatically; no workflow change needed.
class _Marker {}

void main() {
  group('WebPlatformBootstrap.createRootContainer', () {
    test('returns a functional container (register/get round trip)', () async {
      const bootstrap = WebPlatformBootstrap();
      final container = await bootstrap.createRootContainer();
      addTearDown(container.dispose);

      final marker = _Marker();
      container.registerSingleton<_Marker>(marker);

      expect(container.get<_Marker>(), same(marker));
    });

    test('each call returns a fresh, isolated container — no shared '
        'global GetIt state', () async {
      const bootstrap = WebPlatformBootstrap();
      final first = await bootstrap.createRootContainer();
      final second = await bootstrap.createRootContainer();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      first.registerSingleton<_Marker>(_Marker());

      expect(second.isRegistered<_Marker>(), isFalse);
    });
  });
}
