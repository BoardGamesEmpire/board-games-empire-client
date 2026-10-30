import 'package:interfaces/services.dart';

import 'browser_from_user_agent.dart';

/// [DeviceInfoReader] for the browser (#324): the OS the browser runs on, the
/// browser's engine, and the browser itself by name and major version. The
/// raw user agent is not reported; see [browserFromUserAgent].
///
/// The sources are `dart:ui_web`'s browser detection, which this library
/// cannot name: it is on the VM-compilable side of this package, and off the
/// web `dart:ui_web` has no `browser` at all. So the browser-only composition
/// root (`buildWebRootModule`) passes them in, each as the plain string it
/// reads — the user agent, `navigator.vendor`, and the `name` of the engine's
/// `BrowserEngine` and `OperatingSystem` values. Each is read inside [read],
/// not at construction.
///
/// The OS is mapped to `TargetPlatform.name`'s spelling, and an OS the engine
/// could not detect stays `unknown`. Flutter's own web platform mapping turns
/// that case into Android, which is what #324 was filed for. ChromeOS is
/// `unknown` too: its `navigator.platform` is `Linux …`, so the engine files
/// it under Linux, and only the user agent's `CrOS` tells the two apart.
///
/// The engine's `blink` is also what it falls back to when it cannot tell, so
/// it is reported only when the vendor confirms it (`Google Inc.`, which every
/// Chromium browser sends). Its `webkit` and `firefox` are only ever detected.
class WebDeviceInfoReader implements DeviceInfoReader {
  WebDeviceInfoReader({
    required this._userAgent,
    required this._vendor,
    required this._browserEngine,
    required this._operatingSystem,
  });

  final String Function() _userAgent;
  final String Function() _vendor;
  final String Function() _browserEngine;
  final String Function() _operatingSystem;

  @override
  Map<String, String> read() {
    final operatingSystem = _attempt(_operatingSystem);
    final browserEngine = _attempt(_browserEngine);
    final vendor = _attempt(_vendor);
    final userAgent = _attempt(_userAgent);
    final browser = userAgent == null ? null : browserFromUserAgent(userAgent);
    return {
      if (operatingSystem != null)
        'operatingSystem': _spelling(operatingSystem, userAgent: userAgent),
      'browserEngine': ?_confirmed(browserEngine, vendor: vendor),
      'browser': ?browser,
    };
  }

  /// `OperatingSystem.name` in `TargetPlatform.name`'s spelling; anything
  /// else, including a value added to the engine's enum later, is `unknown`.
  static String _spelling(String detected, {required String? userAgent}) =>
      switch (detected) {
        'iOs' => 'iOS',
        'macOs' => 'macOS',
        'linux' when userAgent?.contains('CrOS') ?? false => 'unknown',
        'android' || 'linux' || 'windows' => detected,
        _ => 'unknown',
      };

  /// [detected] when it is a detection rather than the engine's fallback.
  static String? _confirmed(String? detected, {required String? vendor}) =>
      switch (detected) {
        'blink' when vendor == 'Google Inc.' => detected,
        'webkit' || 'firefox' => detected,
        _ => null,
      };

  static String? _attempt(String Function() source) {
    try {
      return source();
    } on Object {
      return null;
    }
  }
}
