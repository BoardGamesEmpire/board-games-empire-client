import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';
import 'package:observability/observability.dart';

/// Tests for `registerNativeRootModule`'s registrations: the resolved
/// `BuildInfo` (#35), the durable `FeedbackSink` (#69), and the lazy
/// device-global `ConnectivityService` (#9).
///
/// The module takes an injectable `BuildInfoReader` (defaulting to the
/// concrete `PackageInfoBuildInfoReader`) so this test drives it with a
/// stub instead of the real platform read. The reader is awaited and its
/// resolved value registered as a singleton — the manual analog of
/// injectable's `@preResolve` (#61). The connectivity factory seam is
/// injected likewise: the production `ConnectivityPlusService`
/// constructor touches the connectivity plugin, unavailable in the test
/// VM.
class _StubBuildInfoReader implements BuildInfoReader {
  const _StubBuildInfoReader(this._info);
  final BuildInfo _info;

  @override
  Future<BuildInfo> read() async => _info;
}

class _FakeConnectivityService implements ConnectivityService, Disposable {
  bool disposed = false;

  @override
  ConnectivityState get current => ConnectivityState.online;

  @override
  Stream<ConnectivityState> watch() => Stream.value(ConnectivityState.online);

  @override
  Future<void> onDispose() async => disposed = true;
}

const _info = BuildInfo(
  version: '1.2.3',
  buildNumber: '42',
  appName: 'Board Games Empire',
  packageName: 'com.boardgamesempire.app',
);

void main() {
  test('registers the resolved BuildInfo into the container', () async {
    final container = DependencyContainerImpl();
    addTearDown(container.dispose);

    await registerNativeRootModule(
      container,
      buildInfoReader: const _StubBuildInfoReader(_info),
    );

    expect(container.get<BuildInfo>(), _info);
  });

  test('registers the durable FeedbackSink (#69) — lazily, no plugin '
      'call at registration', () async {
    final container = DependencyContainerImpl();
    addTearDown(container.dispose);

    await registerNativeRootModule(
      container,
      buildInfoReader: const _StubBuildInfoReader(_info),
    );

    // Registration succeeds in the plugin-less test VM because
    // FileFeedbackSink resolves its directory lazily at first persist.
    expect(container.isRegistered<FeedbackSink>(), isTrue);
    expect(container.get<FeedbackSink>(), isA<FileFeedbackSink>());
  });

  group('ConnectivityService registration (#9)', () {
    test('registers lazily — no construction at registration, singleton '
        'on resolution', () async {
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);
      var constructions = 0;

      await registerNativeRootModule(
        container,
        buildInfoReader: const _StubBuildInfoReader(_info),
        connectivityFactory: () {
          constructions++;
          return _FakeConnectivityService();
        },
      );

      expect(container.isRegistered<ConnectivityService>(), isTrue);
      expect(
        constructions,
        0,
        reason:
            'the plugin-touching constructor must not run at '
            'registration (defensive-module contract)',
      );

      final first = container.get<ConnectivityService>();
      final second = container.get<ConnectivityService>();

      expect(constructions, 1);
      expect(second, same(first));
    });

    test('container dispose drives Disposable.onDispose on the resolved '
        'service', () async {
      final container = DependencyContainerImpl();
      final service = _FakeConnectivityService();

      await registerNativeRootModule(
        container,
        buildInfoReader: const _StubBuildInfoReader(_info),
        connectivityFactory: () => service,
      );

      container.get<ConnectivityService>();
      await container.dispose();

      expect(service.disposed, isTrue);
    });

    test('an unresolved lazy registration is not constructed just to be '
        'disposed', () async {
      final container = DependencyContainerImpl();
      var constructions = 0;

      await registerNativeRootModule(
        container,
        buildInfoReader: const _StubBuildInfoReader(_info),
        connectivityFactory: () {
          constructions++;
          return _FakeConnectivityService();
        },
      );

      await container.dispose();

      expect(constructions, 0);
    });
  });
}
