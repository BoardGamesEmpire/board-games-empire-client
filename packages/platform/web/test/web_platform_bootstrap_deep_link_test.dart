import 'package:flutter_test/flutter_test.dart';
import 'package:web_platform/web.dart';

/// #10: web has no out-of-band deep-link channel — the browser URL *is*
/// the link and the path URL strategy hands it to `go_router` directly.
/// This pins the null contract so a future refactor can't silently start
/// constructing a source (and dragging native plugin code) on web.
void main() {
  group('WebPlatformBootstrap.createDeepLinkSource', () {
    test('returns null — no out-of-band channel on web', () {
      const bootstrap = WebPlatformBootstrap();

      expect(bootstrap.createDeepLinkSource(), isNull);
    });
  });
}
