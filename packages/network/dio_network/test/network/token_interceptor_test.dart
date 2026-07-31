import 'dart:async';
import 'dart:typed_data';

import 'package:di/di.dart' show LocalClockService;
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

  StoredSession validToken() => StoredSession(
    token: 'tok-123',
    persistedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
    expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );

  StoredSession expiredToken() => StoredSession(
    token: 'tok-old',
    persistedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
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

  // #98: the persisted expiry became nullable when the client stopped
  // fabricating one at sign-in, so the gate is now "attach unless KNOWN
  // expired" rather than "attach unless expired".
  group('TokenInterceptor and an unconfirmed expiry (#98)', () {
    test(
      'attaches the token when the expiry is UNKNOWN — otherwise the '
      'reconcile call that confirms it would go out unauthenticated',
      () async {
        when(() => storage.retrieve()).thenAnswer(
          (_) async => StoredSession(
            token: 'tok-fresh',
            persistedAt: DateTime.now().toUtc(),
          ),
        );

        await dio.get<dynamic>('/protected');

        expect(adapter.captured?.headers['Authorization'], 'Bearer tok-fresh');
      },
    );

    test('gates on the injected per-server clock rather than the device wall '
        'clock, so a skewed device does not discard a live token', () async {
      final correctedAdapter = _CapturingAdapter();
      final correctedDio =
          Dio(
              BaseOptions(
                baseUrl: 'https://api.example.com',
                validateStatus: (_) => true,
              ),
            )
            ..httpClientAdapter = correctedAdapter
            ..interceptors.add(
              TokenInterceptor(
                tokenStorage: storage,
                // Server-corrected time places us inside the session window
                // even though the expiry is in the device's past.
                clock: LocalClockService(() => DateTime.utc(2026, 1, 2)),
              ),
            );

      when(() => storage.retrieve()).thenAnswer(
        (_) async => StoredSession(
          token: 'tok-live',
          persistedAt: DateTime.utc(2026),
          expiresAt: DateTime.utc(2026, 1, 8),
        ),
      );

      await correctedDio.get<dynamic>('/protected');

      expect(
        correctedAdapter.captured?.headers['Authorization'],
        'Bearer tok-live',
      );
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
        '{"v":2,"token":"survivor","expires_at":"2099-01-01T00:00:00.000Z",'
        '"persisted_at":"2026-01-01T00:00:00.000Z"}';

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
      expect(
        latchAdapter.captured?.headers['Authorization'],
        'Bearer survivor',
      );

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
