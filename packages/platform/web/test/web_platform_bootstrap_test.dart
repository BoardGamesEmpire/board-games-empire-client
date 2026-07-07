import 'package:flutter_test/flutter_test.dart';
import 'package:web_platform/web.dart';

void main() {
  group('WebPlatformBootstrap', () {
    const bootstrap = WebPlatformBootstrap();

    test('a server is present by construction (the serving origin) and '
        'there is no orchestrator', () async {
      final result = await bootstrap.initialize();

      expect(result.hasServer, isTrue);
      expect(result.orchestrator, isNull);
    });

    test('never supports the destructive reset', () {
      expect(bootstrap.supportsReset, isFalse);
    });

    test('reset() throws UnsupportedError', () async {
      await expectLater(bootstrap.reset(), throwsUnsupportedError);
    });
  });
}
