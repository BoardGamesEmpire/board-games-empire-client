import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

class MockDio extends Mock implements Dio {}

/// A household row as `GET /api/households` embeds it — the scalar columns
/// plus the `languageTag` select and the `members` include, transcribed from
/// the backend's own black-box wire types
/// (`apps/api-e2e/src/household/household-wire.ts`).
Map<String, dynamic> _householdRow({
  String id = 'hh_1',
  String name = 'Game Night HQ',
  List<Map<String, dynamic>> members = const [],
  String? deletedAt,
}) => {
  'id': id,
  'name': name,
  'description': null,
  'image': null,
  'languageTagId': null,
  'createdById': 'user-abc',
  'visibility': 'Private',
  'deletedAt': deletedAt,
  'createdAt': '2026-01-15T10:30:00.000Z',
  'updatedAt': '2026-01-15T10:30:00.000Z',
  'languageTag': null,
  'members': members,
};

/// A member row as the list include embeds it.
///
/// `role` is a **nested projection**, not the enum string the domain model
/// serialises: the Prisma include is
/// `role: { include: { role: { select: { id, name } } } }`.
Map<String, dynamic> _memberRow({
  String id = 'hm_1',
  String userId = 'user-abc',
  String householdId = 'hh_1',
  String? roleName = 'HouseholdOwner',
  bool showAllGames = true,
}) => {
  'id': id,
  'userId': userId,
  'householdId': householdId,
  'showAllGames': showAllGames,
  'origin': 'Founder',
  'addedById': null,
  'createdAt': '2026-01-15T10:30:00.000Z',
  'updatedAt': '2026-01-15T10:30:00.000Z',
  'role': roleName == null
      ? null
      : {
          'id': 'hr_1',
          'householdMemberId': id,
          'roleId': 'role_1',
          'role': {'id': 'role_1', 'name': roleName},
        },
  'user': {
    'id': userId,
    'username': 'ada',
    'profile': {'avatarUrl': null, 'displayName': 'Ada'},
  },
};

Map<String, dynamic> _envelope(
  List<Map<String, dynamic>> households, {
  int page = 1,
  int limit = 100,
  int? total,
  int totalPages = 1,
  bool hasMore = false,
}) => {
  'households': households,
  'pagination': {
    'page': page,
    'limit': limit,
    'total': total ?? households.length,
    'totalPages': totalPages,
    'hasMore': hasMore,
  },
};

Response<Object?> _resp(Object? data, {int? statusCode = 200}) => Response(
  data: data,
  statusCode: statusCode,
  requestOptions: RequestOptions(path: '/api/households'),
);

