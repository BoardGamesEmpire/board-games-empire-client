import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:native_platform/native_platform.dart';

/// Red-phase tests for the native `createRootContainer` leg (issue #72).
///
/// Contract pinned here:
///
/// - Each call returns a **freshly built, functional** root container —
///   fresh-per-call keeps hot restart clean and proves there is no
///   hidden global GetIt state behind the seam.
/// - Building the container touches **no platform plugins**: the key
///   service is injected here only to keep the default
///   `FlutterSecureStorage` composition out of the picture entirely —
///   `createRootContainer` itself must never need it.
/// - Registration content is owned by the per-platform root module
///   (near-empty in the #72 shell; #35/#69 populate it).
class _FakeKeyService implements EncryptionKeyService {
  @override
  Future<String> getOrCreateServerKey(String serverId) async => 'a' * 64;

  @override
  Future<String> getOrCreateMetaKey() async => 'b' * 64;

  @override
  Future<void> deleteServerKey(String serverId) async {}

  @override
  Future<void> deleteMetaKey() async {}
}

class _Marker {}

void main() {
  NativePlatformBootstrap buildBootstrap() =>
      NativePlatformBootstrap(keyService: _FakeKeyService());

  group('NativePlatformBootstrap.createRootContainer', () {
    test('returns a functional container (register/get round trip)', () async {
      final container = await buildBootstrap().createRootContainer();
      addTearDown(container.dispose);

      final marker = _Marker();
      container.registerSingleton<_Marker>(marker);

      expect(container.get<_Marker>(), same(marker));
    });

    test('each call returns a fresh, isolated container — hot-restart '
        'friendly, no shared global GetIt state', () async {
      final bootstrap = buildBootstrap();
      final first = await bootstrap.createRootContainer();
      final second = await bootstrap.createRootContainer();
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      first.registerSingleton<_Marker>(_Marker());

      expect(second.isRegistered<_Marker>(), isFalse);
    });
  });
}
