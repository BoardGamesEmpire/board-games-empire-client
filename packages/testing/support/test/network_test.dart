import 'package:bge_test_support/network.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cannedDio', () {
    test('replays the canned body and status through a real Dio', () async {
      final res = await cannedDio(
        body: '{"ok":true}',
        statusCode: 200,
      ).get<Map<String, dynamic>>('/anything');

      expect(res.statusCode, 200);
      expect(res.data, {'ok': true});
    });

    test(
      'permissiveStatus: true hands a non-2xx back instead of throwing',
      () async {
        final res = await cannedDio(
          body: '{}',
          statusCode: 500,
        ).get<Map<String, dynamic>>('/anything');

        expect(res.statusCode, 500);
      },
    );

    test('permissiveStatus: false lets Dio throw badResponse WITH the '
        'response attached', () async {
      await expectLater(
        cannedDio(
          body: '{}',
          statusCode: 404,
          permissiveStatus: false,
        ).get<Map<String, dynamic>>('/anything'),
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.badResponse)
              .having((e) => e.response?.statusCode, 'status', 404),
        ),
      );
    });

    test(
      "Dio's own cast runs — the reason this exists rather than a MockDio",
      () async {
        // A 2xx whose body is not a JSON object must fail inside the call, not
        // reach the caller as a typed value.
        await expectLater(
          cannedDio(
            body: '<html>portal</html>',
            statusCode: 200,
          ).get<Map<String, dynamic>>('/anything'),
          throwsA(isA<DioException>()),
        );
      },
    );
  });

  group('routingDio', () {
    test('answers per path suffix', () async {
      final dio = routingDio({
        '/a': ('{"which":"a"}', 200),
        '/b': ('{"which":"b"}', 201),
      });

      final a = await dio.get<Map<String, dynamic>>('/x/a');
      final b = await dio.get<Map<String, dynamic>>('/y/b');

      expect(a.data, {'which': 'a'});
      expect(b.statusCode, 201);
    });

    test('throws StateError for a path it was given no answer for', () async {
      await expectLater(
        routingDio({'/a': ('{}', 200)}).get<Map<String, dynamic>>('/nope'),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'error',
            isA<StateError>(),
          ),
        ),
      );
    });

    test('permissiveStatus defaults to true, matching cannedDio — the two '
        'copies this replaced disagreed here (#354 D2)', () async {
      final res = await routingDio({
        '/a': ('{}', 409),
      }).get<Map<String, dynamic>>('/a');

      expect(res.statusCode, 409);
    });

    test('rejects routes where one suffix is a suffix of another, rather '
        'than letting declaration order decide silently', () {
      expect(
        () => routingDio({
          'session': ('{}', 200),
          '/api/get-session': ('{}', 201),
        }),
        throwsA(isA<AssertionError>()),
      );
    });

    test('near-miss keys are NOT ambiguous: /get-session does not end with '
        '/session', () {
      expect(
        () => routingDio({
          '/session': ('{}', 200),
          '/get-session': ('{}', 201),
        }),
        returnsNormally,
      );
    });

    test('permissiveStatus: false restores Dio throwing on non-2xx', () async {
      await expectLater(
        routingDio(
          {'/a': ('{}', 409)},
          permissiveStatus: false,
        ).get<Map<String, dynamic>>('/a'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            409,
          ),
        ),
      );
    });
  });

  group('unreachableDio / FailingAdapter', () {
    test('fails with the given type and NO response attached', () async {
      await expectLater(
        unreachableDio(DioExceptionType.connectionError)
            .get<Map<String, dynamic>>('/anything'),
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.connectionError)
              .having((e) => e.response, 'response', isNull),
        ),
      );
    });

    test(
      'FailingAdapter installs on a Dio the suite did not construct',
      () async {
        final dio = Dio()
          ..httpClientAdapter = FailingAdapter(
            DioExceptionType.connectionTimeout,
            error: 'origin unreachable',
          );

        await expectLater(
          dio.get<Map<String, dynamic>>('/anything'),
          throwsA(
            isA<DioException>()
                .having(
                  (e) => e.type,
                  'type',
                  DioExceptionType.connectionTimeout,
                )
                .having((e) => e.error, 'error', 'origin unreachable'),
          ),
        );
      },
    );
  });
}
