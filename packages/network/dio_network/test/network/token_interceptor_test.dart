import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:dio_network/src/auth/token_storage_service.dart';
import 'package:dio_network/src/network/token_interceptor.dart';

class _MockTokenStorage extends Mock implements TokenStorageService {}

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

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

  // Closes the original PR #99 gap: the interceptor authenticated purely off
  // TokenStorageService.retrieve(), so a token surviving a failed clear() kept
  // being attached after sign-out. With the latch inside the shared store, the
  // interceptor stops attaching it the moment clear() is called — even when the
  // persisted delete throws and the token physically survives on disk.
  group('TokenInterceptor honors the shared sign-out latch (PR #99)', () {
    late _MockSecureStorage secure;
    late TokenStorageService realStorage;
    late _CapturingAdapter latchAdapter;
    late Dio latchDio;

    const validPayload =
        '{"token":"survivor","expires_at":"2099-01-01T00:00:00.000Z"}';

    setUp(() {
      secure = _MockSecureStorage();
      realStorage = TokenStorageService(serverId: 'server-1', storage: secure);
      latchAdapter = _CapturingAdapter();
      latchDio =
          Dio(
              BaseOptions(
                baseUrl: 'https://api.example.com',
                validateStatus: (_) => true,
              ),
            )
            ..httpClientAdapter = latchAdapter
            ..interceptors.add(TokenInterceptor(tokenStorage: realStorage));

      when(
        () => secure.read(key: any(named: 'key')),
      ).thenAnswer((_) async => validPayload);
    });

    test('stops attaching a surviving token after a failed clear', () async {
      // The persisted delete fails, so the token physically survives on disk.
      when(
        () => secure.delete(key: any(named: 'key')),
      ).thenThrow(StateError('keychain unavailable'));

      // Sanity: before sign-out the interceptor attaches the bearer token.
      await latchDio.get<dynamic>('/protected');
      expect(latchAdapter.captured?.headers['Authorization'], 'Bearer survivor');

      // Sign-out clears the store; the delete throws but the latch is set.
      await expectLater(realStorage.clear(), throwsA(isA<StateError>()));

      // Even though the token still reads from the keychain, the latched store
      // reports none — so no Authorization header is attached.
      latchAdapter.captured = null;
      await latchDio.get<dynamic>('/protected');
      expect(
        latchAdapter.captured?.headers.containsKey('Authorization'),
        isFalse,
      );
    });
  });
}
