import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';
import 'package:observability/observability.dart';

/// Red-phase test for `registerNativeRootModule` gaining its first
/// registration (issue #35): the resolved `BuildInfo`.
///
/// The module takes an injectable `BuildInfoReader` (defaulting to the
/// concrete `PackageInfoBuildInfoReader`) so this test drives it with a
/// stub instead of the real platform read. The reader is awaited and its
/// resolved value registered as a singleton — the manual analog of
/// injectable's `@preResolve` (#61).
class _StubBuildInfoReader implements BuildInfoReader {
  const _StubBuildInfoReader(this._info);
  final BuildInfo _info;

  @override
  Future<BuildInfo> read() async => _info;
}

void main() {
  test('registers the resolved BuildInfo into the container', () async {
    final container = DependencyContainerImpl();
    addTearDown(container.dispose);
    const info = BuildInfo(
      version: '1.2.3',
      buildNumber: '42',
      appName: 'Board Games Empire',
      packageName: 'com.boardgamesempire.app',
    );

    await registerNativeRootModule(
      container,
      buildInfoReader: const _StubBuildInfoReader(info),
    );

    expect(container.get<BuildInfo>(), info);
  });

  test('registers the durable FeedbackSink (#69) — lazily, no plugin '
      'call at registration', () async {
    final container = DependencyContainerImpl();
    addTearDown(container.dispose);

    await registerNativeRootModule(
      container,
      buildInfoReader: const _StubBuildInfoReader(
        BuildInfo(
          version: '1.2.3',
          buildNumber: '42',
          appName: 'Board Games Empire',
          packageName: 'com.boardgamesempire.app',
        ),
      ),
    );

    // Registration succeeds in the plugin-less test VM because
    // FileFeedbackSink resolves its directory lazily at first persist.
    expect(container.isRegistered<FeedbackSink>(), isTrue);
    expect(container.get<FeedbackSink>(), isA<FileFeedbackSink>());
  });
}
