import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dio_network/src/network/dio_factory.dart';

void main() {
  const factory = DefaultDioFactory();

  group('DefaultDioFactory.buildForServer', () {
    test('sets baseUrl from the supplied server URL', () {
      final dio = factory.buildForServer(baseUrl: 'https://api.example.com');
      expect(dio.options.baseUrl, 'https://api.example.com');
    });

    test('normalizes a trailing slash on the base URL', () {
      final dio = factory.buildForServer(baseUrl: 'https://api.example.com/');
      expect(dio.options.baseUrl, 'https://api.example.com');
    });

    test('configures standard timeouts and Accept header', () {
      final dio = factory.buildForServer(baseUrl: 'https://api.example.com');
      expect(dio.options.connectTimeout, const Duration(seconds: 10));
      expect(dio.options.receiveTimeout, const Duration(seconds: 10));
      expect(dio.options.headers['Accept'], 'application/json');
    });

    test('treats all status codes as non-throwing for manual handling', () {
      final dio = factory.buildForServer(baseUrl: 'https://api.example.com');
      expect(dio.options.validateStatus(500), isTrue);
      expect(dio.options.validateStatus(404), isTrue);
      expect(dio.options.validateStatus(200), isTrue);
    });

    test('adds none of the caller-supplied interceptors by default', () {
      // A fresh Dio carries an implicit ImplyContentTypeInterceptor, so we
      // assert against the interceptor types we control rather than emptiness.
      final dio = factory.buildForServer(baseUrl: 'https://api.example.com');
      expect(dio.interceptors.whereType<LogInterceptor>(), isEmpty);
    });

    test('attaches the supplied interceptors in order', () {
      final first = LogInterceptor();
      final second = LogInterceptor();
      final dio = factory.buildForServer(
        baseUrl: 'https://api.example.com',
        interceptors: [first, second],
      );
      expect(dio.interceptors, containsAllInOrder([first, second]));
    });
  });
}
