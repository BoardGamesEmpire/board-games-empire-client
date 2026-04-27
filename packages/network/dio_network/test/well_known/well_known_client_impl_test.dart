import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import 'package:dio_network/dio_network.dart';

class MockDio extends Mock implements Dio {}

// Minimal valid identity JSON matching the BgeDiscoveryDto wire format.
const _kServerId = '550e8400-e29b-41d4-a716-446655440000';
const _kServerUrl = 'https://api.example.com';

Map<String, dynamic> _validIdentityJson({String? serverId}) => {
  'bge_server_id': serverId ?? _kServerId,
  'issuer': _kServerUrl,
  'device_authorization_endpoint': '$_kServerUrl/api/auth/device',
  'bge_auth_base_url': '$_kServerUrl/api/auth',
  'bge_session_endpoint': '$_kServerUrl/api/auth/get-session',
  'bge_sign_out_endpoint': '$_kServerUrl/api/auth/sign-out',
  'bge_passkey_supported': true,
  'bge_two_factor_supported': true,
  'bge_anonymous_auth_supported': true,
  'strategies': <dynamic>[],
};

Response<Map<String, dynamic>> _makeResponse(
  Map<String, dynamic> data, {
  int statusCode = 200,
}) => Response(
  data: data,
  statusCode: statusCode,
  requestOptions: RequestOptions(path: ''),
);

Response<Map<String, dynamic>> _makeEmptyResponse({int statusCode = 200}) =>
    Response(
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
        when(
          () => mockDio.get<Map<String, dynamic>>(
            '$_kServerUrl/.well-known/bge-identity',
          ),
        ).thenAnswer((_) async => _makeResponse(_validIdentityJson()));

        await client.fetchIdentity(_kServerUrl);

        verify(
          () => mockDio.get<Map<String, dynamic>>(
            '$_kServerUrl/.well-known/bge-identity',
          ),
        ).called(1);
      });

      test('strips trailing slash before appending well-known path', () async {
        when(
          () => mockDio.get<Map<String, dynamic>>(
            '$_kServerUrl/.well-known/bge-identity',
          ),
        ).thenAnswer((_) async => _makeResponse(_validIdentityJson()));

        await client.fetchIdentity('$_kServerUrl/');

        verify(
          () => mockDio.get<Map<String, dynamic>>(
            '$_kServerUrl/.well-known/bge-identity',
          ),
        ).called(1);
      });
    });

    group('happy path', () {
      setUp(() {
        when(
          () => mockDio.get<Map<String, dynamic>>(any()),
        ).thenAnswer((_) async => _makeResponse(_validIdentityJson()));
      });

      test('returns ServerIdentity on 200 with valid body', () async {
        final identity = await client.fetchIdentity(_kServerUrl);

        expect(identity, isA<ServerIdentity>());
        expect(identity.serverId, _kServerId);
        expect(identity.issuer, _kServerUrl);
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
            'sign_in_endpoint': '$_kServerUrl/api/auth/sign-in/email',
            'sign_up_endpoint': '$_kServerUrl/api/auth/sign-up/email',
          },
        ];
        when(
          () => mockDio.get<Map<String, dynamic>>(any()),
        ).thenAnswer((_) async => _makeResponse(json));

        final identity = await client.fetchIdentity(_kServerUrl);

        expect(identity.strategies, hasLength(1));
        expect(identity.strategies.first, isA<EmailAndPasswordStrategy>());
        expect(identity.hasEmailAndPassword, isTrue);
      });
    });

    group('404 response', () {
      setUp(() {
        when(
          () => mockDio.get<Map<String, dynamic>>(any()),
        ).thenAnswer((_) async => _makeEmptyResponse(statusCode: 404));
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
        when(
          () => mockDio.get<Map<String, dynamic>>(any()),
        ).thenAnswer((_) async => _makeEmptyResponse(statusCode: 500));

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
        when(
          () => mockDio.get<Map<String, dynamic>>(any()),
        ).thenAnswer((_) async => _makeEmptyResponse(statusCode: 401));

        expect(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(isA<WellKnownInvalidResponseException>()),
        );
      });
    });

    group('empty body on 200', () {
      test('throws WellKnownInvalidResponseException', () async {
        when(
          () => mockDio.get<Map<String, dynamic>>(any()),
        ).thenAnswer((_) async => _makeEmptyResponse(statusCode: 200));

        expect(
          () => client.fetchIdentity(_kServerUrl),
          throwsA(isA<WellKnownInvalidResponseException>()),
        );
      });
    });

    group('network failures', () {
      test('throws WellKnownUnreachableException on connection timeout', () {
        when(() => mockDio.get<Map<String, dynamic>>(any())).thenThrow(
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
        when(() => mockDio.get<Map<String, dynamic>>(any())).thenThrow(
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
          when(
            () => mockDio.get<Map<String, dynamic>>(any()),
          ).thenThrow(dioError);

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
          when(() => mockDio.get<Map<String, dynamic>>(any())).thenAnswer(
            (_) async => _makeResponse({'bge_server_id': 'only-id'}),
          );

          expect(
            () => client.fetchIdentity(_kServerUrl),
            throwsA(isA<WellKnownInvalidResponseException>()),
          );
        },
      );
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
