import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import 'package:dio_network/dio_network.dart';

import '../support/canned_adapter.dart';

class MockDio extends Mock implements Dio {}

// Minimal valid identity JSON matching the BgeDiscoveryDto wire format.
const _kServerId = '550e8400-e29b-41d4-a716-446655440000';
const _kServerUrl = 'https://api.example.com';

Map<String, dynamic> _validIdentityJson({String? serverId}) => {
  'well_known_schema_version': 1,
  'bge_server_id': serverId ?? _kServerId,
  'name': 'Board Games Empire',
  'bge_min_client_version': null,
  'bge_max_client_version': null,
  'issuer': _kServerUrl,
  'device_authorization_endpoint': '/api/auth/device',
  'bge_auth_base_path': '/api/auth',
  'bge_session_endpoint': '/api/auth/get-session',
  'bge_sign_out_endpoint': '/api/auth/sign-out',
  'bge_passkey_supported': true,
  'bge_two_factor_supported': true,
  'bge_anonymous_auth_supported': true,
  'strategies': <dynamic>[],
};

Response<String> _makeResponse(
  Map<String, dynamic> data, {
  int statusCode = 200,
}) => Response(
  data: jsonEncode(data),
  statusCode: statusCode,
  requestOptions: RequestOptions(path: ''),
);

Response<String> _makeEmptyResponse({int statusCode = 200}) => Response(
  data: null,
  statusCode: statusCode,
  requestOptions: RequestOptions(path: ''),
);

