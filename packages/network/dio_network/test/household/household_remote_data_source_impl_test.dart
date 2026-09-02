import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:network_interface/network_interface.dart';

import 'package:dio_network/dio_network.dart';

import '../support/canned_adapter.dart';

class MockDio extends Mock implements Dio {}

Map<String, dynamic> _householdJson({
  String id = 'hh_server_1',
  String name = 'Game Night HQ',
  String? description,
  String? image,
  String? deletedAt,
}) => {
  'id': id,
  'name': name,
  'description': description,
  'image': image,
  // Fields the server sends that the domain model doesn't carry:
  'languageTagId': null,
  'createdById': 'user-abc',
  'visibility': 'Private',
  'deletedAt': deletedAt,
  'createdAt': '2026-01-15T10:30:00.000Z',
  'updatedAt': '2026-01-15T10:30:00.000Z',
};

Map<String, dynamic> _createEnvelope(Map<String, dynamic> household) => {
  'message': 'success.household.created',
  'household': household,
};

Response<String> _resp(Map<String, dynamic>? data, {int? statusCode = 201}) =>
    Response(
      data: data == null ? null : jsonEncode(data),
      statusCode: statusCode,
      requestOptions: RequestOptions(path: '/api/households'),
    );

DioException _dioError(DioExceptionType type, {Response<dynamic>? response}) =>
    DioException(
      type: type,
      requestOptions: RequestOptions(path: '/api/households'),
      response: response,
    );

