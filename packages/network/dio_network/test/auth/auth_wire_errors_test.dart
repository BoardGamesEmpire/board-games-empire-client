// The auth wire-error mapping both auth repositories share (#877).
//
// Driven through a REAL Dio with a canned transport, so each DioException is
// the one Dio itself builds: a non-2xx thrown as `badResponse` with the
// response attached (Dio's default `validateStatus`, the shape an injected
// Dio produces), or a transport failure with no response at all.

import 'package:bge_test_support/network.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:dio_network/src/network/api_error_envelope.dart'
    show probeJsonMaxChars;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';

const _path = '/api/auth/sign-in/email';

/// The [DioException] [dio] throws for one plain-bodied POST.
Future<DioException> _thrownBy(Dio dio) async {
  try {
    await dio.post<String>(
      _path,
      options: Options(responseType: ResponseType.plain),
    );
  } on DioException catch (e) {
    return e;
  }
  fail('expected the request to throw');
}

/// A rejection Dio throws as `badResponse`, with [status] and [body] attached.
Future<DioException> _rejected(int status, {String body = ''}) => _thrownBy(
  cannedDio(body: body, statusCode: status, permissiveStatus: false),
);

/// A 429 thrown with an `X-Retry-After` of [seconds].
Future<DioException> _rateLimited(String seconds) {
  final server = ScriptedServer()
    ..on(
      'POST',
      _path,
      (_) => ScriptedResponse(
        '{"code":"RATE_LIMITED"}',
        status: 429,
        headers: {
          retryAfterHeader: [seconds],
        },
      ),
    );
  return _thrownBy(Dio()..httpClientAdapter = server);
}

String _envelope(String code) => '{"code":"$code","message":"refused"}';

Matcher _serverFault(int? status, String message) => isA<AuthServerException>()
    .having((e) => e.statusCode, 'statusCode', status)
    .having((e) => e.message, 'message', message);

