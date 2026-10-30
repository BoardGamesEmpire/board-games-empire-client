/// The browser [userAgent] names, as `'<Name> <major>'` (`'Firefox 131'`), or
/// null when it names none this recognises (#324).
///
/// Only the name and major version leave the device: a full user agent is a
/// fingerprint, and the minor versions add nothing a triager acts on.
///
/// First match wins, and the order is the point. Edge, Opera and Samsung
/// Internet are Chromium underneath and carry `Chrome/` in their user agents,
/// and nearly everything carries `Safari/`, so each is tried before the
/// browser it is built on.
///
/// A browser that adds a token of its own but is not listed here (Yandex,
/// DuckDuckGo, an Android WebView) names no browser rather than the one it is
/// built on. One that adds none — Brave, and most iOS browsers — sends the
/// user agent of the browser underneath, and is reported as that: the user
/// agent carries nothing else to go on.
String? browserFromUserAgent(String userAgent) {
  if (_unlisted.hasMatch(userAgent)) return null;
  for (final (pattern, name) in _browsers) {
    if (pattern.firstMatch(userAgent) case final match?) {
      return '$name ${match.group(1)}';
    }
  }
  return null;
}

/// Tokens of browsers built on one listed below, which would otherwise be
/// reported as it. `; wv)` marks an Android WebView.
final _unlisted = RegExp(r'YaBrowser/|Vivaldi/|DuckDuckGo/|UCBrowser/|; wv\)');

final _browsers = <(RegExp, String)>[
  // `Edge/` is EdgeHTML-era Edge, which also carried `Chrome/`.
  (RegExp(r'Edg(?:e|A|iOS)?/(\d+)'), 'Edge'),
  // `OPT/` is Opera on iOS, which carries `Safari/` and `Version/`.
  (RegExp(r'(?:OPR|OPT)/(\d+)'), 'Opera'),
  (RegExp(r'SamsungBrowser/(\d+)'), 'Samsung Internet'),
  (RegExp(r'(?:Firefox|FxiOS)/(\d+)'), 'Firefox'),
  (RegExp(r'(?:CriOS|Chrome)/(\d+)'), 'Chrome'),
  // Safari carries its own version in `Version/`; its `Safari/` token is the
  // WebKit build, which every WebKit and Blink browser above also sends.
  (RegExp(r'Version/(\d+).*Safari/'), 'Safari'),
];
