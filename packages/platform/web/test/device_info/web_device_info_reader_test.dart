@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:web_platform/web.dart';

/// Pinned (#324): what a web feedback report says about the device. The
/// sources are injected because the real ones (`dart:ui_web`'s browser
/// detection) only exist in a browser; the browser-only composition root
/// supplies them.
void main() {
  const safariOnMac =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/18.1 Safari/605.1.15';

  WebDeviceInfoReader reader({
    String Function()? userAgent,
    String Function()? vendor,
    String Function()? browserEngine,
    String Function()? operatingSystem,
  }) => WebDeviceInfoReader(
    userAgent: userAgent ?? () => safariOnMac,
    vendor: vendor ?? () => 'Apple Computer, Inc.',
    browserEngine: browserEngine ?? () => 'webkit',
    operatingSystem: operatingSystem ?? () => 'macOs',
  );

  test('reads the OS, the browser engine and the browser', () {
    expect(reader().read(), {
      'operatingSystem': 'macOS',
      'browserEngine': 'webkit',
      'browser': 'Safari 18',
    });
  });

  const spellings = {
    'iOs': 'iOS',
    'android': 'android',
    'linux': 'linux',
    'windows': 'windows',
    'macOs': 'macOS',
    'unknown': 'unknown',
  };
  for (final MapEntry(key: detected, value: reported) in spellings.entries) {
    test('a detected $detected reads as $reported', () {
      expect(
        reader(operatingSystem: () => detected).read()['operatingSystem'],
        reported,
      );
    });
  }

  test('an OS the browser could not name reads as unknown, never as '
      'android', () {
    // The trap #324 was filed for: Flutter's own web platform mapping turns
    // an undetected OS into Android.
    expect(
      reader(operatingSystem: () => 'unknown').read()['operatingSystem'],
      'unknown',
    );
    expect(
      reader(operatingSystem: () => 'fuchsia').read()['operatingSystem'],
      'unknown',
    );
  });

  test('ChromeOS reads as unknown, not as the Linux the engine files it '
      'under', () {
    const chromebook =
        'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

    expect(
      reader(
        userAgent: () => chromebook,
        operatingSystem: () => 'linux',
      ).read()['operatingSystem'],
      'unknown',
    );
  });

  test('blink is reported when the vendor confirms it', () {
    final info = reader(
      vendor: () => 'Google Inc.',
      browserEngine: () => 'blink',
    ).read();

    expect(info['browserEngine'], 'blink');
  });

  test("the engine's fallback blink is left out, not reported as a "
      'reading', () {
    // The engine assumes blink for a vendor it does not recognise.
    for (final vendor in ['', 'Ladybird']) {
      final info = reader(
        vendor: () => vendor,
        browserEngine: () => 'blink',
      ).read();

      expect(info.containsKey('browserEngine'), isFalse, reason: vendor);
    }
  });

  test('a vendor that cannot be read leaves blink out', () {
    final info = reader(
      vendor: () => throw StateError('no navigator'),
      browserEngine: () => 'blink',
    ).read();

    expect(info.containsKey('browserEngine'), isFalse);
  });

  test('a user agent naming no known browser leaves the browser out and '
      'keeps the engine', () {
    final info = reader(userAgent: () => 'curl/8.4.0').read();

    expect(info.containsKey('browser'), isFalse);
    expect(info['browserEngine'], 'webkit');
  });

  test('a source that throws leaves its entry out and the rest in', () {
    final info = reader(
      userAgent: () => throw StateError('no navigator'),
      browserEngine: () => throw StateError('no engine'),
    ).read();

    expect(info, {'operatingSystem': 'macOS'});
  });

  test('an OS source that throws leaves the OS out', () {
    final info = reader(operatingSystem: () => throw StateError('no platform'))
        .read();

    expect(info, {'browserEngine': 'webkit', 'browser': 'Safari 18'});
  });
}
