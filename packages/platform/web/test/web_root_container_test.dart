import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:web_platform/web.dart';

/// Tests for the web `createRootContainer` leg (issues #72, #35).
///
/// Same contract as the native leg: each call returns a freshly built,
/// functional root container with no shared global GetIt state, and
/// building the container performs the web root module's registrations —
/// since #35, the defensive `BuildInfo` read. In the test VM
/// `package_info_plus`'s platform source is unavailable, so the reader's
/// fail-closed contract registers [BuildInfo.unknown]; asserted below,
/// proving the degraded path end-to-end through the real composition.
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

    test('registers BuildInfo via the defensive read — BuildInfo.unknown '
        'when the platform source is unavailable (test VM)', () async {
      const bootstrap = WebPlatformBootstrap();
      final container = await bootstrap.createRootContainer();
      addTearDown(container.dispose);

      expect(container.isRegistered<BuildInfo>(), isTrue);
      expect(container.get<BuildInfo>(), BuildInfo.unknown);
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
