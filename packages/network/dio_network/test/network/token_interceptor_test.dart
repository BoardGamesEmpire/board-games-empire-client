import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:dio_network/src/auth/token_storage_service.dart';
import 'package:dio_network/src/network/token_interceptor.dart';

class _MockTokenStorage extends Mock implements TokenStorageService {}

/// Captures the outgoing [RequestOptions] without hitting the network.
class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? captured;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured = options;
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  late _MockTokenStorage storage;
  late _CapturingAdapter adapter;
  late Dio dio;

  StoredToken validToken() => StoredToken(
    token: 'tok-123',
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );

  StoredToken expiredToken() => StoredToken(
    token: 'tok-old',
    expiresAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
  );

  setUp(() {
    storage = _MockTokenStorage();
    adapter = _CapturingAdapter();
    dio =
        Dio(
            BaseOptions(
              baseUrl: 'https://api.example.com',
              validateStatus: (_) => true,
            ),
          )
          ..httpClientAdapter = adapter
          ..interceptors.add(TokenInterceptor(tokenStorage: storage));
  });

  group('TokenInterceptor', () {
    test(
      'attaches bearer token by default when a valid token exists',
      () async {
        when(() => storage.retrieve()).thenAnswer((_) async => validToken());

        await dio.get<dynamic>('/protected');

        expect(adapter.captured?.headers['Authorization'], 'Bearer tok-123');
      },
    );

    test('omits token when the request opts out via Options.extra', () async {
      when(() => storage.retrieve()).thenAnswer((_) async => validToken());

      await dio.get<dynamic>(
        '/public',
        options: Options(extra: {TokenInterceptor.skipAuthKey: true}),
      );

      expect(adapter.captured?.headers.containsKey('Authorization'), isFalse);
      // The opt-out should short-circuit before touching storage.
      verifyNever(() => storage.retrieve());
    });

    test('omits token when none is stored', () async {
      when(() => storage.retrieve()).thenAnswer((_) async => null);

      await dio.get<dynamic>('/protected');

      expect(adapter.captured?.headers.containsKey('Authorization'), isFalse);
    });

    test('omits token when the stored token is expired', () async {
      when(() => storage.retrieve()).thenAnswer((_) async => expiredToken());

      await dio.get<dynamic>('/protected');

      expect(adapter.captured?.headers.containsKey('Authorization'), isFalse);
    });
  });
}
