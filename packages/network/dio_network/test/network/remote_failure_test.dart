import 'package:bge_test_support/network.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for a source's exception family: transient, permanent, and
/// whatever its `refused` hook claims.
sealed class _Failure implements Exception {
  const _Failure();
}

final class _Transient extends _Failure {
  const _Transient(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;
}

final class _Permanent extends _Failure {
  const _Permanent(this.message, {required this.statusCode, this.cause});

  final String message;
  final int statusCode;
  final Object? cause;
}

final class _Claimed extends _Failure {
  const _Claimed(this.refusal);

  final RemoteRefusal refusal;
}

final class _TestFamily extends RemoteFailureFamily<_Failure> {
  const _TestFamily({this.onRefused, this.onUnanswered})
    : super(transient: _Transient.new, permanent: _Permanent.new);

  final _Failure? Function(RemoteRefusal refusal)? onRefused;
  final _Failure? Function(DioException error, String message)? onUnanswered;

  @override
  _Failure? refused(RemoteRefusal refusal) => onRefused?.call(refusal);

  @override
  _Failure? unanswered(DioException error, String message) =>
      onUnanswered?.call(error, message);
}

/// Nest's rendering of an `HttpException` carrying a message.
String _envelope(int status) =>
    '{"statusCode":$status,"message":"m","error":"E"}';

const _family = _TestFamily();

TypeMatcher<_Transient> _transient(int? status) =>
    isA<_Transient>().having((e) => e.statusCode, 'statusCode', status);

TypeMatcher<_Permanent> _permanent(int status) =>
    isA<_Permanent>().having((e) => e.statusCode, 'statusCode', status);

/// A request the way the sources send one: the body as a `String`, with the
/// response type pinned.
Future<Response<String>> Function() _get(Dio dio) =>
    () => dio.get<String>(
      '/x',
      options: Options(responseType: ResponseType.plain),
    );

/// The [DioException] [dio] throws for a request.
Future<DioException> _thrownBy(Dio dio) async {
  try {
    await _get(dio)();
  } on DioException catch (error) {
    return error;
  }
  fail('the request did not throw');
}

void main() {
  group('remoteVerdictFor', () {
    void expectVerdict(
      Iterable<int> statuses,
      RemoteVerdict verdict, {
      Object? body,
    }) {
      for (final status in statuses) {
        expect(
          remoteVerdictFor(status, body: body),
          verdict,
          reason: '$status with body $body',
        );
      }
    }

    test('a 5xx is a server error', () {
      expectVerdict([500, 502, 503, 511], RemoteVerdict.serverError);
    });

    test('401 is a rejected session', () {
      expectVerdict([401], RemoteVerdict.sessionRejected);
    });

    test('408 and 429 are throttled', () {
      expectVerdict([408, 429], RemoteVerdict.throttled);
    });

    test('407 is not the API', () {
      expectVerdict([407], RemoteVerdict.notTheApi);
    });

    test('403 and 404 without the envelope are not the API', () {
      expectVerdict([403, 404], RemoteVerdict.notTheApi);
      expectVerdict([403, 404], RemoteVerdict.notTheApi, body: '<html>');
    });

    test('403 and 404 with the envelope are refused', () {
      for (final status in [403, 404]) {
        expect(
          remoteVerdictFor(status, body: _envelope(status)),
          RemoteVerdict.refused,
          reason: '$status',
        );
      }
    });

    test('409 saying retryable is a retryable conflict', () {
      expectVerdict(
        [409],
        RemoteVerdict.retryableConflict,
        body: '{"statusCode":409,"message":"m","error":"E","retryable":true}',
      );
      expectVerdict(
        [409],
        RemoteVerdict.retryableConflict,
        body: '{"retryable":true}',
      );
    });

    test('409 with the envelope but no retryable is refused', () {
      expectVerdict([409], RemoteVerdict.refused, body: _envelope(409));
    });

    test('any other 4xx is refused', () {
      expectVerdict([400, 402, 410, 413, 422], RemoteVerdict.refused);
    });

    test('1xx and 3xx are no answer', () {
      expectVerdict([100, 301, 302, 304], RemoteVerdict.noAnswer);
    });
  });

  group('failureForStatus', () {
    test('every transient verdict is transient, with the status', () {
      final cases = <(int, Object?)>[
        (302, null), // noAnswer
        (401, null), // sessionRejected
        (408, null), // throttled
        (429, null),
        (407, null), // notTheApi
        (403, '<html>'),
        (404, null),
        (500, null), // serverError
        (511, null),
        (409, '{"retryable":true}'), // retryableConflict
      ];
      final cause = StateError('cause');

      for (final (status, body) in cases) {
        expect(
          remoteVerdictFor(status, body: body).isTransient,
          isTrue,
          reason: '$status',
        );
        expect(
          failureForStatus(_family, status, 'm', body: body, cause: cause),
          _transient(status).having((e) => e.cause, 'cause', same(cause)),
          reason: '$status',
        );
      }
    });

    test('a refused 400 is permanent', () {
      expect(
        failureForStatus(_family, 400, 'm', body: _envelope(400), cause: null),
        _permanent(400),
      );
    });

    test('a refused 404 nobody claims is transient', () {
      expect(
        failureForStatus(_family, 404, 'm', body: _envelope(404), cause: null),
        _transient(404),
      );
    });

    test('a claimed refusal wins, told whether the API wrote it', () {
      final family = _TestFamily(onRefused: _Claimed.new);
      final cause = StateError('cause');

      final enveloped = failureForStatus(
        family,
        403,
        'm',
        body: _envelope(403),
        cause: cause,
      );
      expect(
        enveloped,
        isA<_Claimed>().having(
          (e) => e.refusal,
          'refusal',
          isA<RemoteRefusal>()
              .having((r) => r.status, 'status', 403)
              .having((r) => r.fromApi, 'fromApi', isTrue)
              .having((r) => r.body, 'body', _envelope(403))
              .having((r) => r.message, 'message', 'm')
              .having((r) => r.cause, 'cause', same(cause)),
        ),
      );

      final bare = failureForStatus(family, 400, 'm', body: null, cause: null);
      expect(
        bare,
        isA<_Claimed>().having(
          (e) => e.refusal.fromApi,
          'refusal.fromApi',
          isFalse,
        ),
      );
    });

    test('the notTheApi 403 message says the request missed the API', () {
      expect(
        failureForStatus(_family, 403, 'm', body: '<html>', cause: null),
        isA<_Transient>().having(
          (e) => e.message,
          'message',
          endsWith('; the request did not reach the API'),
        ),
      );
    });
  });

  group('failureForDioException', () {
    test('a failure with no response is transient, with no status', () async {
      final error = await _thrownBy(
        unreachableDio(DioExceptionType.connectionTimeout),
      );

      expect(
        failureForDioException(_family, error, action: 'act'),
        _transient(null).having((e) => e.cause, 'cause', same(error)),
      );
    });

    test('an unanswered hook wins', () async {
      final error = await _thrownBy(
        unreachableDio(DioExceptionType.connectionTimeout),
      );
      final family = _TestFamily(
        onUnanswered: (error, message) =>
            _Permanent(message, statusCode: 0, cause: error),
      );

      expect(
        failureForDioException(family, error, action: 'act'),
        _permanent(0)
            .having((e) => e.message, 'message', 'act failed')
            .having((e) => e.cause, 'cause', same(error)),
      );
    });

    test('a response is read by its status and body', () {
      final requestOptions = RequestOptions(path: '/x');
      final error = DioException(
        requestOptions: requestOptions,
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: requestOptions,
          statusCode: 403,
          data: _envelope(403),
        ),
      );
      final family = _TestFamily(onRefused: _Claimed.new);

      expect(
        failureForDioException(family, error, action: 'act'),
        isA<_Claimed>().having(
          (e) => e.refusal,
          'refusal',
          isA<RemoteRefusal>()
              .having((r) => r.status, 'status', 403)
              .having((r) => r.fromApi, 'fromApi', isTrue)
              .having((r) => r.cause, 'cause', same(error)),
        ),
      );
    });
  });

