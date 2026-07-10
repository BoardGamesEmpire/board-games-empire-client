import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';

/// Tests for the native `createRootContainer` leg (issues #72, #35).
///
/// Contract pinned here:
///
/// - Each call returns a **freshly built, functional** root container —
///   fresh-per-call keeps hot restart clean and proves there is no
///   hidden global GetIt state behind the seam.
/// - Building the container performs the root module's registrations —
///   since #35, the defensive `BuildInfo` read. In the test VM the
///   platform source is unavailable, so the reader's fail-closed
///   contract registers [BuildInfo.unknown]; asserted below, proving the
///   degraded path end-to-end through the real composition (no stub —
///   `createRootContainer` deliberately has no module/reader injection
///   until #69 adds that seam for the dispose-partial guard).
/// - The key service is injected only to keep the default
///   `FlutterSecureStorage` composition out of the picture entirely —
///   `createRootContainer` itself never touches it.
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

    test('registers BuildInfo via the defensive read — BuildInfo.unknown '
        'when the platform source is unavailable (test VM)', () async {
      final container = await buildBootstrap().createRootContainer();
      addTearDown(container.dispose);

      expect(container.isRegistered<BuildInfo>(), isTrue);
      expect(container.get<BuildInfo>(), BuildInfo.unknown);
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

  group('NativePlatformBootstrap.createRootContainer — injectable module '
      'seam (#69)', () {
    test('an injected module replaces the default registrations', () async {
      final marker = _Marker();
      final bootstrap = NativePlatformBootstrap(
        keyService: _FakeKeyService(),
        rootModule: (container) async {
          container.registerSingleton<_Marker>(marker);
        },
      );

      final container = await bootstrap.createRootContainer();
      addTearDown(container.dispose);

      expect(container.get<_Marker>(), same(marker));
      expect(
        container.isRegistered<BuildInfo>(),
        isFalse,
        reason: 'the injected module ran instead of the default one',
      );
    });

    test('a throwing module rethrows AND the partially-built container '
        'is disposed first — no leaked partials (dispose-partial guard, '
        'deferred from #74)', () async {
      DependencyContainer? captured;
      final bootstrap = NativePlatformBootstrap(
        keyService: _FakeKeyService(),
        rootModule: (container) async {
          captured = container..registerSingleton<_Marker>(_Marker());
          throw StateError('module bug — contract violation');
        },
      );

      await expectLater(bootstrap.createRootContainer(), throwsStateError);

      expect(captured, isNotNull);
      // The partial container was disposed before the exception
      // propagated: the disposed guard rejects further use.
      expect(() => captured!.get<_Marker>(), throwsStateError);
    });
  });
}
