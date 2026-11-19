import 'dart:convert';

import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/network.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';

// A live `GET /api/auth/list-accounts` answer (task 0 probe, 2026-11-19).
const _liveList =
    '[{"accountId":"TmeL0uxivrLYLQdAZ3WdQ4sIGv8PkW5M",'
    '"providerId":"credential",'
    '"userId":"TmeL0uxivrLYLQdAZ3WdQ4sIGv8PkW5M",'
    '"createdAt":"2026-11-19T18:38:40.649Z",'
    '"updatedAt":"2026-11-19T18:38:40.649Z",'
    '"id":"6UJgqBrNUba7ms7JrIvBYXKG5hvDXGWS","scopes":[]}]';

Matcher _linkFailure(ProviderLinkFailureReason reason, String code) =>
    isA<AuthProviderLinkException>()
        .having((e) => e.reason, 'reason', reason)
        .having((e) => e.code, 'code', code);

const _list = '$testAuthBasePath/list-accounts';

typedef _Wire = ({Dio dio, ScriptedServer server, List<RequestOptions> sent});

// A REAL Dio over a recording `ScriptedServer`. [permissive] resolves every
// status, as the platform factories' `validateStatus` does; without it a
// non-2xx is thrown as a `badResponse`, as an injected Dio's default does.
// The Dio defaults to `ResponseType.bytes`, under which Dio skips forcing
// `responseType` from the type argument, so only the options the helper is
// given make the request plain (#360).
_Wire _wire({required bool permissive}) {
  final server = ScriptedServer();
  final sent = <RequestOptions>[];
  final dio =
      Dio(
          BaseOptions(
            baseUrl: testServerUrl,
            responseType: ResponseType.bytes,
            validateStatus: permissive ? (_) => true : null,
          ),
        )
        ..httpClientAdapter = server
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              sent.add(options);
              handler.next(options);
            },
          ),
        );
  return (dio: dio, server: server, sent: sent);
}

Future<Response<String>> _sendList(Dio dio) => sendSignInMethodsRequest(
  (options) => dio.get<String>(_list, options: options),
  options: Options(responseType: ResponseType.plain),
  context: 'listing sign-in methods',
);

Response<String> _answer(String body) => Response<String>(
  requestOptions: RequestOptions(path: _list),
  statusCode: 200,
  data: body,
);

