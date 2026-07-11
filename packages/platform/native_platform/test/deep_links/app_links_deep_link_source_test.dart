import 'package:flutter_test/flutter_test.dart';
import 'package:native_platform/native_platform.dart';

/// `AppLinksDeepLinkSource` — the adapter must forward the
/// (injected) plugin stream as-is, preserving order. The real
/// `AppLinks().uriLinkStream` needs a platform channel, so tests exercise
/// only the injection seam; the launch-link-included semantics are the
/// plugin's documented contract (app_links ^7.2.1).
void main() {
  group('AppLinksDeepLinkSource', () {
    test('forwards the injected uriLinkStream in order', () async {
      final first = Uri.parse('bge://server/s1/game/1');
      final second = Uri.parse('bge://server/s2/event/9');
      final source = AppLinksDeepLinkSource(
        uriLinkStream: Stream.fromIterable([first, second]),
      );

      final received = await source.uris.toList();

      expect(received, [first, second]);
    });
  });
}
