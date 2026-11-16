import 'dart:async';

import 'package:build_info_platform/build_info_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The reader maps `package_info_plus`'s `PackageInfo` onto `BuildInfo`,
/// with the platform source injected for tests. That source is the Android
/// manifest or macOS bundle on native and Flutter's generated
/// `version.json` on web, and the mapping and the fallback are the same on
/// both. Its defining contract is that it **never throws into bootstrap**
/// and **never hangs**: a source that fails, or never answers, resolves to
/// `BuildInfo.unknown`, so the root-module registration can't fail or stall
/// the boot.
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
  );

  group('PackageInfoBuildInfoReader', () {
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
            throw StateError('the platform source is unavailable'),
      );

      await expectLater(reader.read(), completion(BuildInfo.unknown));
    });

    test('a source that never completes resolves to BuildInfo.unknown at '
        'the read timeout — a hung read degrades instead of stalling '
        'boot', () async {
      final reader = PackageInfoBuildInfoReader(
        packageInfoReader: () => Completer<PackageInfo>().future,
        readTimeout: const Duration(milliseconds: 20),
      );

      await expectLater(reader.read(), completion(BuildInfo.unknown));
    });
  });
}
