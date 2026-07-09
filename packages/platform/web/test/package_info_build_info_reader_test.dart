import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:web_platform/web.dart';

/// Red-phase tests for the web `BuildInfoReader` (issue #35).
///
/// Same contract as the native reader — on web, `package_info_plus` reads
/// Flutter's generated `version.json` under the hood, but the injectable
/// source seam and the `PackageInfo` → `BuildInfo` mapping are identical,
/// including the never-throw / `BuildInfo.unknown` fallback (which also
/// covers a missing or unreachable `version.json`).
void main() {
  PackageInfo packageInfo({
    String appName = 'Board Games Empire',
    String packageName = 'com.boardgamesempire.app',
    String version = '1.2.3',
    String buildNumber = '42',
  }) => PackageInfo(
    appName: appName,
    packageName: packageName,
    version: version,
    buildNumber: buildNumber,
    buildSignature: '',
  );

  group('PackageInfoBuildInfoReader (web)', () {
    test('is a BuildInfoReader', () {
      expect(PackageInfoBuildInfoReader(), isA<BuildInfoReader>());
    });

    test('maps the platform PackageInfo fields onto BuildInfo', () async {
      final reader = PackageInfoBuildInfoReader(
        packageInfoReader: () async => packageInfo(),
      );

      final info = await reader.read();

      expect(info.appName, 'Board Games Empire');
      expect(info.packageName, 'com.boardgamesempire.app');
      expect(info.version, '1.2.3');
      expect(info.buildNumber, '42');
    });

    test('resolves to BuildInfo.unknown when the source throws — never '
        'throws into bootstrap', () async {
      final reader = PackageInfoBuildInfoReader(
        packageInfoReader: () async =>
            throw StateError('version.json unavailable'),
      );

      await expectLater(reader.read(), completion(BuildInfo.unknown));
    });

    test('a source that never completes resolves to BuildInfo.unknown at '
        'the read timeout — a wedged version.json fetch degrades instead '
        'of stalling boot', () async {
      final reader = PackageInfoBuildInfoReader(
        packageInfoReader: () => Completer<PackageInfo>().future,
        readTimeout: const Duration(milliseconds: 20),
      );

      await expectLater(reader.read(), completion(BuildInfo.unknown));
    });
  });
}
