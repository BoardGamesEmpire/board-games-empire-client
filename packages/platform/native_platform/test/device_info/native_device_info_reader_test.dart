import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_platform/native_platform.dart';

/// Pinned (#324): what a native feedback report says about the device — the
/// OS by its `TargetPlatform` name and the version string `dart:io` reports.
/// Android reports a build ID there rather than a version, so it goes under
/// its own key. A version that cannot be read is left out, never guessed.
void main() {
  test('Android reports its build ID as the OS build', () {
    final reader = NativeDeviceInfoReader(
      platform: TargetPlatform.android,
      osVersion: () => 'TP1A.220624.014',
    );

    expect(reader.read(), {
      'operatingSystem': 'android',
      'operatingSystemBuild': 'TP1A.220624.014',
    });
  });

  test('macOS reports the OS version', () {
    final reader = NativeDeviceInfoReader(
      platform: TargetPlatform.macOS,
      osVersion: () => 'Version 15.1 (Build 24B83)',
    );

    expect(reader.read(), {
      'operatingSystem': 'macOS',
      'operatingSystemVersion': 'Version 15.1 (Build 24B83)',
    });
  });

  test('a version read that throws leaves the version out', () {
    final reader = NativeDeviceInfoReader(
      platform: TargetPlatform.macOS,
      osVersion: () => throw const FormatException('no version'),
    );

    expect(reader.read(), {'operatingSystem': 'macOS'});
  });

  test('an empty version leaves the version out', () {
    for (final empty in ['', '   ']) {
      final reader = NativeDeviceInfoReader(
        platform: TargetPlatform.windows,
        osVersion: () => empty,
      );

      expect(reader.read(), {'operatingSystem': 'windows'}, reason: '"$empty"');
    }
  });

  test('defaults to the host dart:io runs on, not the target platform '
      'override', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final host = switch (Platform.operatingSystem) {
      'ios' => 'iOS',
      'macos' => 'macOS',
      final other => other,
    };
    expect(NativeDeviceInfoReader().read()['operatingSystem'], host);
  });
}