void main() {
  late MockDio mockDio;
  late HouseholdRemoteDataSourceImpl remote;

  void stubPost(Response<String> response) {
    when(() => mockDio.post<String>(any(), data: any(named: 'data')))
        .thenAnswer((_) async => response);
  }

  void stubPostThrows(Object error) {
    when(() => mockDio.post<String>(any(), data: any(named: 'data')))
        .thenThrow(error);
  }

  setUp(() {
    mockDio = MockDio();
    remote = HouseholdRemoteDataSourceImpl(mockDio);
  });

  group('HouseholdRemoteDataSourceImpl.createHousehold', () {
    group('happy path', () {
      test('maps the returned household on 201', () async {
        stubPost(
          _resp(
            _createEnvelope(
              _householdJson(description: 'Where we play', image: 'x.png'),
            ),
          ),
        );

        final household = await remote.createHousehold(name: 'Game Night HQ');

        expect(household.id, 'hh_server_1');
        expect(household.name, 'Game Night HQ');
        expect(household.description, 'Where we play');
        expect(household.image, 'x.png');
        expect(household.isDeleted, isFalse);
      });

      test('accepts a 200 as success too', () async {
        stubPost(_resp(_createEnvelope(_householdJson()), statusCode: 200));

        final household = await remote.createHousehold(name: 'Game Night HQ');
        expect(household.id, 'hh_server_1');
      });

      test('server-confirmed row has both sync flags false', () async {
        stubPost(_resp(_createEnvelope(_householdJson())));

        final household = await remote.createHousehold(name: 'Game Night HQ');
        expect(household.isDirty, isFalse);
        expect(household.isLocalOnly, isFalse);
      });

      test('null description / image map to null', () async {
        stubPost(_resp(_createEnvelope(_householdJson())));

        final household = await remote.createHousehold(name: 'Game Night HQ');
        expect(household.description, isNull);
        expect(household.image, isNull);
      });

      test('hits the relative /api/households path', () async {
        stubPost(_resp(_createEnvelope(_householdJson())));

        await remote.createHousehold(name: 'Game Night HQ');

        verify(
          () =>
              mockDio.post<String>('/api/households', data: any(named: 'data')),
        ).called(1);
      });
    });

    group('request body', () {
      Map<String, dynamic> capturedBody() =>
          verify(
                () => mockDio.post<String>(
                  any(),
                  data: captureAny(named: 'data'),
                ),
              ).captured.single
              as Map<String, dynamic>;

      test('sends only name when optionals are omitted', () async {
        stubPost(_resp(_createEnvelope(_householdJson())));

        await remote.createHousehold(name: 'Game Night HQ');

        final body = capturedBody();
        expect(body, equals({'name': 'Game Night HQ'}));
      });

      test('includes optionals when provided', () async {
        stubPost(_resp(_createEnvelope(_householdJson())));

        await remote.createHousehold(
          name: 'Game Night HQ',
          description: 'Where we play',
          image: 'x.png',
          language: 'pt-BR',
          visibility: 'Friends',
        );

        final body = capturedBody();
        expect(body['name'], 'Game Night HQ');
        expect(body['description'], 'Where we play');
        expect(body['image'], 'x.png');
        expect(body['language'], 'pt-BR');
        expect(body['visibility'], 'Friends');
      });
    });

    group('transient failures (retryable)', () {
      test('connection error', () {
        stubPostThrows(_dioError(DioExceptionType.connectionError));
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(isA<HouseholdRemoteTransientException>()),
        );
      });

      test('connection timeout', () {
        stubPostThrows(_dioError(DioExceptionType.connectionTimeout));
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(isA<HouseholdRemoteTransientException>()),
        );
      });

      test('500 via DioException response', () {
        stubPostThrows(
          _dioError(
            DioExceptionType.badResponse,
            response: _resp(null, statusCode: 500),
          ),
        );
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(
            isA<HouseholdRemoteTransientException>().having(
              (e) => e.statusCode,
              'statusCode',
              500,
            ),
          ),
        );
      });

      test('401, 408, 429 are transient', () async {
        for (final status in [401, 408, 429]) {
          stubPostThrows(
            _dioError(
              DioExceptionType.badResponse,
              response: _resp(null, statusCode: status),
            ),
          );
          expect(
            () => remote.createHousehold(name: 'x'),
            throwsA(isA<HouseholdRemoteTransientException>()),
            reason: 'status $status should be transient',
          );
        }
      });

      test('no response status is transient', () {
        stubPostThrows(_dioError(DioExceptionType.unknown));
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(isA<HouseholdRemoteTransientException>()),
        );
      });

      test('a 2xx response with a null status is transient', () {
        stubPost(_resp(_createEnvelope(_householdJson()), statusCode: null));
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(isA<HouseholdRemoteTransientException>()),
        );
      });
    });

    // ── #297: a 404 on the create route is never a rejection ────────────
    //
    // `/api/households` is a fixed route: it exists in every deployed
    // server, so a 404 on it means the request did not reach the household
    // module — a misrouted prefix, a partial deploy, a proxy answering for
    // it. Classifying that permanent is a data-loss shape once #121 owns
    // cancel semantics: the queue entry is cancelled and the user's
    // household is discarded, for a failure a retry would have survived.

    group('404 on the create route is transient (#297)', () {
      test('with no body — a proxy or gateway answered', () {
        stubPostThrows(
          _dioError(
            DioExceptionType.badResponse,
            response: _resp(null, statusCode: 404),
          ),
        );
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(
            isA<HouseholdRemoteTransientException>().having(
              (e) => e.statusCode,
              'statusCode',
              404,
            ),
          ),
        );
      });

      test("with the API's own error envelope — Nest's route-not-found carries "
          'it too, so the envelope does not license a rejection here', () {
        stubPostThrows(
          _dioError(
            DioExceptionType.badResponse,
            response: _resp({
              'statusCode': 404,
              'message': 'Cannot POST /api/households',
              'error': 'Not Found',
            }, statusCode: 404),
          ),
        );
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(isA<HouseholdRemoteTransientException>()),
        );
      });

      test('on a non-exception 404 response body', () {
        stubPost(_resp(null, statusCode: 404));
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(isA<HouseholdRemoteTransientException>()),
        );
      });

      test('409 conflict stays permanent — only 404 changed', () {
        stubPostThrows(
          _dioError(
            DioExceptionType.badResponse,
            response: _resp(null, statusCode: 409),
          ),
        );
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(isA<HouseholdRemotePermanentException>()),
        );
      });
    });

    group('permanent failures (non-retryable)', () {
      test('400 validation', () {
        stubPostThrows(
          _dioError(
            DioExceptionType.badResponse,
            response: _resp(null, statusCode: 400),
          ),
        );
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(
            isA<HouseholdRemotePermanentException>().having(
              (e) => e.statusCode,
              'statusCode',
              400,
            ),
          ),
        );
      });

      test('403 forbidden', () {
        stubPostThrows(
          _dioError(
            DioExceptionType.badResponse,
            response: _resp(null, statusCode: 403),
          ),
        );
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(isA<HouseholdRemotePermanentException>()),
        );
      });

      test('2xx with a body missing "household" is permanent', () {
        stubPost(_resp({'message': 'ok'}));
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(isA<HouseholdRemotePermanentException>()),
        );
      });

      test('2xx with an unparseable household is permanent', () {
        // Missing required createdAt -> mapping throws -> permanent.
        stubPost(
          _resp({
            'household': {'id': 'hh_1', 'name': 'x'},
          }),
        );
        expect(
          () => remote.createHousehold(name: 'x'),
          throwsA(isA<HouseholdRemotePermanentException>()),
        );
      });
    });

    // These run against a **real** Dio with a canned adapter, not `MockDio`.
    // The defect in #265 lives inside Dio's own body cast, which a stubbed
    // `Dio` never performs — see `test/support/canned_adapter.dart`.
    //
    // `permissiveStatus: true` mirrors production: `DioFactory` builds the
    // per-server Dio with `validateStatus: (_) => true`, so every status comes
    // back as a Response and the cast runs on all of them — which is why the
    // misclassification here is not limited to 2xx.
    group(
      'an unparseable body classifies by status, not as transport (#265)',
      () {
        HouseholdRemoteDataSource remoteOver(Dio dio) =>
            HouseholdRemoteDataSourceImpl(dio);

        test('2xx with a String body is permanent', () async {
          final remote = remoteOver(
            cannedDio(
              body: '<!doctype html><html>Captive portal</html>',
              statusCode: 200,
              contentType: 'text/html',
            ),
          );

          await expectLater(
            () => remote.createHousehold(name: 'HQ'),
            throwsA(isA<HouseholdRemotePermanentException>()),
          );
        });

        test('2xx with a bare JSON array is permanent', () async {
          final remote = remoteOver(
            cannedDio(body: '[{"id": "hh_1"}]', statusCode: 201),
          );

          await expectLater(
            () => remote.createHousehold(name: 'HQ'),
            throwsA(isA<HouseholdRemotePermanentException>()),
          );
        });

        // The status still decides. A 400 is a rejection whatever the body is,
        // and must not be softened to transient just because a proxy replaced
        // the envelope with an error page.
        test(
          'a non-2xx with a non-JSON body still classifies by status',
          () async {
            final remote = remoteOver(
              cannedDio(
                body: '<html>Bad Request</html>',
                statusCode: 400,
                contentType: 'text/html',
              ),
            );

            await expectLater(
              () => remote.createHousehold(name: 'HQ'),
              throwsA(
                isA<HouseholdRemotePermanentException>().having(
                  (e) => e.statusCode,
                  'statusCode',
                  400,
                ),
              ),
            );
          },
        );

        // #297's rule has to survive reaching the classifier by this new route:
        // a 404 is transient whether its body parses or not.
        test('a 404 with an HTML body is still transient (#297)', () async {
          final remote = remoteOver(
            cannedDio(
              body: '<html>Not Found</html>',
              statusCode: 404,
              contentType: 'text/html',
            ),
          );

          await expectLater(
            () => remote.createHousehold(name: 'HQ'),
            throwsA(
              isA<HouseholdRemoteTransientException>().having(
                (e) => e.statusCode,
                'statusCode',
                404,
              ),
            ),
          );
        });

        test('a 5xx with an HTML body is transient', () async {
          final remote = remoteOver(
            cannedDio(
              body: '<html>Bad Gateway</html>',
              statusCode: 502,
              contentType: 'text/html',
            ),
          );

          await expectLater(
            () => remote.createHousehold(name: 'HQ'),
            throwsA(isA<HouseholdRemoteTransientException>()),
          );
        });

        // An injected Dio need not carry the factory's permissive
        // `validateStatus`, in which case a non-2xx arrives as a thrown
        // `badResponse`. The status must still decide.
        test('a thrown badResponse still classifies by status', () async {
          final remote = remoteOver(
            cannedDio(
              body: '<html>Forbidden</html>',
              statusCode: 403,
              contentType: 'text/html',
              permissiveStatus: false,
            ),
          );

          await expectLater(
            () => remote.createHousehold(name: 'HQ'),
            throwsA(isA<HouseholdRemotePermanentException>()),
          );
        });

        // Dio decodes on content type, not on what the body turns out to be, so
        // an HTML page served as `application/json` and a truncated JSON body
        // both throw a `FormatException` out of the transformer — losing the
        // status exactly like the cast did.
        test(
          'a 2xx HTML body under a JSON content type is permanent',
          () async {
            final remote = remoteOver(
              cannedDio(body: '<html>Portal</html>', statusCode: 200),
            );

            await expectLater(
              () => remote.createHousehold(name: 'HQ'),
              throwsA(isA<HouseholdRemotePermanentException>()),
            );
          },
        );

        test(
          'a 400 under a JSON content type still classifies by status',
          () async {
            final remote = remoteOver(
              cannedDio(body: '<html>Bad Request</html>', statusCode: 400),
            );

            await expectLater(
              () => remote.createHousehold(name: 'HQ'),
              throwsA(
                isA<HouseholdRemotePermanentException>().having(
                  (e) => e.statusCode,
                  'statusCode',
                  400,
                ),
              ),
            );
          },
        );

        test('a truncated JSON 2xx is permanent', () async {
          final remote = remoteOver(
            cannedDio(body: '{"household": {"id"', statusCode: 201),
          );

          await expectLater(
            () => remote.createHousehold(name: 'HQ'),
            throwsA(isA<HouseholdRemotePermanentException>()),
          );
        });

        test(
          'a truncated JSON 404 is still transient with its status',
          () async {
            final remote = remoteOver(
              cannedDio(body: '{"message"', statusCode: 404),
            );

            await expectLater(
              () => remote.createHousehold(name: 'HQ'),
              throwsA(
                isA<HouseholdRemoteTransientException>().having(
                  (e) => e.statusCode,
                  'statusCode',
                  404,
                ),
              ),
            );
          },
        );

        // A 3xx only reaches the classifier because the per-server Dio sets
        // `validateStatus: (_) => true`; it carries no rejection semantics, so
        // it is transient. Asked for by #182 and the one status shape the
        // household suite had no case for.
        test('a 302 carries no rejection semantics and is transient', () async {
          final remote = remoteOver(
            cannedDio(
              body: '<html>Moved</html>',
              statusCode: 302,
              contentType: 'text/html',
            ),
          );

          await expectLater(
            () => remote.createHousehold(name: 'HQ'),
            throwsA(
              isA<HouseholdRemoteTransientException>().having(
                (e) => e.statusCode,
                'statusCode',
                302,
              ),
            ),
          );
        });

        test('a valid envelope still maps through the real pipeline', () async {
          final remote = remoteOver(
            cannedDio(
              body: jsonEncode(_createEnvelope(_householdJson())),
              statusCode: 201,
            ),
          );

          final household = await remote.createHousehold(name: 'HQ');
          expect(household.id, 'hh_server_1');
        });
      },
    );

    group('exception taxonomy', () {
      test('both concrete types are HouseholdRemoteException', () {
        const transient = HouseholdRemoteTransientException('t');
        const permanent = HouseholdRemotePermanentException('p');
        expect(transient, isA<HouseholdRemoteException>());
        expect(permanent, isA<HouseholdRemoteException>());
      });
    });
  });
}
