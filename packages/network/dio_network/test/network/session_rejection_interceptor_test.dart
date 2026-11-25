import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every request with [status] and a small JSON body.
class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.status);

  final int status;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{"hello":"world"}',
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

/// Fails every request in transport, with no response.
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(
    requestOptions: options,
    reason: 'down',
  );
}

void main() {
  late int rejections;

  setUp(() => rejections = 0);

  Dio buildDio(
    int status, {
    String baseUrl = 'https://h',
    String authBase = 'https://h/api/auth',
    bool acceptAll = true,
    void Function()? onRejected,
  }) {
    return Dio(
        BaseOptions(
          baseUrl: baseUrl,
          validateStatus: acceptAll ? (_) => true : null,
        ),
      )
      ..httpClientAdapter = _StatusAdapter(status)
      ..interceptors.add(
        SessionRejectionInterceptor(
          authBase: Uri.parse(authBase),
          onRejected: onRejected ?? () => rejections++,
        ),
      );
  }

  group('SessionRejectionInterceptor', () {
    test('a 401 from a data endpoint reports once', () async {
      await buildDio(401).get<dynamic>('/api/households');

      expect(rejections, 1);
    });

    test('a 401 under the auth base path does not report', () async {
      await buildDio(401).get<dynamic>('/api/auth/get-session');

      expect(rejections, 0);
    });

    test('a 401 at exactly the auth base path does not report', () async {
      await buildDio(401).get<dynamic>('/api/auth');

      expect(rejections, 0);
    });

    test('a trailing slash on the auth base changes nothing', () async {
      final dio = buildDio(401, authBase: 'https://h/api/auth/');

      await dio.get<dynamic>('/api/auth/get-session');
      await dio.get<dynamic>('/api/auth');
      expect(rejections, 0);

      await dio.get<dynamic>('/api/households');
      expect(rejections, 1);
    });

    test(
      'a path that only shares a prefix with the auth base reports',
      () async {
        final dio = buildDio(401);

        await dio.get<dynamic>('/api/authors');
        await dio.get<dynamic>('/api/auth-keys');

        expect(rejections, 2);
      },
    );

    test('a 401 from another origin reports even on the auth path', () async {
      final dio = buildDio(401);

      await dio.get<dynamic>('https://other.example/api/auth/get-session');
      await dio.get<dynamic>('http://h/api/auth/get-session');
      await dio.get<dynamic>('https://h:8443/api/auth/get-session');

      expect(rejections, 3);
    });

    test('a 401 matches the origin ignoring host case', () async {
      await buildDio(401).get<dynamic>('https://H/api/auth/get-session');

      expect(rejections, 0);
    });

    for (final status in [200, 403, 500]) {
      test('status $status does not report', () async {
        await buildDio(status).get<dynamic>('/api/households');

        expect(rejections, 0);
      });
    }

    test('a 401 delivered as a DioException reports', () async {
      final dio = buildDio(401, acceptAll: false);

      await expectLater(
        dio.get<dynamic>('/api/households'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            401,
          ),
        ),
      );

      expect(rejections, 1);
    });

    test('a DioException 401 under the auth base does not report', () async {
      final dio = buildDio(401, acceptAll: false);

      await expectLater(
        dio.get<dynamic>('/api/auth/get-session'),
        throwsA(isA<DioException>()),
      );

      expect(rejections, 0);
    });

    test('a DioException without a response does not report', () async {
      final dio = buildDio(401)..httpClientAdapter = _ThrowingAdapter();

      await expectLater(
        dio.get<dynamic>('/api/households'),
        throwsA(isA<DioException>()),
      );

      expect(rejections, 0);
    });

    test('the response passes through unchanged', () async {
      final response = await buildDio(401).get<dynamic>('/api/households');

      expect(response.statusCode, 401);
      expect(response.data, {'hello': 'world'});
    });

    test('a thrown onRejected does not break the request', () async {
      final dio = buildDio(401, onRejected: () => throw StateError('boom'));

      final response = await dio.get<dynamic>('/api/households');

      expect(response.statusCode, 401);
      expect(response.data, {'hello': 'world'});
    });

    test('a thrown onRejected does not mask a DioException', () async {
      final dio = buildDio(
        401,
        acceptAll: false,
        onRejected: () => throw StateError('boom'),
      );

      await expectLater(
        dio.get<dynamic>('/api/households'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            401,
          ),
        ),
      );
    });

    test('a server under a path prefix', () async {
      final dio = buildDio(
        401,
        baseUrl: 'https://h/bge/',
        authBase: 'https://h/bge/api/auth',
      );

      await dio.get<dynamic>('api/auth/x');
      expect(rejections, 0);

      await dio.get<dynamic>('api/x');
      expect(rejections, 1);
    });
  });
}