void main() {
  group('parseSignInMethods', () {
    test('parses the live list-accounts body with linkedAt set', () {
      final methods = parseSignInMethods(jsonDecode(_liveList));

      expect(methods, [
        SignInMethod(
          id: '6UJgqBrNUba7ms7JrIvBYXKG5hvDXGWS',
          providerId: 'credential',
          linkedAt: DateTime.utc(2026, 11, 19, 18, 38, 40, 649),
        ),
      ]);
      expect(methods.single.isPassword, isTrue);
    });

    test('ignores unknown keys', () {
      final methods = parseSignInMethods([
        {
          'id': 'a',
          'providerId': 'authentik',
          'future': 1,
          'scopes': <Object>[],
        },
      ]);

      expect(methods.single.id, 'a');
      expect(methods.single.providerId, 'authentik');
    });

    test('a missing or bad createdAt gives linkedAt null', () {
      final methods = parseSignInMethods([
        {'id': 'a', 'providerId': 'x'},
        {'id': 'b', 'providerId': 'y', 'createdAt': 'yesterday'},
        {'id': 'c', 'providerId': 'z', 'createdAt': 5},
      ]);

      expect(methods.map((m) => m.linkedAt), [null, null, null]);
    });

    test('a non-list body throws FormatException', () {
      expect(
        () => parseSignInMethods({'accounts': <Object>[]}),
        throwsFormatException,
      );
      expect(() => parseSignInMethods(null), throwsFormatException);
    });

    test('a row missing id throws FormatException', () {
      expect(
        () => parseSignInMethods([
          {'providerId': 'credential'},
        ]),
        throwsFormatException,
      );
    });

    test('a row that is not an object throws FormatException', () {
      expect(() => parseSignInMethods(['x']), throwsFormatException);
    });
  });

  group('paths', () {
    test('resolve against the identity auth base path', () {
      final identity = testServerIdentity();

      expect(listSignInMethodsPath(identity), '/api/auth/list-accounts');
      expect(linkProviderPath(identity), '/api/auth/link-social');
      expect(unlinkSignInMethodPath(identity), '/api/auth/unlink-account');
    });
  });

  group('signInMethodsRefusal', () {
    test('403 PROVIDER_LINK_NEEDS_RECENT_SIGN_IN is needsRecentSignIn', () {
      final error = signInMethodsRefusal(
        403,
        '{"code":"PROVIDER_LINK_NEEDS_RECENT_SIGN_IN","message":"Linking a '
        'sign-in provider needs a recent sign-in. Sign in again, then link '
        'it"}',
        context: 'link',
      );

      expect(
        error,
        _linkFailure(
          ProviderLinkFailureReason.needsRecentSignIn,
          'PROVIDER_LINK_NEEDS_RECENT_SIGN_IN',
        ),
      );
    });

    test('403 SESSION_NOT_FRESH is needsRecentSignIn', () {
      final error = signInMethodsRefusal(
        403,
        '{"message":"Session is not fresh","code":"SESSION_NOT_FRESH"}',
        context: 'unlink',
      );

      expect(
        error,
        _linkFailure(
          ProviderLinkFailureReason.needsRecentSignIn,
          'SESSION_NOT_FRESH',
        ),
      );
    });

    test('400 FAILED_TO_UNLINK_LAST_ACCOUNT is lastSignInMethod', () {
      final error = signInMethodsRefusal(
        400,
        '{"message":"You can\'t unlink your last '
        'account","code":"FAILED_TO_UNLINK_LAST_ACCOUNT"}',
        context: 'unlink',
      );

      expect(
        error,
        _linkFailure(
          ProviderLinkFailureReason.lastSignInMethod,
          'FAILED_TO_UNLINK_LAST_ACCOUNT',
        ),
      );
    });

    test('an unlisted code is generic but keeps its code', () {
      final error = signInMethodsRefusal(
        400,
        '{"message":"x","code":"ACCOUNT_NOT_FOUND"}',
        context: 'unlink',
      );

      expect(
        error,
        _linkFailure(ProviderLinkFailureReason.generic, 'ACCOUNT_NOT_FOUND'),
      );
    });

    test('a 500 with an HTML body is AuthServerException(500)', () {
      final error = signInMethodsRefusal(
        500,
        '<html><body>Bad gateway</body></html>',
        context: 'list',
      );

      expect(
        error,
        isA<AuthServerException>().having((e) => e.statusCode, 'status', 500),
      );
    });

    test('a 429 is a rate limit carrying its wait', () {
      final error = signInMethodsRefusal(
        429,
        '{"code":"RATE_LIMITED"}',
        headers: Headers.fromMap({
          'x-retry-after': ['7'],
        }),
        context: 'list',
      );

      expect(
        error,
        isA<AuthRateLimitedException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 7),
        ),
      );
    });
  });

  group('sendSignInMethodsRequest', () {
    test(
      'returns a 2xx response, sent with the options it was given',
      () async {
        final (:dio, :server, :sent) = _wire(permissive: true);
        server.on('GET', _list, (_) => const ScriptedResponse(_liveList));

        final response = await _sendList(dio);

        expect(response.statusCode, 200);
        expect(response.data, _liveList);
        expect(sent.single.responseType, ResponseType.plain);
      },
    );

    for (final permissive in [true, false]) {
      group(permissive ? 'resolved by the Dio' : 'thrown as a badResponse', () {
        test("a 4xx with a code is that code's link failure", () async {
          final (:dio, :server, sent: _) = _wire(permissive: permissive);
          server.on(
            'GET',
            _list,
            (_) => const ScriptedResponse(
              '{"message":"Session is not fresh","code":"SESSION_NOT_FRESH"}',
              status: 403,
            ),
          );

          await expectLater(
            _sendList(dio),
            throwsA(
              _linkFailure(
                ProviderLinkFailureReason.needsRecentSignIn,
                'SESSION_NOT_FRESH',
              ),
            ),
          );
        });

        test(
          'a 5xx with no code is AuthServerException for its status',
          () async {
            final (:dio, :server, sent: _) = _wire(permissive: permissive);
            server.on(
              'GET',
              _list,
              (_) => const ScriptedResponse(
                '<html><body>Bad gateway</body></html>',
                status: 502,
              ),
            );

            await expectLater(
              _sendList(dio),
              throwsA(
                isA<AuthServerException>().having(
                  (e) => e.statusCode,
                  'status',
                  502,
                ),
              ),
            );
          },
        );

        test(
          'a 429 is a rate limit carrying its x-retry-after wait',
          () async {
            final (:dio, :server, sent: _) = _wire(permissive: permissive);
            server.on(
              'GET',
              _list,
              (_) => const ScriptedResponse(
                '{"code":"RATE_LIMITED"}',
                status: 429,
                headers: {
                  'x-retry-after': ['7'],
                },
              ),
            );

            await expectLater(
              _sendList(dio),
              throwsA(
                isA<AuthRateLimitedException>().having(
                  (e) => e.retryAfter,
                  'retryAfter',
                  const Duration(seconds: 7),
                ),
              ),
            );
          },
        );
      });
    }

    test('a transport failure is AuthNetworkException', () async {
      final (:dio, :server, sent: _) = _wire(permissive: true);
      server.drop('GET', _list);

      await expectLater(
        _sendList(dio),
        throwsA(isA<AuthNetworkException>()),
      );
    });
  });

  group('readSignInMethods', () {
    test('reads a list-accounts body into sign-in methods', () async {
      final methods = await readSignInMethods(
        _answer(_liveList),
        decode: decodeJsonBody,
      );

      expect(methods.single.id, '6UJgqBrNUba7ms7JrIvBYXKG5hvDXGWS');
      expect(methods.single.isPassword, isTrue);
    });

    test('a body that is not a list is AuthServerException carrying the '
        'parse error', () async {
      await expectLater(
        readSignInMethods(
          _answer('{"accounts":[]}'),
          decode: decodeJsonBody,
        ),
        throwsA(
          isA<AuthServerException>()
              .having((e) => e.statusCode, 'status', 200)
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
    });

    test('a body that is not JSON is AuthServerException', () async {
      await expectLater(
        readSignInMethods(_answer('<html>'), decode: decodeJsonBody),
        throwsA(
          isA<AuthServerException>().having((e) => e.statusCode, 'status', 200),
        ),
      );
    });

    test('a decode that cannot run is AuthLocalDecodeException', () async {
      await expectLater(
        readSignInMethods(
          _answer(_liveList),
          decode: (_) async => throw StateError('no isolate'),
        ),
        throwsA(isA<AuthLocalDecodeException>()),
      );
    });
  });
}