void main() {
  group('mapAuthDioException', () {
    test('a 401 is invalid credentials', () async {
      final e = await _rejected(401);

      expect(
        mapAuthDioException(e, credentialGrant: true),
        isA<AuthInvalidCredentialsException>(),
      );
    });

    test(
      'a grant 403 with EMAIL_NOT_VERIFIED is an unverified email',
      () async {
        final e = await _rejected(403, body: _envelope('EMAIL_NOT_VERIFIED'));

        expect(
          mapAuthDioException(e, credentialGrant: true),
          isA<AuthEmailNotVerifiedException>(),
        );
      },
    );

    test(
      'a grant 403 with REGISTRATION_DISABLED is closed registration',
      () async {
        final e = await _rejected(
          403,
          body: _envelope('REGISTRATION_DISABLED'),
        );

        expect(
          mapAuthDioException(e, credentialGrant: true),
          isA<AuthRegistrationDisabledException>(),
        );
      },
    );

    test(
      'a 403 off a grant is invalid credentials whatever its code',
      () async {
        final e = await _rejected(403, body: _envelope('EMAIL_NOT_VERIFIED'));

        expect(
          mapAuthDioException(e, credentialGrant: false),
          isA<AuthInvalidCredentialsException>(),
        );
      },
    );

    test('a grant 429 is rate limited with the wait it names', () async {
      final e = await _rateLimited('7');

      expect(
        mapAuthDioException(e, credentialGrant: true),
        isA<AuthRateLimitedException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 7),
        ),
      );
    });

    test('a 429 off a grant falls through to an unexpected status', () async {
      final e = await _rateLimited('7');

      expect(
        mapAuthDioException(e, credentialGrant: false),
        _serverFault(429, 'Unexpected 429 from the server.'),
      );
    });

    test('a grant 422 with a USER_ALREADY_EXISTS code is a duplicate '
        'email', () async {
      final e = await _rejected(
        422,
        body: _envelope('USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL'),
      );

      expect(
        mapAuthDioException(e, credentialGrant: true),
        isA<AuthEmailAlreadyExistsException>(),
      );
    });

    test('a 409 off a grant is not a duplicate email', () async {
      final e = await _rejected(409);

      expect(
        mapAuthDioException(e, credentialGrant: false),
        _serverFault(409, 'Unexpected 409 from the server.'),
      );
    });

    test('a 503 is a server error carrying its status', () async {
      final thrown = await _rejected(503);

      expect(
        mapAuthDioException(thrown, credentialGrant: true),
        isA<AuthServerException>()
            .having((e) => e.statusCode, 'statusCode', 503)
            .having((e) => e.message, 'message', 'Server error 503.')
            .having((e) => e.cause, 'cause', same(thrown)),
      );
    });

    for (final type in [
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.connectionError,
    ]) {
      test('a $type is a network failure', () async {
        final e = await _thrownBy(unreachableDio(type));

        expect(
          mapAuthDioException(e, credentialGrant: true),
          isA<AuthNetworkException>().having(
            (e) => e.message,
            'message',
            'Connection failed. Check your network.',
          ),
        );
      });
    }

    test('a 404 is an unexpected status from the server', () async {
      final e = await _rejected(404);

      expect(
        mapAuthDioException(e, credentialGrant: true),
        _serverFault(404, 'Unexpected 404 from the server.'),
      );
    });

    test('a cancellation with no status is a network failure', () async {
      final thrown = await _thrownBy(unreachableDio(DioExceptionType.cancel));
      expect(thrown.response, isNull);
      expect(thrown.message, isNull);

      expect(
        mapAuthDioException(thrown, credentialGrant: true),
        isA<AuthNetworkException>()
            .having((e) => e.message, 'message', 'Network error.')
            .having((e) => e.cause, 'cause', same(thrown)),
      );
    });
  });

  group('authRejectionCode', () {
    test('reads the code from raw JSON text', () {
      expect(
        authRejectionCode(_envelope('EMAIL_NOT_VERIFIED')),
        'EMAIL_NOT_VERIFIED',
      );
    });

    test('reads the code from a decoded map', () {
      expect(
        authRejectionCode({'code': 'REGISTRATION_DISABLED'}),
        'REGISTRATION_DISABLED',
      );
    });

    test('is null for an envelope past the probe bound', () {
      const head = '{"code":"EMAIL_NOT_VERIFIED","pad":"';
      const tail = '"}';
      final body =
          '$head${'a' * (probeJsonMaxChars + 1 - head.length - tail.length)}'
          '$tail';
      expect(body.length, probeJsonMaxChars + 1);

      expect(authRejectionCode(body), isNull);
    });

    test('is null for a body that is not JSON', () {
      expect(authRejectionCode('<html>Bad Gateway</html>'), isNull);
    });

    test('is null for a code that is not a string', () {
      expect(authRejectionCode({'code': 403}), isNull);
    });
  });

  group('isEmailAlreadyExists', () {
    test('any 409 is a duplicate', () {
      expect(isEmailAlreadyExists(409, null), isTrue);
    });

    test('a USER_ALREADY_EXISTS-prefixed code is a duplicate at any '
        'status', () {
      expect(
        isEmailAlreadyExists(422, _envelope('USER_ALREADY_EXISTS')),
        isTrue,
      );
      expect(
        isEmailAlreadyExists(200, {'code': 'USER_ALREADY_EXISTS'}),
        isTrue,
      );
    });

    test('a bare 422 with another code is not', () {
      expect(isEmailAlreadyExists(422, _envelope('VALIDATION_ERROR')), isFalse);
    });
  });

  group('forbiddenRefusal', () {
    test('reads the refusal from the code', () {
      expect(
        forbiddenRefusal(_envelope('EMAIL_NOT_VERIFIED')),
        isA<AuthEmailNotVerifiedException>(),
      );
      expect(
        forbiddenRefusal(_envelope('REGISTRATION_DISABLED')),
        isA<AuthRegistrationDisabledException>(),
      );
    });

    test('is invalid credentials without a readable code', () {
      expect(
        forbiddenRefusal('<html>Forbidden</html>'),
        isA<AuthInvalidCredentialsException>(),
      );
      expect(forbiddenRefusal(null), isA<AuthInvalidCredentialsException>());
    });
  });

  group('assertAuthSuccess', () {
    void check(int? status, Object? body, {Headers? headers}) =>
        assertAuthSuccess(status, body, headers: headers, context: 'sign-in');

    test('returns for a 2xx with no rejection envelope', () {
      expect(() => check(200, {'token': 't'}), returnsNormally);
    });

    test('a 401 is invalid credentials', () {
      expect(
        () => check(401, null),
        throwsA(isA<AuthInvalidCredentialsException>()),
      );
    });

    test('a 403 is read by its code', () {
      expect(
        () => check(403, _envelope('EMAIL_NOT_VERIFIED')),
        throwsA(isA<AuthEmailNotVerifiedException>()),
      );
    });

    test('a 429 is rate limited, ahead of a duplicate-email code', () {
      expect(
        () => check(
          429,
          _envelope('USER_ALREADY_EXISTS'),
          headers: Headers.fromMap({
            retryAfterHeader: ['3'],
          }),
        ),
        throwsA(
          isA<AuthRateLimitedException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 3),
          ),
        ),
      );
    });

    test('a duplicate-email code throws even on a 2xx', () {
      expect(
        () => check(200, {'code': 'USER_ALREADY_EXISTS'}),
        throwsA(isA<AuthEmailAlreadyExistsException>()),
      );
    });

    for (final status in [null, 302, 404, 500]) {
      test('a $status is unexpected during the context', () {
        expect(
          () => check(status, null),
          throwsA(_serverFault(status, 'Unexpected $status during sign-in.')),
        );
      });
    }
  });

  group('decodeAuthBody', () {
    Future<Object?> unreachableDecode(String _) =>
        fail('the decoder must not run');

    for (final raw in [null, '']) {
      test('${raw == null ? 'null' : 'an empty'} body decodes to nothing, '
          'without running the decoder', () async {
        final decoded = await decodeAuthBody(
          raw,
          decode: unreachableDecode,
          context: 'sign-in',
          status: 200,
        );

        expect(decoded.value, isNull);
        expect(decoded.failure, isNull);
      });
    }

    test('a JSON body decodes through the given decoder', () async {
      final decoded = await decodeAuthBody(
        '{"token":"t"}',
        decode: decodeJsonBody,
        context: 'sign-in',
        status: 200,
      );

      expect(decoded.value, {'token': 't'});
      expect(decoded.failure, isNull);
    });

    test('a body that is not JSON is a server fault naming the '
        'context', () async {
      final decoded = await decodeAuthBody(
        '<html>',
        decode: decodeJsonBody,
        context: 'sign-up',
        status: 200,
      );

      expect(decoded.value, isNull);
      expect(
        decoded.failure,
        isA<AuthServerException>()
            .having((e) => e.statusCode, 'statusCode', 200)
            .having((e) => e.message, 'message', contains('sign-up'))
            .having((e) => e.cause, 'cause', isA<FormatException>()),
      );
    });

    test('a decode this device could not perform stays retryable', () async {
      final error = StateError('isolate would not spawn');

      final decoded = await decodeAuthBody(
        '{"token":"t"}',
        decode: (_) async => throw error,
        context: 'sign-in',
        status: 200,
      );

      expect(decoded.value, isNull);
      expect(
        decoded.failure,
        isA<AuthLocalDecodeException>()
            .having(
              (e) => e.message,
              'message',
              'This device could not decode the response during sign-in.',
            )
            .having((e) => e.cause, 'cause', same(error)),
      );
    });
  });
}
