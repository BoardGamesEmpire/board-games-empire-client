import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import 'package:dio_network/dio_network.dart';

class MockDio extends Mock implements Dio {}

const _path = '/api/game-collections';

/// A full server payload — every field the backend `GameCollectionDto` carries,
/// including the ones the domain model has no home for.
Map<String, dynamic> _entryJson({
  String id = 'gc_server_1',
  String userId = 'user-abc',
  String platformGameId = 'pg_1',
  String medium = 'Physical',
  String? releaseId,
  int quantity = 2,
  int? rating = 8,
  int? playCount = 5,
  bool? playAgain = true,
  bool? favorite = true,
  String? comment = 'Great with four',
  String? lastPlayed = '2026-02-01T18:00:00.000Z',
  String? lastUpdated = '2026-02-02T09:00:00.000Z',
  String? deletedAt,
  String? deleteReason,
}) => {
  'id': id,
  'userId': userId,
  'platformGameId': platformGameId,
  'medium': medium,
  'releaseId': releaseId,
  'quantity': quantity,
  'rating': rating,
  'playCount': playCount,
  'playAgain': playAgain,
  'favorite': favorite,
  'comment': comment,
  'lastPlayed': lastPlayed,
  'lastUpdated': lastUpdated,
  'deletedAt': deletedAt,
  'deleteReason': deleteReason,
  'createdAt': '2026-01-15T10:30:00.000Z',
  'updatedAt': '2026-02-02T09:00:00.000Z',
  // Fields the server sends that the domain model doesn't carry (#253 D5):
  'visibility': 'Private',
  'platformGame': {
    'id': 'pg_1',
    'image': 'pg.png',
    'thumbnail': 'pg_thumb.png',
    'platform': {'id': 'plat_1', 'name': 'Tabletop', 'slug': 'tabletop'},
    'game': {
      'id': 'g_1',
      'title': 'Brass: Birmingham',
      'subtitle': null,
      'image': 'g.png',
      'thumbnail': 'g_thumb.png',
    },
  },
  'release': {'id': 'rel_1', 'editionName': 'Deluxe', 'releaseYear': 2018},
};

Response<Object?> _resp(Map<String, dynamic>? data, {int? statusCode = 200}) =>
    Response<Object?>(
      data: data,
      statusCode: statusCode,
      requestOptions: RequestOptions(path: _path),
    );

/// A response whose body is deliberately not a JSON object.
Response<Object?> _resp2(Object? data, {int? statusCode = 200}) =>
    Response<Object?>(
      data: data,
      statusCode: statusCode,
      requestOptions: RequestOptions(path: _path),
    );

/// The backend's global error envelope — what every application
/// `HttpException` renders as. Its presence is what tells the data source the
/// application answered rather than a proxy in front of it.
Map<String, dynamic> _errorEnvelope(int status) => {
  'statusCode': status,
  'message': 'errors.game_collection.not_found',
  'error': 'Not Found',
};

DioException _dioError(DioExceptionType type, {int? status, Object? body}) =>
    DioException(
      type: type,
      requestOptions: RequestOptions(path: _path),
      response: status == null
          ? null
          : _resp2(body ?? _errorEnvelope(status), statusCode: status),
    );

