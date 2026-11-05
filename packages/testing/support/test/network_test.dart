import 'dart:async';

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

  group('ScriptedServer', () {
    late ScriptedServer server;
    late Dio dio;

    setUp(() {
      server = ScriptedServer();
      dio = Dio(BaseOptions(baseUrl: 'https://bge.test.invalid'))
        ..httpClientAdapter = server;
    });

    test(
      'answers the route matching method and path suffix, as JSON',
      () async {
        server
          ..json('GET', '/api/thing', {'who': 'get'})
          ..json('POST', '/api/thing', {'who': 'post'}, status: 201);

        final got = await dio.get<Map<String, dynamic>>('/api/thing');
        final posted = await dio.post<Map<String, dynamic>>('/api/thing');

        expect(got.data, {'who': 'get'});
        expect(got.headers.value(Headers.contentTypeHeader), contains('json'));
        expect(posted.data, {'who': 'post'});
        expect(posted.statusCode, 201);
      },
    );

    test(
      'records every request with method, path, query, headers and data',
      () async {
        server.json('POST', '/api/thing', <String, Object?>{});

        await dio.post<Object?>(
          '/api/thing',
          queryParameters: {'a': '1'},
          data: {'clientRequestId': 'abc'},
          options: Options(headers: {'Authorization': 'Bearer t'}),
        );

        expect(server.requests, hasLength(1));
        final r = server.requests.single;
        expect(r.method, 'POST');
        expect(r.path, '/api/thing');
        expect(r.queryParameters, {'a': '1'});
        expect(r.headers['Authorization'], 'Bearer t');
        expect(r.authorization, 'Bearer t');
        expect(r.data, isA<Map<dynamic, dynamic>>());
        expect((r.data! as Map<dynamic, dynamic>)['clientRequestId'], 'abc');
      },
    );

    test(
      'records each body as it was sent, though the caller changes it later',
      () async {
        server.json('POST', '/api/thing', <String, Object?>{});
        final body = <String, Object?>{
          'clientRequestId': 'first',
          'tags': ['a'],
        };
        final query = <String, dynamic>{
          'ids': ['1'],
        };

        await dio.post<Object?>(
          '/api/thing',
          data: body,
          queryParameters: query,
        );
        body['clientRequestId'] = 'second';
        (body['tags']! as List<Object?>).add('b');
        (query['ids'] as List<Object?>).add('2');
        await dio.post<Object?>(
          '/api/thing',
          data: body,
          queryParameters: query,
        );

        expect(server.requests[0].data, {
          'clientRequestId': 'first',
          'tags': ['a'],
        });
        expect(server.requests[0].queryParameters, {
          'ids': ['1'],
        });
        expect(server.requests[1].data, {
          'clientRequestId': 'second',
          'tags': ['a', 'b'],
        });
      },
    );

    test(
      'stores a JSON String body decoded and a non-JSON String as-is',
      () async {
        server.json('POST', '/api/thing', <String, Object?>{});

        await dio.post<Object?>('/api/thing', data: '{"k":"v"}');
        await dio.post<Object?>('/api/thing', data: 'not json');

        expect(server.requests[0].data, {'k': 'v'});
        expect(server.requests[1].data, 'not json');
      },
    );

    test('reads the authorization header whatever its case', () async {
      server.json('GET', '/api/thing', <String, Object?>{});

      await dio.get<Object?>(
        '/api/thing',
        options: Options(headers: {'authorization': 'Bearer low'}),
      );

      final r = server.requests.single;
      expect(r.authorization, 'Bearer low');
      expect(r.headers['Authorization'], 'Bearer low');
    });

    test('matches a path written with an inline query', () async {
      server.json('GET', '/api/thing', {'ok': true});

      final res = await dio.get<Map<String, dynamic>>('/api/thing?x=1');

      expect(res.data, {'ok': true});
      expect(server.requestsTo('GET', '/api/thing'), hasLength(1));
      expect(server.requests.single.path, '/api/thing?x=1');
    });

    test(
      'merges ScriptedResponse.headers over the JSON content type',
      () async {
        server.on(
          'GET',
          '/api/thing',
          (_) => const ScriptedResponse(
            '{"ok":true}',
            headers: {
              'x-extra': ['yes'],
            },
          ),
        );

        final res = await dio.get<Map<String, dynamic>>('/api/thing');

        expect(res.headers.value('x-extra'), 'yes');
        expect(
          res.headers.value(Headers.contentTypeHeader),
          contains('application/json'),
        );
      },
    );

    test('an unrouted request throws naming it', () async {
      await expectLater(
        dio.get<Object?>('/api/nowhere'),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'error',
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('GET /api/nowhere'),
            ),
          ),
        ),
      );
    });

    test(
      'an unrouted request is kept in unrouted as well as requests, and a '
      'clear keeps it there',
      () async {
        server.json('GET', '/api/known', <String, Object?>{});

        await dio.get<Object?>('/api/known');
        await dio.get<Object?>('/api/nowhere').then((_) {}, onError: (_) {});

        expect(server.requests, hasLength(2));
        expect(server.unrouted.map((r) => r.path), ['/api/nowhere']);

        server.clear();
        expect(server.requests, isEmpty);
        expect(server.unrouted.map((r) => r.path), ['/api/nowhere']);
      },
    );

    test('a held route records the request before it answers', () async {
      final release = Completer<ScriptedResponse>();
      final arrived = Completer<void>();
      server.on('GET', '/api/slow', (_) {
        if (!arrived.isCompleted) arrived.complete();
        return release.future;
      });

      final pending = dio.get<Map<String, dynamic>>('/api/slow');
      var done = false;
      unawaited(pending.then((_) => done = true));
      await arrived.future;
      await Future<void>.delayed(Duration.zero);

      expect(server.requestsTo('GET', '/api/slow'), hasLength(1));
      expect(done, isFalse);

      release.complete(ScriptedResponse.json({'late': true}));
      expect((await pending).data, {'late': true});

      final after = await dio.get<Map<String, dynamic>>('/api/slow');
      expect(after.data, {'late': true});
      expect(server.requestsTo('GET', '/api/slow'), hasLength(2));
    });

    test(
      'a dropped route records the request and fails as a connection error',
      () async {
        server.drop('POST', '/api/lost');

        await expectLater(
          dio.post<Object?>('/api/lost'),
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              'type',
              DioExceptionType.connectionError,
            ),
          ),
        );
        expect(server.requestsTo('POST', '/api/lost'), hasLength(1));
      },
    );

    test('clear forgets requests but keeps routes', () async {
      server.json('GET', '/api/thing', {'ok': true});
      await dio.get<Object?>('/api/thing');

      server.clear();
      expect(server.requests, isEmpty);

      final res = await dio.get<Map<String, dynamic>>('/api/thing');
      expect(res.data, {'ok': true});
    });

    test('re-registering the same key replaces the route', () async {
      server
        ..json('GET', '/api/thing', {'v': 1})
        ..json('GET', '/api/thing', {'v': 2});

      final res = await dio.get<Map<String, dynamic>>('/api/thing');

      expect(res.data, {'v': 2});
    });

    test('rejects two routes for one method where one suffix ends with the '
        'other', () {
      server.json('GET', 'session', <String, Object?>{});

      expect(
        () => server.json('GET', '/api/get-session', <String, Object?>{}),
        throwsA(isA<AssertionError>()),
      );
      // A different method is a different key space.
      server.json('POST', '/api/get-session', <String, Object?>{});
    });
  });
}