  group('sendForJson', () {
    Future<RemoteJson> send(Dio dio, {bool readBody = true}) => sendForJson(
      _get(dio),
      action: 'act',
      family: _family,
      readBody: readBody,
    );

    test('returns a JSON object with its status', () async {
      final (:body, :status) = await send(
        cannedDio(body: '{"a":1}', statusCode: 200),
      );

      expect(body, {'a': 1});
      expect(status, 200);
    });

    test('an empty 2xx body is permanent, with its status', () async {
      await expectLater(
        send(cannedDio(body: '', statusCode: 201)),
        throwsA(_permanent(201)),
      );
    });

    test('a 2xx body that is not JSON is permanent, with its status', () async {
      await expectLater(
        send(
          cannedDio(body: '<html>', statusCode: 200, contentType: 'text/html'),
        ),
        throwsA(
          _permanent(200)
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
    });

    test('a 2xx body that is not a JSON object is permanent', () async {
      await expectLater(
        send(cannedDio(body: '[1]', statusCode: 200)),
        throwsA(_permanent(200)),
      );
    });

    test('a 5xx is transient, with its status', () async {
      await expectLater(
        send(cannedDio(body: _envelope(503), statusCode: 503)),
        throwsA(_transient(503)),
      );
    });

    test('readBody: false returns no body, with the status', () async {
      final (:body, :status) = await send(
        cannedDio(body: '', statusCode: 204),
        readBody: false,
      );

      expect(body, isEmpty);
      expect(status, 204);
    });

    test('a non-Dio throw from the request is transient, never raw', () async {
      final error = StateError('x');

      await expectLater(
        sendForJson(() => throw error, action: 'act', family: _family),
        throwsA(_transient(null).having((e) => e.cause, 'cause', same(error))),
      );
    });

    test('an unreachable server is transient, with no status', () async {
      await expectLater(
        send(unreachableDio(DioExceptionType.connectionError)),
        throwsA(_transient(null)),
      );
    });
  });

  group('parseRemote', () {
    test('returns what the mapping returns', () {
      expect(parseRemote(_family, () => 1, action: 'act', status: 200), 1);
    });

    test('a mapping that throws is permanent, with the status', () {
      expect(
        () => parseRemote(
          _family,
          () => throw StateError('bad'),
          action: 'act',
          status: 200,
        ),
        throwsA(
          _permanent(200).having(
            (e) => e.message,
            'message',
            startsWith('Failed to parse the act response'),
          ),
        ),
      );
    });
  });
}