void main() {
  late MockDio mockDio;
  late GameCollectionRemoteDataSourceImpl remote;

  setUp(() {
    mockDio = MockDio();
    remote = GameCollectionRemoteDataSourceImpl(mockDio);
  });

  void stubGet(Response<Object?> response) {
    when(
      () => mockDio.get<Object?>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) async => response);
  }

  void stubGetThrows(Object error) {
    when(
      () => mockDio.get<Object?>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenThrow(error);
  }

  void stubPost(Response<Object?> response) {
    when(() => mockDio.post<Object?>(any(), data: any(named: 'data')))
        .thenAnswer((_) async => response);
  }

  void stubPostThrows(Object error) {
    when(() => mockDio.post<Object?>(any(), data: any(named: 'data')))
        .thenThrow(error);
  }

  void stubPatch(Response<Object?> response) {
    when(() => mockDio.patch<Object?>(any(), data: any(named: 'data')))
        .thenAnswer((_) async => response);
  }

  void stubPatchThrows(Object error) {
    when(() => mockDio.patch<Object?>(any(), data: any(named: 'data')))
        .thenThrow(error);
  }

  void stubDelete(Response<Object?> response) {
    when(
      () => mockDio.delete<Object?>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) async => response);
  }

  void stubDeleteThrows(Object error) {
    when(
      () => mockDio.delete<Object?>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenThrow(error);
  }

  Map<String, dynamic> capturedQuery() =>
      verify(
            () => mockDio.get<Object?>(
              any(),
              queryParameters: captureAny(named: 'queryParameters'),
            ),
          ).captured.single
          as Map<String, dynamic>;

  group('response mapping', () {
    test('maps every field the domain model carries', () async {
      stubGet(_resp({'collection': _entryJson(releaseId: 'rel_1')}));

      final entry = await remote.fetchEntry('gc_server_1');

      expect(entry.id, 'gc_server_1');
      expect(entry.userId, 'user-abc');
      expect(entry.platformGameId, 'pg_1');
      expect(entry.medium, GameMedium.physical);
      expect(entry.releaseId, 'rel_1');
      expect(entry.quantity, 2);
      expect(entry.rating, 8);
      expect(entry.playCount, 5);
      expect(entry.playAgain, isTrue);
      expect(entry.favorite, isTrue);
      expect(entry.comment, 'Great with four');
      expect(entry.lastPlayed, DateTime.parse('2026-02-01T18:00:00.000Z'));
      expect(entry.lastUpdated, DateTime.parse('2026-02-02T09:00:00.000Z'));
      expect(entry.createdAt, DateTime.parse('2026-01-15T10:30:00.000Z'));
      expect(entry.updatedAt, DateTime.parse('2026-02-02T09:00:00.000Z'));
      expect(entry.deletedAt, isNull);
      expect(entry.isDeleted, isFalse);
    });

    test('a server-confirmed row has both sync flags false', () async {
      stubGet(_resp({'collection': _entryJson()}));

      final entry = await remote.fetchEntry('gc_server_1');

      expect(entry.isDirty, isFalse);
      expect(entry.isLocalOnly, isFalse);
    });

    test('maps a Digital medium', () async {
      stubGet(_resp({'collection': _entryJson(medium: 'Digital')}));

      final entry = await remote.fetchEntry('gc_server_1');
      expect(entry.medium, GameMedium.digital);
    });

    test('an unknown medium is a permanent failure, not a crash', () {
      stubGet(_resp({'collection': _entryJson(medium: 'Holographic')}));

      expect(
        () => remote.fetchEntry('gc_server_1'),
        throwsA(isA<GameCollectionRemotePermanentException>()),
      );
    });

    test('nullable fields map to null', () async {
      stubGet(
        _resp({
          'collection': _entryJson(
            releaseId: null,
            rating: null,
            playCount: null,
            playAgain: null,
            favorite: null,
            comment: null,
            lastPlayed: null,
            lastUpdated: null,
          ),
        }),
      );

      final entry = await remote.fetchEntry('gc_server_1');

      expect(entry.releaseId, isNull);
      expect(entry.rating, isNull);
      expect(entry.playCount, isNull);
      expect(entry.playAgain, isNull);
      expect(entry.favorite, isNull);
      expect(entry.comment, isNull);
      expect(entry.lastPlayed, isNull);
      expect(entry.lastUpdated, isNull);
    });

    test(
      'a tombstoned entry maps deletedAt (the removal confirmation)',
      () async {
        stubGet(
          _resp({
            'collection': _entryJson(
              deletedAt: '2026-03-01T12:00:00.000Z',
              deleteReason: 'Sold',
            ),
          }),
        );

        final entry = await remote.fetchEntry('gc_server_1');

        expect(entry.deletedAt, DateTime.parse('2026-03-01T12:00:00.000Z'));
        expect(entry.isDeleted, isTrue);
      },
    );
  });

  group('fetchCollectionPage', () {
    test('maps a page of entries', () async {
      stubGet(
        _resp({
          'collections': [
            _entryJson(),
            _entryJson(id: 'gc_server_2', medium: 'Digital'),
          ],
        }),
      );

      final page = await remote.fetchCollectionPage(limit: 2);

      expect(page, hasLength(2));
      expect(page.first.id, 'gc_server_1');
      expect(page.last.medium, GameMedium.digital);
    });

    test('an empty page maps to an empty list', () async {
      stubGet(_resp({'collections': <Map<String, dynamic>>[]}));

      expect(await remote.fetchCollectionPage(), isEmpty);
    });

    test('hits the relative collection path', () async {
      stubGet(_resp({'collections': <Map<String, dynamic>>[]}));

      await remote.fetchCollectionPage();

      verify(
        () => mockDio.get<Object?>(
          _path,
          queryParameters: any(named: 'queryParameters'),
        ),
      ).called(1);
    });

    group('query parameters', () {
      test('sends only paging when no filters are supplied', () async {
        stubGet(_resp({'collections': <Map<String, dynamic>>[]}));

        await remote.fetchCollectionPage(offset: 40, limit: 20);

        expect(capturedQuery(), equals({'offset': 40, 'limit': 20}));
      });

      test(
        'omits the tombstone flags when they are at their defaults',
        () async {
          stubGet(_resp({'collections': <Map<String, dynamic>>[]}));

          await remote.fetchCollectionPage();

          final query = capturedQuery();
          expect(query.containsKey('includeDeleted'), isFalse);
          expect(query.containsKey('deletedOnly'), isFalse);
          expect(query.containsKey('favorite'), isFalse);
          expect(query.containsKey('medium'), isFalse);
          expect(query.containsKey('updatedSince'), isFalse);
        },
      );

      test('sends every filter when supplied', () async {
        stubGet(_resp({'collections': <Map<String, dynamic>>[]}));

        await remote.fetchCollectionPage(
          includeDeleted: true,
          deletedOnly: true,
          medium: GameMedium.digital,
          favorite: false,
          updatedSince: DateTime.utc(2026, 2, 1, 18),
        );

        final query = capturedQuery();
        expect(query['includeDeleted'], isTrue);
        expect(query['deletedOnly'], isTrue);
        expect(query['medium'], 'Digital');
        expect(query['favorite'], isFalse);
        expect(query['updatedSince'], '2026-02-01T18:00:00.000Z');
      });

      test('sends updatedSince as UTC even when given a local time', () async {
        stubGet(_resp({'collections': <Map<String, dynamic>>[]}));

        final local = DateTime.utc(2026, 2, 1, 18).toLocal();
        await remote.fetchCollectionPage(updatedSince: local);

        expect(capturedQuery()['updatedSince'], '2026-02-01T18:00:00.000Z');
      });
    });

    group('paging bounds are rejected before the request', () {
      test('a limit above the backend cap throws ArgumentError', () {
        expect(
          () => remote.fetchCollectionPage(
            limit: GameCollectionRemoteDataSource.maxPageSize + 1,
          ),
          throwsArgumentError,
        );
        verifyNever(
          () => mockDio.get<Object?>(
            any(),
            queryParameters: any(named: 'queryParameters'),
          ),
        );
      });

      test('a non-positive limit throws ArgumentError', () {
        expect(() => remote.fetchCollectionPage(limit: 0), throwsArgumentError);
        expect(
          () => remote.fetchCollectionPage(limit: -1),
          throwsArgumentError,
        );
      });

      test('a negative offset throws ArgumentError', () {
        expect(
          () => remote.fetchCollectionPage(offset: -1),
          throwsArgumentError,
        );
      });

      test('an offset above the backend ceiling throws ArgumentError', () {
        expect(
          () => remote.fetchCollectionPage(
            offset: GameCollectionRemoteDataSource.maxOffset + 1,
          ),
          throwsArgumentError,
        );
      });

      // The literal 100 below is a canary, not an oversight: asserting against
      // `maxPageSize` on both sides would only prove we send what we said we
      // send. Pinning the value means a change to the constant fails here and
      // forces a look at whether the backend's `@Max` moved with it — the drift
      // nothing else detects (#263). The out-of-range cases above stay relative
      // (`maxPageSize + 1`), because their subject is the boundary, not its
      // value.
      test('the cap itself is accepted', () async {
        stubGet(_resp({'collections': <Map<String, dynamic>>[]}));

        await remote.fetchCollectionPage(
          limit: GameCollectionRemoteDataSource.maxPageSize,
          offset: GameCollectionRemoteDataSource.maxOffset,
        );

        expect(capturedQuery()['limit'], 100);
      });
    });

    test('a 2xx whose body is not a JSON object is permanent, not transient', () {
      // Dio would cast the body to Map itself if we asked it for a typed
      // Response, and the TypeError would surface as a status-less transient
      // failure that retries forever. A captive-portal HTML page served with a
      // 200 is the realistic shape of this.
      stubGet(_resp2('<html>Sign in to continue</html>'));
      expect(
        () => remote.fetchCollectionPage(),
        throwsA(
          isA<GameCollectionRemotePermanentException>()
              .having((e) => e.statusCode, 'statusCode', 200)
              .having((e) => e.isRetryable, 'isRetryable', isFalse),
        ),
      );
    });

    test('a 2xx whose body is a bare array is permanent', () {
      stubGet(_resp2([<String, dynamic>{}]));
      expect(
        () => remote.fetchCollectionPage(),
        throwsA(isA<GameCollectionRemotePermanentException>()),
      );
    });

    test('a 2xx with a null body is permanent', () {
      stubGet(_resp2(null));
      expect(
        () => remote.fetchCollectionPage(),
        throwsA(isA<GameCollectionRemotePermanentException>()),
      );
    });

    test('a 2xx body without a "collections" array is permanent', () {
      stubGet(_resp({'message': 'ok'}));
      expect(
        () => remote.fetchCollectionPage(),
        throwsA(isA<GameCollectionRemotePermanentException>()),
      );
    });

    test('a "collections" array with a non-object element is permanent', () {
      stubGet(
        _resp({
          'collections': ['nope'],
        }),
      );
      expect(
        () => remote.fetchCollectionPage(),
        throwsA(isA<GameCollectionRemotePermanentException>()),
      );
    });

    test('a 404 on the list is transient — the route was never reached', () {
      // An authenticated user's collection is never absent: an empty one is a
      // 200 with an empty array. A 404 here is a routing/deployment fault,
      // fixed server-side, so a hydrate must be able to retry it.
      stubGetThrows(_dioError(DioExceptionType.badResponse, status: 404));
      expect(
        () => remote.fetchCollectionPage(),
        throwsA(
          isA<GameCollectionRemoteTransientException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.isRetryable, 'isRetryable', isTrue),
        ),
      );
    });

    test('a 404 on the list stays transient even with the API error envelope — '
        'the route is simply not registered', () {
      stubGetThrows(_dioError(DioExceptionType.badResponse, status: 404));
      expect(
        () => remote.fetchCollectionPage(),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });

    test('a 404 on the list is neither of the row-level 404 types', () {
      stubGetThrows(_dioError(DioExceptionType.badResponse, status: 404));
      expect(
        () => remote.fetchCollectionPage(),
        throwsA(
          isNot(
            anyOf(
              isA<GameCollectionNotFoundException>(),
              isA<GameCollectionAlreadyRemovedException>(),
            ),
          ),
        ),
      );
    });
  });

  group('fetchEntry', () {
    test('hits the id path', () async {
      stubGet(_resp({'collection': _entryJson()}));

      await remote.fetchEntry('gc_server_1');

      verify(
        () => mockDio.get<Object?>(
          '$_path/gc_server_1',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).called(1);
    });

    test('a 2xx body without a "collection" object is permanent', () {
      stubGet(_resp({'message': 'ok'}));
      expect(
        () => remote.fetchEntry('gc_server_1'),
        throwsA(isA<GameCollectionRemotePermanentException>()),
      );
    });

    test('a 404 means the row does not exist for this actor', () {
      stubGetThrows(_dioError(DioExceptionType.badResponse, status: 404));
      expect(
        () => remote.fetchEntry('gc_server_1'),
        throwsA(
          isA<GameCollectionNotFoundException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });
  });

  group('addToCollection', () {
    Map<String, dynamic> capturedBody() =>
        verify(
              () =>
                  mockDio.post<Object?>(any(), data: captureAny(named: 'data')),
            ).captured.single
            as Map<String, dynamic>;

    test('maps the created entry on 201', () async {
      stubPost(
        _resp({
          'collection': _entryJson(),
          'message': 'success.game_collection.added',
        }, statusCode: 201),
      );

      final entry = await remote.addToCollection(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
      );

      expect(entry.id, 'gc_server_1');
      expect(entry.isLocalOnly, isFalse);
    });

    test('accepts a 200 as success too', () async {
      stubPost(_resp({'collection': _entryJson()}));

      final entry = await remote.addToCollection(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
      );
      expect(entry.id, 'gc_server_1');
    });

    test('hits the collection path', () async {
      stubPost(_resp({'collection': _entryJson()}, statusCode: 201));

      await remote.addToCollection(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
      );

      verify(() => mockDio.post<Object?>(_path, data: any(named: 'data')))
          .called(1);
    });

    test('sends only the identity when optionals are omitted', () async {
      stubPost(_resp({'collection': _entryJson()}, statusCode: 201));

      await remote.addToCollection(
        platformGameId: 'pg_1',
        medium: GameMedium.digital,
      );

      expect(
        capturedBody(),
        equals({'platformGameId': 'pg_1', 'medium': 'Digital'}),
      );
    });

    test('sends every optional when supplied', () async {
      stubPost(_resp({'collection': _entryJson()}, statusCode: 201));

      await remote.addToCollection(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
        releaseId: 'rel_1',
        quantity: 3,
        rating: 9,
        comment: 'heavy',
        favorite: true,
        playAgain: false,
      );

      expect(
        capturedBody(),
        equals({
          'platformGameId': 'pg_1',
          'medium': 'Physical',
          'releaseId': 'rel_1',
          'quantity': 3,
          'rating': 9,
          'comment': 'heavy',
          'favorite': true,
          'playAgain': false,
        }),
      );
    });

    test('a non-positive quantity is rejected before the request', () {
      expect(
        () => remote.addToCollection(
          platformGameId: 'pg_1',
          medium: GameMedium.physical,
          quantity: 0,
        ),
        throwsArgumentError,
      );
      verifyNever(() => mockDio.post<Object?>(any(), data: any(named: 'data')));
    });

    test('a 404 (unknown platform game) is not-found, not already-removed', () {
      stubPostThrows(_dioError(DioExceptionType.badResponse, status: 404));
      expect(
        () => remote.addToCollection(
          platformGameId: 'nope',
          medium: GameMedium.physical,
        ),
        throwsA(isA<GameCollectionNotFoundException>()),
      );
    });
  });

  group('updateEntry', () {
    Map<String, dynamic> capturedBody() =>
        verify(
              () => mockDio.patch<Object?>(
                any(),
                data: captureAny(named: 'data'),
              ),
            ).captured.single
            as Map<String, dynamic>;

    test('maps the updated entry', () async {
      stubPatch(_resp({'collection': _entryJson(), 'message': 'ok'}));

      final entry = await remote.updateEntry(id: 'gc_server_1', quantity: 2);

      expect(entry.id, 'gc_server_1');
      expect(entry.isDirty, isFalse);
    });

    test('hits the id path with PATCH', () async {
      stubPatch(_resp({'collection': _entryJson()}));

      await remote.updateEntry(id: 'gc_server_1', quantity: 2);

      verify(
        () => mockDio.patch<Object?>(
          '$_path/gc_server_1',
          data: any(named: 'data'),
        ),
      ).called(1);
    });

    test('sends only the fields supplied', () async {
      stubPatch(_resp({'collection': _entryJson()}));

      await remote.updateEntry(id: 'gc_server_1', quantity: 4, favorite: true);

      expect(capturedBody(), equals({'quantity': 4, 'favorite': true}));
    });

    test('omits nulls rather than sending them (a null would CLEAR)', () async {
      stubPatch(_resp({'collection': _entryJson()}));

      await remote.updateEntry(
        id: 'gc_server_1',
        quantity: 4,
        rating: null,
        comment: null,
        favorite: null,
        playAgain: null,
        releaseId: null,
      );

      final body = capturedBody();
      expect(body.containsKey('rating'), isFalse);
      expect(body.containsKey('comment'), isFalse);
      expect(body.containsKey('favorite'), isFalse);
      expect(body.containsKey('playAgain'), isFalse);
      expect(body.containsKey('releaseId'), isFalse);
      expect(body, equals({'quantity': 4}));
    });

    test('never sends the server-managed play fields', () async {
      stubPatch(_resp({'collection': _entryJson()}));

      await remote.updateEntry(
        id: 'gc_server_1',
        quantity: 4,
        rating: 7,
        comment: 'x',
        favorite: true,
        playAgain: true,
        releaseId: 'rel_1',
      );

      final body = capturedBody();
      expect(body.containsKey('playCount'), isFalse);
      expect(body.containsKey('lastPlayed'), isFalse);
      expect(body.containsKey('platformGameId'), isFalse);
      expect(body.containsKey('medium'), isFalse);
    });

    test('an all-null patch is rejected before the request', () {
      expect(() => remote.updateEntry(id: 'gc_server_1'), throwsArgumentError);
      verifyNever(
        () => mockDio.patch<Object?>(any(), data: any(named: 'data')),
      );
    });

    test('the empty-patch rejection is an ArgumentError, deliberately outside '
        'the remote-exception taxonomy', () {
      // A drain reaching this has an UpdateCollectionOperation carrying only
      // server-managed fields (#258) — nothing this transport can send. It is
      // a caller bug, not a server answer, so it must not masquerade as one:
      // `catch (GameCollectionRemoteException)` deliberately misses it.
      expect(
        () => remote.updateEntry(id: 'gc_server_1'),
        throwsA(isNot(isA<GameCollectionRemoteException>())),
      );
    });

    test('a non-positive quantity is rejected before the request', () {
      expect(
        () => remote.updateEntry(id: 'gc_server_1', quantity: 0),
        throwsArgumentError,
      );
    });

    test('a 404 without the API error envelope is transient, not a permanent '
        'discard of the edit', () {
      stubPatchThrows(
        _dioError(
          DioExceptionType.badResponse,
          status: 404,
          body: '<html>404</html>',
        ),
      );
      expect(
        () => remote.updateEntry(id: 'gc_server_1', quantity: 2),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });

    test('a 404 carrying a mismatched or partial envelope is transient, not a '
        'permanent discard of the edit', () {
      for (final body in <Map<String, dynamic>>[
        {'statusCode': 502, 'message': 'Bad gateway', 'error': 'Bad Gateway'},
        {'statusCode': 404, 'message': 'nope'},
        {'statusCode': '404', 'message': 'nope', 'error': 'Not Found'},
      ]) {
        stubPatchThrows(
          _dioError(DioExceptionType.badResponse, status: 404, body: body),
        );
        expect(
          () => remote.updateEntry(id: 'gc_server_1', quantity: 2),
          throwsA(isA<GameCollectionRemoteTransientException>()),
          reason: 'body: $body',
        );
      }
    });

    test('a 404 means the row does not exist — permanent, not completion', () {
      stubPatchThrows(_dioError(DioExceptionType.badResponse, status: 404));
      expect(
        () => remote.updateEntry(id: 'gc_server_1', quantity: 2),
        throwsA(
          isA<GameCollectionNotFoundException>().having(
            (e) => e.isRetryable,
            'isRetryable',
            isFalse,
          ),
        ),
      );
    });
  });

  group('removeEntry', () {
    Map<String, dynamic> capturedQueryOnDelete() =>
        verify(
              () => mockDio.delete<Object?>(
                any(),
                queryParameters: captureAny(named: 'queryParameters'),
              ),
            ).captured.single
            as Map<String, dynamic>;

    test('returns the tombstoned entry the server confirms', () async {
      stubDelete(
        _resp({
          'collection': _entryJson(deletedAt: '2026-03-01T12:00:00.000Z'),
          'message': 'ok',
        }),
      );

      final entry = await remote.removeEntry('gc_server_1');

      expect(entry.isDeleted, isTrue);
      expect(entry.deletedAt, DateTime.parse('2026-03-01T12:00:00.000Z'));
    });

    test('hits the id path with DELETE', () async {
      stubDelete(
        _resp({
          'collection': _entryJson(deletedAt: '2026-03-01T12:00:00.000Z'),
        }),
      );

      await remote.removeEntry('gc_server_1');

      verify(
        () => mockDio.delete<Object?>(
          '$_path/gc_server_1',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).called(1);
    });

    test('omits the reason when none is given', () async {
      stubDelete(
        _resp({
          'collection': _entryJson(deletedAt: '2026-03-01T12:00:00.000Z'),
        }),
      );

      await remote.removeEntry('gc_server_1');

      expect(capturedQueryOnDelete(), isEmpty);
    });

    test('sends the reason when given', () async {
      stubDelete(
        _resp({
          'collection': _entryJson(deletedAt: '2026-03-01T12:00:00.000Z'),
        }),
      );

      await remote.removeEntry('gc_server_1', reason: 'Sold');

      expect(capturedQueryOnDelete(), equals({'reason': 'Sold'}));
    });

    test('a 404 is already-removed, which is completion — not a failure', () {
      stubDeleteThrows(_dioError(DioExceptionType.badResponse, status: 404));

      expect(
        () => remote.removeEntry('gc_server_1'),
        throwsA(
          isA<GameCollectionAlreadyRemovedException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.isRetryable, 'isRetryable', isFalse),
        ),
      );
    });

    test('an already-removed 404 is NOT a permanent failure type', () {
      stubDeleteThrows(_dioError(DioExceptionType.badResponse, status: 404));

      expect(
        () => remote.removeEntry('gc_server_1'),
        throwsA(isNot(isA<GameCollectionRemotePermanentException>())),
      );
    });

    test(
      'a 404 without the API error envelope is transient, NOT completion',
      () {
        // The whole value of already-removed is that the drain marks the
        // operation completed. A proxy or gateway answering 404 means the
        // service never saw the removal, so completing it would silently
        // discard the user's deletion and the entry would reappear on the next
        // hydrate. Without the application's envelope there is no row-level
        // conclusion to draw.
        stubDeleteThrows(
          _dioError(
            DioExceptionType.badResponse,
            status: 404,
            body: '<html>404 Not Found</html>',
          ),
        );
        expect(
          () => remote.removeEntry('gc_server_1'),
          throwsA(
            isA<GameCollectionRemoteTransientException>().having(
              (e) => e.isRetryable,
              'isRetryable',
              isTrue,
            ),
          ),
        );
      },
    );

    test('an empty-bodied 404 is transient too', () {
      stubDeleteThrows(
        _dioError(DioExceptionType.badResponse, status: 404, body: ''),
      );
      expect(
        () => remote.removeEntry('gc_server_1'),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });

    test('a 404 carrying the API error envelope IS already-removed', () {
      stubDeleteThrows(_dioError(DioExceptionType.badResponse, status: 404));
      expect(
        () => remote.removeEntry('gc_server_1'),
        throwsA(isA<GameCollectionAlreadyRemovedException>()),
      );
    });

    test('a 404 whose body claims a different status is transient, NOT '
        'completion', () {
      // The filter renders `statusCode` from the exception's own status, so an
      // application 404 always carries 404. A body announcing some other
      // status arrived with this one, which means something between the app
      // and here rewrote the status — exactly the case that must not be
      // mistaken for a row-level conclusion.
      stubDeleteThrows(
        _dioError(
          DioExceptionType.badResponse,
          status: 404,
          body: {
            'statusCode': 502,
            'message': 'Bad gateway',
            'error': 'Bad Gateway',
          },
        ),
      );
      expect(
        () => remote.removeEntry('gc_server_1'),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });

    test('a 404 missing the envelope\'s error label is transient, NOT '
        'completion', () {
      // `{ statusCode, message, error }` is one shape, not three optional
      // fields: `translateException` always sets the label. A two-field
      // lookalike is some other producer's JSON.
      stubDeleteThrows(
        _dioError(
          DioExceptionType.badResponse,
          status: 404,
          body: {'statusCode': 404, 'message': 'nope'},
        ),
      );
      expect(
        () => remote.removeEntry('gc_server_1'),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });

    test('a 404 arriving as a plain response, not a DioException, classifies '
        'the same way', () {
      // The factory sets `validateStatus: (_) => true`, so in production a 404
      // comes back as an ordinary Response rather than a thrown DioException.
      // Both paths must read the envelope.
      stubDelete(_resp2(_errorEnvelope(404), statusCode: 404));
      expect(
        () => remote.removeEntry('gc_server_1'),
        throwsA(isA<GameCollectionAlreadyRemovedException>()),
      );
    });

    test('a 403 on delete is still a permanent failure', () {
      stubDeleteThrows(_dioError(DioExceptionType.badResponse, status: 403));

      expect(
        () => remote.removeEntry('gc_server_1'),
        throwsA(isA<GameCollectionRemotePermanentException>()),
      );
    });
  });

  group('status classification', () {
    test('401, 408, 429 and every 5xx are transient', () async {
      for (final status in [401, 408, 429, 500, 502, 503]) {
        stubGetThrows(_dioError(DioExceptionType.badResponse, status: status));
        expect(
          () => remote.fetchEntry('gc_1'),
          throwsA(
            isA<GameCollectionRemoteTransientException>().having(
              (e) => e.isRetryable,
              'isRetryable',
              isTrue,
            ),
          ),
          reason: 'status $status should be transient',
        );
      }
    });

    test('400, 403, 409, 422 are permanent', () async {
      for (final status in [400, 403, 409, 422]) {
        stubGetThrows(_dioError(DioExceptionType.badResponse, status: status));
        expect(
          () => remote.fetchEntry('gc_1'),
          throwsA(
            isA<GameCollectionRemotePermanentException>().having(
              (e) => e.isRetryable,
              'isRetryable',
              isFalse,
            ),
          ),
          reason: 'status $status should be permanent',
        );
      }
    });

    test('connection faults without a status are transient', () async {
      for (final type in [
        DioExceptionType.connectionError,
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.unknown,
      ]) {
        stubGetThrows(_dioError(type));
        expect(
          () => remote.fetchEntry('gc_1'),
          throwsA(isA<GameCollectionRemoteTransientException>()),
          reason: '$type should be transient',
        );
      }
    });

    test('a 2xx response with a null status is transient', () {
      stubGet(_resp({'collection': _entryJson()}, statusCode: null));
      expect(
        () => remote.fetchEntry('gc_1'),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });

    test('a 3xx surfaced by a permissive validateStatus is transient', () {
      stubGet(_resp({'collection': _entryJson()}, statusCode: 302));
      expect(
        () => remote.fetchEntry('gc_1'),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });

    test('a non-Dio error escaping the transport is transient', () {
      stubGetThrows(StateError('unexpected'));
      expect(
        () => remote.fetchEntry('gc_1'),
        throwsA(isA<GameCollectionRemoteTransientException>()),
      );
    });
  });

  group('path-prefix deployments', () {
    // The interface promises the per-server Dio's base URL is honoured
    // "path-prefix deployments included". Nothing tested that, and it is not
    // obvious: a leading-slash path WOULD drop the prefix under `Uri.resolve`
    // semantics. Dio does not resolve — it concatenates
    // (`url = baseUrl + url`, dio-5.9.2/lib/src/options.dart:631) — and
    // `DefaultDioFactory.normalizeBaseUrl` strips one trailing slash so the
    // join produces exactly one separator. These two halves are what make the
    // convention work, so both are pinned here.
    Uri resolve(String baseUrl, String path) => RequestOptions(
      path: path,
      baseUrl: DefaultDioFactory.normalizeBaseUrl(baseUrl),
    ).uri;

    test('a path-prefixed base URL keeps its prefix', () {
      expect(
        resolve('https://host.example.com/bge', _path).toString(),
        'https://host.example.com/bge/api/game-collections',
      );
    });

    test('a trailing slash on the base does not double the separator', () {
      expect(
        resolve('https://host.example.com/bge/', _path).toString(),
        'https://host.example.com/bge/api/game-collections',
      );
    });

    test('a bare-origin base URL still resolves', () {
      expect(
        resolve('https://host.example.com', '$_path/gc_1').toString(),
        'https://host.example.com/api/game-collections/gc_1',
      );
    });

    test('a multi-segment prefix survives', () {
      expect(
        resolve('https://host.example.com/a/b/c', _path).toString(),
        'https://host.example.com/a/b/c/api/game-collections',
      );
    });
  });

  group('exception taxonomy', () {
    test('every variant is a GameCollectionRemoteException', () {
      const variants = <GameCollectionRemoteException>[
        GameCollectionRemoteTransientException('t'),
        GameCollectionRemotePermanentException('p'),
        GameCollectionNotFoundException('n'),
        GameCollectionAlreadyRemovedException('a'),
      ];
      for (final variant in variants) {
        expect(variant, isA<GameCollectionRemoteException>());
      }
    });

    test('only the transient variant is retryable', () {
      expect(
        const GameCollectionRemoteTransientException('t').isRetryable,
        isTrue,
      );
      expect(
        const GameCollectionRemotePermanentException('p').isRetryable,
        isFalse,
      );
      expect(const GameCollectionNotFoundException('n').isRetryable, isFalse);
      expect(
        const GameCollectionAlreadyRemovedException('a').isRetryable,
        isFalse,
      );
    });

    test('the two 404 contexts are distinct types', () {
      expect(
        const GameCollectionAlreadyRemovedException('a'),
        isNot(isA<GameCollectionNotFoundException>()),
      );
      expect(
        const GameCollectionNotFoundException('n'),
        isNot(isA<GameCollectionAlreadyRemovedException>()),
      );
    });

    test('toString carries the type and status without the cause', () {
      const error = GameCollectionNotFoundException('gone', statusCode: 404);
      expect(
        error.toString(),
        'GameCollectionNotFoundException(message: gone, statusCode: 404)',
      );
    });
  });
}
