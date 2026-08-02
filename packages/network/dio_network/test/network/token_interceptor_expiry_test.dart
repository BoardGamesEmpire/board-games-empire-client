import 'package:di/di.dart' show LocalClockService;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:dio_network/src/auth/token_storage_service.dart';
import 'package:dio_network/src/network/token_interceptor.dart';

class MockTokenStorage extends Mock implements TokenStorageService {}

/// Captures whether the interceptor let the request through and with what
/// headers, without needing a real Dio.
class _CapturingHandler extends RequestInterceptorHandler {
  RequestOptions? passed;

  @override
  void next(RequestOptions requestOptions) => passed = requestOptions;
}

/// #98: the stored expiry became nullable when the client stopped
/// fabricating one at sign-in, which changes the interceptor's gate from
/// "attach unless expired" to "attach unless KNOWN expired".
void main() {
  late MockTokenStorage storage;

  final persistedAt = DateTime.utc(2026, 1, 1);
  final now = DateTime.utc(2026, 1, 2);

  TokenInterceptor build({DateTime? clockNow}) => TokenInterceptor(
    tokenStorage: storage,
    clock: LocalClockService(() => clockNow ?? now),
  );

  Future<RequestOptions> run(
    TokenInterceptor interceptor, {
    Map<String, dynamic>? extra,
  }) async {
    final handler = _CapturingHandler();
    await interceptor.onRequest(
      RequestOptions(path: '/anything', extra: extra ?? {}),
      handler,
    );
    return handler.passed!;
  }

  setUp(() {
    storage = MockTokenStorage();
  });

  void stub(StoredSession? session) =>
      when(() => storage.retrieve()).thenAnswer((_) async => session);

  test('attaches the token when the expiry is UNKNOWN — otherwise the very '
      'reconcile call that confirms it would go out unauthenticated', () async {
    stub(StoredSession(token: 'tok-abc', persistedAt: persistedAt));

    final options = await run(build());

    expect(options.headers['Authorization'], 'Bearer tok-abc');
  });

  test(
    'attaches the token when the confirmed expiry is in the future',
    () async {
      stub(
        StoredSession(
          token: 'tok-abc',
          persistedAt: persistedAt,
          expiresAt: DateTime.utc(2026, 1, 8),
        ),
      );

      final options = await run(build());

      expect(options.headers['Authorization'], 'Bearer tok-abc');
    },
  );

  test('omits the token once the confirmed expiry has passed', () async {
    stub(
      StoredSession(
        token: 'tok-abc',
        persistedAt: persistedAt,
        expiresAt: DateTime.utc(2026, 1, 8),
      ),
    );

    final options = await run(build(clockNow: DateTime.utc(2026, 2, 1)));

    expect(options.headers.containsKey('Authorization'), isFalse);
  });

  test('gates on the injected per-server clock, not the device wall clock '
      '— a skewed device must not discard a live token', () async {
    stub(
      StoredSession(
        token: 'tok-abc',
        persistedAt: persistedAt,
        expiresAt: DateTime.utc(2026, 1, 8),
      ),
    );

    // A device whose clock has run far ahead would call this dead; the
    // corrected clock knows better.
    final skewCorrected = await run(build(clockNow: DateTime.utc(2026, 1, 3)));
    expect(skewCorrected.headers['Authorization'], 'Bearer tok-abc');
  });

  test('omits the token when nothing is stored', () async {
    stub(null);

    final options = await run(build());

    expect(options.headers.containsKey('Authorization'), isFalse);
  });

  test('honours the per-request opt-out without touching storage', () async {
    final options = await run(
      build(),
      extra: {TokenInterceptor.skipAuthKey: true},
    );

    expect(options.headers.containsKey('Authorization'), isFalse);
    verifyNever(() => storage.retrieve());
  });
}
