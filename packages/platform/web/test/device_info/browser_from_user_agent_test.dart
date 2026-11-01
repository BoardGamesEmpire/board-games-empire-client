@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:web_platform/src/device_info/browser_from_user_agent.dart';

/// Pinned (#324): the browser a feedback report names, read from the user
/// agent as `'<Name> <major>'`. Chromium-based browsers carry `Chrome/` in
/// their UA too, so each is matched before Chrome; a UA nothing here
/// recognises names no browser rather than a guess.
void main() {
  const named = <String, ({String userAgent, String browser})>{
    'desktop Edge': (
      userAgent:
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 '
          'Edg/130.0.0.0',
      browser: 'Edge 130',
    ),
    'Android Edge': (
      userAgent:
          'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36 '
          'EdgA/130.0.0.0',
      browser: 'Edge 130',
    ),
    'iOS Edge': (
      userAgent:
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
          'EdgiOS/130.0.2849.80 Mobile/15E148 Safari/605.1.15',
      browser: 'Edge 130',
    ),
    'EdgeHTML-era Edge': (
      userAgent:
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/70.0.3538.102 Safari/537.36 '
          'Edge/18.19045',
      browser: 'Edge 18',
    ),
    'iOS Opera': (
      userAgent:
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 '
          'Mobile/15E148 Safari/604.1 OPT/5.0.6',
      browser: 'Opera 5',
    ),
    'Opera': (
      userAgent:
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 '
          'OPR/114.0.0.0',
      browser: 'Opera 114',
    ),
    'Samsung Internet': (
      userAgent:
          'Mozilla/5.0 (Linux; Android 14; SAMSUNG SM-S918B) '
          'AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/26.0 '
          'Chrome/122.0.0.0 Mobile Safari/537.36',
      browser: 'Samsung Internet 26',
    ),
    'desktop Firefox': (
      userAgent:
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:131.0) '
          'Gecko/20100101 Firefox/131.0',
      browser: 'Firefox 131',
    ),
    'iOS Firefox': (
      userAgent:
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/131.0 '
          'Mobile/15E148 Safari/605.1.15',
      browser: 'Firefox 131',
    ),
    'desktop Chrome': (
      userAgent:
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 '
          'Safari/537.36',
      browser: 'Chrome 130',
    ),
    'iOS Chrome': (
      userAgent:
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/130.0.6723.90 '
          'Mobile/15E148 Safari/604.1',
      browser: 'Chrome 130',
    ),
    'macOS Safari': (
      userAgent:
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 '
          'Safari/605.1.15',
      browser: 'Safari 18',
    ),
    'iOS Safari': (
      userAgent:
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 '
          'Mobile/15E148 Safari/604.1',
      browser: 'Safari 18',
    ),
  };

  for (final MapEntry(key: label, value: (:userAgent, :browser))
      in named.entries) {
    test('$label reads as $browser', () {
      expect(browserFromUserAgent(userAgent), browser);
    });
  }

  const unlisted = <String, String>{
    'Yandex':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/128.0.0.0 YaBrowser/24.10.0.0 '
        'Safari/537.36',
    'Vivaldi on Android':
        'Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36 '
        'Vivaldi/7.0.3495.18',
    'iOS DuckDuckGo':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 '
        'Mobile/15E148 DuckDuckGo/7 Safari/605.1.15',
    'UC Browser':
        'Mozilla/5.0 (Linux; U; Android 10; en-US; K) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Version/4.0 Chrome/100.0.4896.58 '
        'UCBrowser/13.6.0.1315 Mobile Safari/537.36',
    'Android WebView':
        'Mozilla/5.0 (Linux; Android 14; Pixel 8; wv) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Version/4.0 Chrome/130.0.6723.86 Mobile '
        'Safari/537.36',
  };
  for (final MapEntry(key: label, value: userAgent) in unlisted.entries) {
    test('$label reads as none, not as the browser it is built on', () {
      expect(browserFromUserAgent(userAgent), isNull);
    });
  }

  test('a user agent naming no known browser reads as none', () {
    expect(browserFromUserAgent('curl/8.4.0'), isNull);
  });

  test('an empty user agent reads as none', () {
    expect(browserFromUserAgent(''), isNull);
  });
}
