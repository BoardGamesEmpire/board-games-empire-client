import 'package:flutter_test/flutter_test.dart';
import 'package:web_network/web_network.dart';

/// The web factory's own options: the base URL it is given, normalised the
/// way the native factory normalises it, and the flag that opts every
/// request into sending the browser's credentials (#196).
void main() {
  group('WebDioFactory', () {
    test('strips one trailing slash from the base URL', () {
      final dio = const WebDioFactory().buildForServer(
        baseUrl: 'https://bge.example/',
      );

      expect(dio.options.baseUrl, 'https://bge.example');
    });

    test('leaves a base URL without a trailing slash as it is', () {
      final dio = const WebDioFactory().buildForServer(
        baseUrl: 'https://bge.example',
      );

      expect(dio.options.baseUrl, 'https://bge.example');
    });

    test('asks the browser to send credentials', () {
      final dio = const WebDioFactory().buildForServer(
        baseUrl: 'https://bge.example',
      );

      expect(dio.options.extra['withCredentials'], isTrue);
    });
  });
}
