import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:web_platform/web.dart';

/// Red-phase test for `registerWebRootModule` gaining its first
/// registration (issue #35): the resolved `BuildInfo`, read on web from
/// Flutter's generated `version.json`. Same injected-reader shape as the
/// native module.
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

    await registerWebRootModule(
      container,
      buildInfoReader: const _StubBuildInfoReader(info),
    );

    expect(container.get<BuildInfo>(), info);
  });
}
