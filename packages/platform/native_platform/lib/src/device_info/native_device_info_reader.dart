import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:interfaces/services.dart';

/// [DeviceInfoReader] for mobile and desktop (#324): the OS by its
/// [TargetPlatform] name and the version string `dart:io` reports for it.
///
/// Both come from `dart:io`'s host. [defaultTargetPlatform] would follow
/// `debugDefaultTargetPlatformOverride` (and reads Android under
/// `flutter test`), pairing one OS's name with another's version.
///
/// No plugin: [Platform.operatingSystemVersion] is all the version there is
/// here. Its form varies by OS — `Version 15.1 (Build 24B83)` on macOS, a
/// kernel build string on Linux — and on Android it is a build ID rather than
/// a version, so Android files it under `operatingSystemBuild` instead.
///
/// [platform] and [osVersion] are injectable for tests.
class NativeDeviceInfoReader implements DeviceInfoReader {
  NativeDeviceInfoReader({
    TargetPlatform? platform,
    String Function()? osVersion,
  }) : _platform = platform ?? _hostPlatform(),
       _osVersion = osVersion ?? _platformOsVersion;

  final TargetPlatform _platform;
  final String Function() _osVersion;

  static String _platformOsVersion() => Platform.operatingSystemVersion;

  static TargetPlatform _hostPlatform() => switch (Platform.operatingSystem) {
    'android' => TargetPlatform.android,
    'ios' => TargetPlatform.iOS,
    'macos' => TargetPlatform.macOS,
    'windows' => TargetPlatform.windows,
    'fuchsia' => TargetPlatform.fuchsia,
    _ => TargetPlatform.linux,
  };

  @override
  Map<String, String> read() {
    final versionKey = _platform == TargetPlatform.android
        ? 'operatingSystemBuild'
        : 'operatingSystemVersion';
    return {'operatingSystem': _platform.name, versionKey: ?_readVersion()};
  }

  /// The trimmed version, or null when it cannot be read or is blank.
  String? _readVersion() {
    try {
      final version = _osVersion().trim();
      return version.isEmpty ? null : version;
    } on Object {
      return null;
    }
  }
}