void main() {
  late MockDio mockDio;
  late WellKnownClientImpl client;

  setUp(() {
    mockDio = MockDio();
    client = WellKnownClientImpl.withDio(mockDio);
  });

  group('WellKnownClientImpl.fetchIdentity', () {
    group('URL construction', () {
      test('appends /.well-known/bge-identity to bare server URL', () async {
        when(() => mockDio.get<String>('$_kServerUrl/.well-known/bge-identity'))
            .thenAnswer((_) async => _makeResponse(_validIdentityJson()));

        await client.fetchIdentity(_kServerUrl);

        verify(
          () => mockDio.get<String>('$_kServerUrl/.well-known/bge-identity'),
        ).called(1);
      });

      test('strips trailing slash before appending well-known path', () async {
        when(() => mockDio.get<String>('$_kServerUrl/.well-known/bge-identity'))
            .thenAnswer((_) async => _makeResponse(_validIdentityJson()));

        await client.fetchIdentity('$_kServerUrl/');

        verify(
          () => mockDio.get<String>('$_kServerUrl/.well-known/bge-identity'),
        ).called(1);
      });
    });

    group('happy path', () {
      setUp(() {
        when(() => mockDio.get<String>(any()))
            .thenAnswer((_) async => _makeResponse(_validIdentityJson()));
      });

      test('returns ServerIdentity on 200 with valid body', () async {
        final identity = await client.fetchIdentity(_kServerUrl);

        expect(identity, isA<ServerIdentity>());
        expect(identity.serverId, _kServerId);
        expect(identity.issuer, _kServerUrl);
      });

      test('parses schema version, name, and open version bounds', () async {
        final identity = await client.fetchIdentity(_kServerUrl);

        expect(identity.wellKnownSchemaVersion, 1);
        expect(identity.name, 'Board Games Empire');
        expect(identity.minClientVersion, isNull);
        expect(identity.maxClientVersion, isNull);
      });

      test('parses populated version bounds', () async {
        final json = _validIdentityJson();
        json['bge_min_client_version'] = '0.1.0';
        json['bge_max_client_version'] = '3.0.0';
        when(() => mockDio.get<String>(any()))
            .thenAnswer((_) async => _makeResponse(json));

        final identity = await client.fetchIdentity(_kServerUrl);

        expect(identity.minClientVersion, '0.1.0');
        expect(identity.maxClientVersion, '3.0.0');
      });

      test('parses capability flags', () async {
        final identity = await client.fetchIdentity(_kServerUrl);

        expect(identity.passkeySupported, isTrue);
        expect(identity.twoFactorSupported, isTrue);
        expect(identity.anonymousAuthSupported, isTrue);
      });

      test('parses empty strategies list', () async {
        final identity = await client.fetchIdentity(_kServerUrl);

        expect(identity.strategies, isEmpty);
      });

      test('parses email/password strategy', () async {
        final json = _validIdentityJson();
        json['strategies'] = [
          {
            'type': 'email_and_password',
            'sign_up_disabled': false,
            'sign_in_endpoint': '/api/auth/sign-in/email',
            'sign_up_endpoint': '/api/auth/sign-up/email',
          },
        ];
        when(() => mockDio.get<String>(any()))
            .thenAnswer((_) async => _makeResponse(json));

        final identity = await client.fetchIdentity(_kServerUrl);

        expect(identity.strategies, hasLength(1));
        expect(identity.strategies.first, isA<EmailAndPasswordStrategy>());
        expect(identity.hasEmailAndPassword, isTrue);
      });
    });

    group('404 response', () {
      setUp(() {
        when(() => mockDio.get<String>(any()))
            .thenAnswer((_) async => _makeEmptyResponse(statusCode: 404));
      });

      test('throws WellKnownNotFoundException', () async {
        expect(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(isA<WellKnownNotFoundException>()),
        );
      });

      test('exception carries the serverUrl', () async {
        try {
          await client.fetchIdentity(_kServerUrl);
          fail('expected exception');
        } on WellKnownNotFoundException catch (e) {
          expect(e.serverUrl, _kServerUrl);
        }
      });
    });

    group('non-200/404 response', () {
      test('throws WellKnownInvalidResponseException for 500', () async {
        when(() => mockDio.get<String>(any()))
            .thenAnswer((_) async => _makeEmptyResponse(statusCode: 500));

        expect(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(
            isA<WellKnownInvalidResponseException>().having(
              (e) => e.statusCode,
              'statusCode',
              500,
            ),
          ),
        );
      });

      test('throws WellKnownInvalidResponseException for 401', () async {
        when(() => mockDio.get<String>(any()))
            .thenAnswer((_) async => _makeEmptyResponse(statusCode: 401));

        expect(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(isA<WellKnownInvalidResponseException>()),
        );
      });
    });

    group('empty body on 200', () {
      test('throws WellKnownInvalidResponseException', () async {
        when(() => mockDio.get<String>(any()))
            .thenAnswer((_) async => _makeEmptyResponse(statusCode: 200));

        expect(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(isA<WellKnownInvalidResponseException>()),
        );
      });
    });

    group('network failures', () {
      test('throws WellKnownUnreachableException on connection timeout', () {
        when(() => mockDio.get<String>(any())).thenThrow(
          DioException(
            type: DioExceptionType.connectionTimeout,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        expect(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(isA<WellKnownUnreachableException>()),
        );
      });

      test('throws WellKnownUnreachableException on connection error', () {
        when(() => mockDio.get<String>(any())).thenThrow(
          DioException(
            type: DioExceptionType.connectionError,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        expect(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(isA<WellKnownUnreachableException>()),
        );
      });

      test(
        'WellKnownUnreachableException carries serverUrl and cause',
        () async {
          final dioError = DioException(
            type: DioExceptionType.connectionError,
            requestOptions: RequestOptions(path: ''),
          );
          when(() => mockDio.get<String>(any())).thenThrow(dioError);

          try {
            await client.fetchIdentity(_kServerUrl);
            fail('expected exception');
          } on WellKnownUnreachableException catch (e) {
            expect(e.serverUrl, _kServerUrl);
            expect(e.cause, same(dioError));
          }
        },
      );
    });

    group('malformed JSON body', () {
      test(
        'throws WellKnownInvalidResponseException on parse failure',
        () async {
          // Missing required fields — fromJson will throw
          when(() => mockDio.get<String>(any())).thenAnswer(
            (_) async => _makeResponse({'bge_server_id': 'only-id'}),
          );

          expect(
            () => client.fetchIdentity(_kServerUrl),
            throwsA(isA<WellKnownInvalidResponseException>()),
          );
        },
      );
    });

    // These run against a **real** Dio with a canned adapter, not `MockDio`.
    // The defect in #182 lives inside Dio's own body cast, which a stubbed
    // `Dio` never performs — see `test/support/canned_adapter.dart`.
    group('a server that answered is never reported unreachable (#182)', () {
      WellKnownClient clientOver(Dio dio) => WellKnownClientImpl.withDio(dio);

      test('200 with an HTML body is invalid, not unreachable', () async {
        final client = clientOver(
          cannedDio(
            body: '<!doctype html><html><body>Hi</body></html>',
            statusCode: 200,
            contentType: 'text/html',
          ),
        );

        await expectLater(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(
            isA<WellKnownInvalidResponseException>().having(
              (e) => e.statusCode,
              'statusCode',
              200,
            ),
          ),
        );
      });

      // The most likely first-run mistake of all: point the app at an ordinary
      // website and its server answers the well-known path with an HTML 404
      // page. The status alone is enough to say "not a BGE server", but the
      // cast throws before the status is ever read.
      test('404 with an HTML body is not-found, not unreachable', () async {
        final client = clientOver(
          cannedDio(
            body: '<!doctype html><html><body>Not Found</body></html>',
            statusCode: 404,
            contentType: 'text/html',
          ),
        );

        await expectLater(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(isA<WellKnownNotFoundException>()),
        );
      });

      test('200 with a JSON array body is invalid, not unreachable', () async {
        final client = clientOver(
          cannedDio(body: '[1, 2, 3]', statusCode: 200),
        );

        await expectLater(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(
            isA<WellKnownInvalidResponseException>().having(
              (e) => e.statusCode,
              'statusCode',
              200,
            ),
          ),
        );
      });

      // `followRedirects: false` is a deliberate decision (URL changes need
      // user confirmation), so the status it produces is worth pinning.
      test('a 302 is invalid and carries its status', () async {
        final client = clientOver(
          cannedDio(
            body: '<html>Moved</html>',
            statusCode: 302,
            contentType: 'text/html',
          ),
        );

        await expectLater(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(
            isA<WellKnownInvalidResponseException>().having(
              (e) => e.statusCode,
              'statusCode',
              302,
            ),
          ),
        );
      });

      // An injected Dio need not carry this class's permissive
      // `validateStatus`, in which case a non-2xx arrives as a thrown
      // `badResponse` with the response attached. The server still answered.
      test('a thrown badResponse still classifies by status', () async {
        final client = clientOver(
          cannedDio(
            body: '<html>Blocked</html>',
            statusCode: 403,
            contentType: 'text/html',
            permissiveStatus: false,
          ),
        );

        await expectLater(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(
            isA<WellKnownInvalidResponseException>().having(
              (e) => e.statusCode,
              'statusCode',
              403,
            ),
          ),
        );
      });

      // Content type is not a reliable signal: a proxy or an SPA catch-all
      // can serve an HTML page under `application/json`, and a dropped
      // connection truncates a genuine JSON body. Dio decodes on content type,
      // so both throw a `FormatException` out of the transformer and arrive as
      // `DioException(type: unknown)` with the status lost.
      test('an HTML body under a JSON content type is invalid', () async {
        final client = clientOver(
          cannedDio(
            body: '<!doctype html><html>Portal</html>',
            statusCode: 200,
          ),
        );

        await expectLater(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(
            isA<WellKnownInvalidResponseException>().having(
              (e) => e.statusCode,
              'statusCode',
              200,
            ),
          ),
        );
      });

      test('a 404 under a JSON content type is still not-found', () async {
        final client = clientOver(
          cannedDio(body: '<html>Not Found</html>', statusCode: 404),
        );

        await expectLater(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(isA<WellKnownNotFoundException>()),
        );
      });

      test('a truncated JSON body is invalid, not unreachable', () async {
        final client = clientOver(
          cannedDio(body: '{"bge_server_id": "abc"', statusCode: 200),
        );

        await expectLater(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(
            isA<WellKnownInvalidResponseException>().having(
              (e) => e.statusCode,
              'statusCode',
              200,
            ),
          ),
        );
      });

      // `DioException.response` is a `Response<dynamic>`, so an interceptor
      // can reject with a body that was never the String this class asked for.
      // That must stay inside the typed taxonomy rather than becoming a raw
      // TypeError out of the branch meant to rescue it.
      test('an already-decoded rejected body is still interpreted', () async {
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) => handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response<dynamic>(
                    data: _validIdentityJson(),
                    statusCode: 200,
                    requestOptions: options,
                  ),
                ),
              ),
            ),
          );

        final identity = await clientOver(dio).fetchIdentity(_kServerUrl);
        expect(identity.serverId, _kServerId);
      });

      test('a rejected body of an unusable type is invalid', () async {
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) => handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response<dynamic>(
                    data: 42,
                    statusCode: 200,
                    requestOptions: options,
                  ),
                ),
              ),
            ),
          );

        await expectLater(
          () => clientOver(dio).fetchIdentity(_kServerUrl),
          throwsA(isA<WellKnownInvalidResponseException>()),
        );
      });

      // The `Response<String>` switch bypasses dio's BackgroundTransformer,
      // which offloads jsonDecode above 50 KB. This client reproduces that
      // threshold itself, and the URL here is user-typed during onboarding —
      // an unbounded body from a server we have not yet identified as ours.
      test(
        'a document over the 50 KB isolate threshold still parses',
        () async {
          final padded = _validIdentityJson()
            ..['name'] = 'Board Games Empire ${'padding' * 9000}';
          final body = jsonEncode(padded);
          expect(body.codeUnits.length, greaterThan(50 * 1024));

          final identity = await clientOver(
            cannedDio(body: body, statusCode: 200),
          ).fetchIdentity(_kServerUrl);

          expect(identity.serverId, _kServerId);
        },
      );

      test('a genuine transport failure is still unreachable', () async {
        final client = clientOver(
          unreachableDio(DioExceptionType.connectionError),
        );

        await expectLater(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(isA<WellKnownUnreachableException>()),
        );
      });

      test('a valid document still parses through the real pipeline', () async {
        final client = clientOver(
          cannedDio(body: jsonEncode(_validIdentityJson()), statusCode: 200),
        );

        final identity = await client.fetchIdentity(_kServerUrl);
        expect(identity.serverId, _kServerId);
      });
    });

    group('WellKnownException base', () {
      test('all exception types are subtypes of WellKnownException', () {
        const unreachable = WellKnownUnreachableException(
          serverUrl: 'https://x.com',
          message: 'timeout',
        );
        const notFound = WellKnownNotFoundException(
          serverUrl: 'https://x.com',
          message: '404',
        );
        const invalid = WellKnownInvalidResponseException(
          serverUrl: 'https://x.com',
          message: 'bad body',
        );

        expect(unreachable, isA<WellKnownException>());
        expect(notFound, isA<WellKnownException>());
        expect(invalid, isA<WellKnownException>());
      });
    });
  });
}