void main() {
  late MockDio mockDio;
  late HouseholdRemoteDataSourceImpl remote;

  void stubGet(Response<Object?> response) {
    when(
      () => mockDio.get<Object?>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) async => response);
  }

  setUp(() {
    mockDio = MockDio();
    remote = HouseholdRemoteDataSourceImpl(mockDio);
  });

  group('HouseholdRemoteDataSourceImpl.fetchHouseholds', () {
    test('maps each row and reads the pagination meta', () async {
      stubGet(
        _resp(
          _envelope(
            [_householdRow(), _householdRow(id: 'hh_2', name: 'The Annex')],
            total: 137,
            totalPages: 2,
            hasMore: true,
          ),
        ),
      );

      final page = await remote.fetchHouseholds();

      expect(page.items.map((e) => e.household.id), ['hh_1', 'hh_2']);
      expect(page.items.first.household.name, 'Game Night HQ');
      expect(page.meta.total, 137);
      expect(page.meta.hasMore, isTrue);
    });

    test('an empty page is a page, not a failure', () async {
      stubGet(_resp(_envelope(const [])));

      final page = await remote.fetchHouseholds();

      expect(page.items, isEmpty);
      expect(page.meta.hasMore, isFalse);
      expect(page.meta.total, 0);
    });

    test('server-confirmed rows carry both sync flags false', () async {
      stubGet(_resp(_envelope([_householdRow()])));

      final page = await remote.fetchHouseholds();

      expect(page.items.single.household.isDirty, isFalse);
      expect(page.items.single.household.isLocalOnly, isFalse);
    });
  });

  group('fetchHouseholds — the embedded members', () {
    test('resolves the nested role projection to a real role', () async {
      // The regression this whole mapper exists for: handed to
      // HouseholdMember.fromJson, the nested object degrades silently to
      // HouseholdRole.unknown and isOwner goes false for everyone.
      stubGet(
        _resp(
          _envelope([
            _householdRow(members: [_memberRow()]),
          ]),
        ),
      );

      final member =
          (await remote.fetchHouseholds()).items.single.members.single;

      expect(member.role, HouseholdRole.householdOwner);
      expect(member.isOwner, isTrue);
    });

    test('maps the scalar member fields', () async {
      stubGet(
        _resp(
          _envelope([
            _householdRow(members: [_memberRow(showAllGames: false)]),
          ]),
        ),
      );

      final member =
          (await remote.fetchHouseholds()).items.single.members.single;

      expect(member.id, 'hm_1');
      expect(member.userId, 'user-abc');
      expect(member.householdId, 'hh_1');
      expect(member.showAllGames, isFalse);
    });

    test('a member with no role binding maps to a null role', () async {
      stubGet(
        _resp(
          _envelope([
            _householdRow(members: [_memberRow(roleName: null)]),
          ]),
        ),
      );

      final member =
          (await remote.fetchHouseholds()).items.single.members.single;

      expect(member.role, isNull);
    });

    test('an unrecognized server role name degrades to unknown', () async {
      stubGet(
        _resp(
          _envelope([
            _householdRow(
              members: [_memberRow(roleName: 'HouseholdChaperone')],
            ),
          ]),
        ),
      );

      final member =
          (await remote.fetchHouseholds()).items.single.members.single;

      expect(member.role, HouseholdRole.unknown);
    });

    test('a role projection of the wrong shape is permanent, not unknown', () {
      // The distinction that keeps `unknown` meaningful: a custom role name
      // degrades, a broken payload fails loudly.
      final row = _householdRow(members: [_memberRow()]);
      (row['members']! as List).first['role'] = 'HouseholdOwner';
      stubGet(_resp(_envelope([row])));

      expect(
        () => remote.fetchHouseholds(),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });

    test('a household with no members maps to an empty roster', () async {
      stubGet(_resp(_envelope([_householdRow()])));

      expect((await remote.fetchHouseholds()).items.single.members, isEmpty);
    });

    test('an absent members key is an empty roster', () async {
      final row = _householdRow()..remove('members');
      stubGet(_resp(_envelope([row])));

      expect((await remote.fetchHouseholds()).items.single.members, isEmpty);
    });

    test('a members field of the wrong type is permanent', () {
      // Not an empty roster: "we could not read the roster" must not look
      // like "this household has one member in it".
      final row = _householdRow();
      row['members'] = 'oops';
      stubGet(_resp(_envelope([row])));

      expect(
        () => remote.fetchHouseholds(),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });

    test('a member missing showAllGames is permanent, not permissive', () {
      final row = _householdRow(members: [_memberRow()]);
      (row['members']! as List).first.remove('showAllGames');
      stubGet(_resp(_envelope([row])));

      expect(
        () => remote.fetchHouseholds(),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });
  });

  group('fetchHouseholds — the request', () {
    Map<String, dynamic> capturedQuery() =>
        verify(
              () => mockDio.get<Object?>(
                any(),
                queryParameters: captureAny(named: 'queryParameters'),
              ),
            ).captured.single
            as Map<String, dynamic>;

    test('sends page and limit, and never an offset', () async {
      stubGet(_resp(_envelope(const [])));

      await remote.fetchHouseholds(page: 3, limit: 50);

      final query = capturedQuery();
      expect(query, equals({'page': 3, 'limit': 50}));
      expect(query.containsKey('offset'), isFalse);
    });

    test('defaults to the first page at the maximum size', () async {
      stubGet(_resp(_envelope(const [])));

      await remote.fetchHouseholds();

      expect(capturedQuery(), equals({'page': 1, 'limit': 100}));
    });

    test('hits the relative /api/households path', () async {
      stubGet(_resp(_envelope(const [])));

      await remote.fetchHouseholds();

      verify(
        () => mockDio.get<Object?>(
          '/api/households',
          queryParameters: any(named: 'queryParameters'),
        ),
      ).called(1);
    });
  });

  group('fetchHouseholds — paging the server would reject', () {
    test('a limit above the cap throws before the request', () {
      expect(
        () => remote.fetchHouseholds(limit: 101),
        throwsA(isA<ArgumentError>()),
      );
      verifyNever(
        () => mockDio.get<Object?>(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      );
    });

    test('a zero limit throws', () {
      expect(
        () => remote.fetchHouseholds(limit: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('page is 1-based, so 0 throws', () {
      expect(
        () => remote.fetchHouseholds(page: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a page past the depth ceiling throws', () {
      // (page - 1) * limit must not exceed 100_000.
      expect(
        () => remote.fetchHouseholds(page: 1002, limit: 100),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the last page inside the ceiling is allowed', () async {
      stubGet(_resp(_envelope(const [])));

      await remote.fetchHouseholds(page: 1001, limit: 100);

      verify(
        () => mockDio.get<Object?>(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      ).called(1);
    });
  });

  group('fetchHouseholds — failures', () {
    void stubGetThrows(Object error) {
      when(
        () => mockDio.get<Object?>(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenThrow(error);
    }

    DioException dioError(
      DioExceptionType type, {
      Response<Object?>? response,
    }) => DioException(
      type: type,
      requestOptions: RequestOptions(path: '/api/households'),
      response: response,
    );

    test('a connection error is transient', () {
      stubGetThrows(dioError(DioExceptionType.connectionError));
      expect(
        () => remote.fetchHouseholds(),
        throwsA(isA<HouseholdRemoteTransientException>()),
      );
    });

    test('a 500 is transient', () {
      stubGetThrows(
        dioError(
          DioExceptionType.badResponse,
          response: _resp(null, statusCode: 500),
        ),
      );
      expect(
        () => remote.fetchHouseholds(),
        throwsA(
          isA<HouseholdRemoteTransientException>().having(
            (e) => e.statusCode,
            'statusCode',
            500,
          ),
        ),
      );
    });

    test('a 401 is transient — a session can expire mid-drain', () {
      stubGetThrows(
        dioError(
          DioExceptionType.badResponse,
          response: _resp(null, statusCode: 401),
        ),
      );
      expect(
        () => remote.fetchHouseholds(),
        throwsA(isA<HouseholdRemoteTransientException>()),
      );
    });

    test('a 404 is transient — a list route that 404s was never reached', () {
      // A misrouted path prefix or a not-yet-deployed API. The household list
      // route always exists in a deployed server, so a 404 says the request
      // did not arrive, not that there is nothing to list. Permanent here
      // would kill the hydrate until the app restarts, even after the server
      // is fixed. Same call as the collection list route (#253 D6).
      stubGetThrows(
        dioError(
          DioExceptionType.badResponse,
          response: _resp(null, statusCode: 404),
        ),
      );
      expect(
        () => remote.fetchHouseholds(),
        throwsA(
          isA<HouseholdRemoteTransientException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test('a 403 is permanent', () {
      stubGetThrows(
        dioError(
          DioExceptionType.badResponse,
          response: _resp(null, statusCode: 403),
        ),
      );
      expect(
        () => remote.fetchHouseholds(),
        throwsA(
          isA<HouseholdRemotePermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
    });

    test('a 2xx HTML body is permanent, not an endless retry', () {
      // A captive portal or a proxy answering 200 with a login page. Nothing
      // about retrying makes this parse.
      stubGet(_resp('<html><body>Sign in</body></html>'));
      expect(
        () => remote.fetchHouseholds(),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });

    test('a 2xx empty body is permanent', () {
      stubGet(_resp(null));
      expect(
        () => remote.fetchHouseholds(),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });

    test('a 2xx body missing the households array is permanent', () {
      stubGet(
        _resp(const {
          'pagination': {
            'page': 1,
            'limit': 25,
            'total': 0,
            'totalPages': 0,
            'hasMore': false,
          },
        }),
      );
      expect(
        () => remote.fetchHouseholds(),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });

    test('a 2xx body missing the pagination object is permanent', () {
      // Rather than defaulting a drain to "one page and stop".
      stubGet(_resp(const {'households': <Object?>[]}));
      expect(
        () => remote.fetchHouseholds(),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });

    test('a 2xx row that cannot be mapped is permanent', () {
      final row = _householdRow()..remove('createdAt');
      stubGet(_resp(_envelope([row])));
      expect(
        () => remote.fetchHouseholds(),
        throwsA(isA<HouseholdRemotePermanentException>()),
      );
    });

    test('a 2xx response with no status is transient', () {
      stubGet(_resp(_envelope(const []), statusCode: null));
      expect(
        () => remote.fetchHouseholds(),
        throwsA(isA<HouseholdRemoteTransientException>()),
      );
    });
  });
}
