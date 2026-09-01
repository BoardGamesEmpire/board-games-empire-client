import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:network_interface/network_interface.dart';

import 'package:dio_network/dio_network.dart';

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

Response<Map<String, dynamic>> _resp(
  Map<String, dynamic>? data, {
  int? statusCode = 201,
}) => Response(
  data: data,
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

  void stubPost(Response<Map<String, dynamic>> response) {
    when(
      () => mockDio.post<Map<String, dynamic>>(any(), data: any(named: 'data')),
    ).thenAnswer((_) async => response);
  }

  void stubPostThrows(Object error) {
    when(
      () => mockDio.post<Map<String, dynamic>>(any(), data: any(named: 'data')),
    ).thenThrow(error);
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
          () => mockDio.post<Map<String, dynamic>>(
            '/api/households',
            data: any(named: 'data'),
          ),
        ).called(1);
      });
    });

    group('request body', () {
      Map<String, dynamic> capturedBody() =>
          verify(
                () => mockDio.post<Map<String, dynamic>>(
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

      test(
        "with the API's own error envelope — Nest's route-not-found carries "
        'it too, so the envelope does not license a rejection here',
        () {
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
        },
      );

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
