import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

String _envelope(int status, String error, String message) =>
    jsonEncode({'statusCode': status, 'message': message, 'error': error});

String _retryableConflict() => jsonEncode({
  'statusCode': 409,
  'error': 'Conflict',
  'message': 'The request collided with another; try it again.',
  'code': 'TransactionDeadlockError',
  'retryable': true,
});

Map<String, dynamic> _row({
  String id = 'hh_1',
  String reach = 'Public',
  String? deletedAt,
  List<Map<String, dynamic>>? owners,
}) => {
  'id': id,
  'name': 'The Meeples',
  'image': null,
  'reach': reach,
  'createdAt': '2026-10-01T10:30:00.000Z',
  'deletedAt': deletedAt,
  'memberCount': 3,
  'owners':
      owners ??
      [
        {'userId': 'u1', 'username': 'ann', 'displayName': 'Ann A.'},
        {'userId': 'u2', 'username': 'bob', 'displayName': null},
      ],
};

String _page(List<Map<String, dynamic>> rows) => jsonEncode({
  'households': rows,
  'pagination': {
    'page': 1,
    'limit': 25,
    'total': rows.length,
    'totalPages': 1,
    'hasMore': false,
  },
});

Map<String, dynamic> _member(String id, String username) => {
  'id': id,
  'userId': 'user_$id',
  'householdId': 'hh_1',
  'showAllGames': true,
  'createdAt': '2026-10-01T10:30:00.000Z',
  'updatedAt': '2026-10-02T10:30:00.000Z',
  'user': {
    'id': 'user_$id',
    'username': username,
    'profile': {'avatarUrl': null, 'displayName': null},
  },
  'role': {
    'role': {'id': 'r1', 'name': 'HouseholdOwner'},
  },
};

String _detail({Object? languageTag = const {'name': 'English'}}) =>
    jsonEncode({
      'household': {
        'id': 'hh_1',
        'name': 'The Meeples',
        'description': 'Friday nights',
        'image': 'https://example.test/i.png',
        'reach': 'Friends',
        'createdAt': '2026-10-01T10:30:00.000Z',
        'languageTag': languageTag,
        'members': [_member('m1', 'ann'), _member('m2', 'bob')],
      },
    });

typedef _Sent = ({String method, String path, Map<String, dynamic> query});

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.body, this.status);

  final String body;
  final int status;
  final List<_Sent> sent = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sent.add((
      method: options.method,
      path: options.path,
      query: options.queryParameters,
    ));
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _RecordingAdapter adapter;

  AdminHouseholdRemoteDataSource answering(String body, {int status = 200}) {
    adapter = _RecordingAdapter(body, status);
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
    return AdminHouseholdRemoteDataSourceImpl(dio);
  }

  group('fetchPage', () {
    test('sends status, sort, page and limit, and q only when given', () async {
      final remote = answering(_page([]));

      await remote.fetchPage();
      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/admin/households');
      expect(adapter.sent.single.query, {
        'status': 'live',
        'sort': 'name',
        'page': 1,
        'limit': 25,
      });

      await remote.fetchPage(
        status: AdminHouseholdStatus.deleted,
        sort: AdminHouseholdSort.deleted,
        query: '  ab ',
        page: 2,
        limit: 10,
      );
      expect(adapter.sent.last.query, {
        'status': 'deleted',
        'sort': 'deleted',
        'page': 2,
        'limit': 10,
        'q': 'ab',
      });
    });

    test('decodes a row', () async {
      final remote = answering(
        _page([
          _row(
            reach: 'FriendsOfFriends',
            deletedAt: '2026-10-05T00:00:00.000Z',
          ),
        ]),
      );

      final page = await remote.fetchPage();

      expect(
        page.items.single,
        AdminHouseholdRow(
          id: 'hh_1',
          name: 'The Meeples',
          reach: Reach.friendsOfFriends,
          createdAt: DateTime.utc(2026, 10, 1, 10, 30),
          deletedAt: DateTime.utc(2026, 10, 5),
          memberCount: 3,
          owners: const [
            AdminHouseholdOwner(
              userId: 'u1',
              username: 'ann',
              displayName: 'Ann A.',
            ),
            AdminHouseholdOwner(userId: 'u2', username: 'bob'),
          ],
        ),
      );
      expect(page.items.single.owners.last.displayName, isNull);
    });

    test('an unknown reach name is Reach.unknown', () async {
      final remote = answering(_page([_row(reach: 'Galactic')]));

      final page = await remote.fetchPage();

      expect(page.items.single.reach, Reach.unknown);
    });

    group('refuses a call the server would 400', () {
      final calls =
          <String, Future<Object?> Function(AdminHouseholdRemoteDataSource)>{
            'deleted sort with live status': (r) =>
                r.fetchPage(sort: AdminHouseholdSort.deleted),
            'a one-character query': (r) => r.fetchPage(query: 'a'),
            'a blank query': (r) => r.fetchPage(query: '   '),
            'a 101-character query': (r) => r.fetchPage(query: 'a' * 101),
            'one emoji, one server character': (r) =>
                r.fetchPage(query: '\u{1F600}'),
            'page 0': (r) => r.fetchPage(page: 0),
            'limit 101': (r) => r.fetchPage(limit: 101),
            'limit 0': (r) => r.fetchPage(limit: 0),
          };
      for (final entry in calls.entries) {
        test(entry.key, () async {
          final remote = answering(_page([]));

          await expectLater(entry.value(remote), throwsArgumentError);
          expect(adapter.sent, isEmpty);
        });
      }
    });

    test('sends a 100-character ASCII query', () async {
      final remote = answering(_page([]));

      await remote.fetchPage(query: 'a' * 100);

      expect(adapter.sent.single.query['q'], 'a' * 100);
    });
  });

  group('fetchDetail', () {
    test('decodes the household, its language and its roster', () async {
      final remote = answering(_detail());

      final detail = await remote.fetchDetail('hh_1');

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/households/hh_1');
      expect(detail.id, 'hh_1');
      expect(detail.name, 'The Meeples');
      expect(detail.description, 'Friday nights');
      expect(detail.image, 'https://example.test/i.png');
      expect(detail.reach, Reach.friends);
      expect(detail.languageName, 'English');
      expect(detail.createdAt, DateTime.utc(2026, 10, 1, 10, 30));
      expect(detail.members.map((m) => m.username), ['ann', 'bob']);
      expect(detail.members.first.role, HouseholdRole.householdOwner);
    });

    test('a null languageTag is no language name', () async {
      final remote = answering(_detail(languageTag: null));

      final detail = await remote.fetchDetail('hh_1');

      expect(detail.languageName, isNull);
    });

    test('encodes the id in the path', () async {
      final remote = answering(_detail());

      await remote.fetchDetail('a/b');

      expect(adapter.sent.single.path, '/api/households/a%2Fb');
    });
  });

  group('restore', () {
    test("posts to the household's restore path, encoding the id", () async {
      final remote = answering('{}');

      await remote.restore('a/b');

      expect(adapter.sent.single.method, 'POST');
      expect(adapter.sent.single.path, '/api/households/a%2Fb/restore');
    });
  });

  test('restore does not read the 2xx body', () async {
    final remote = answering('<html>ok</html>', status: 204);

    await remote.restore('hh_1');
  });

  group('failures', () {
    final forbidden = _envelope(403, 'Forbidden', 'Not allowed.');
    final notFound = _envelope(404, 'Not Found', 'No such household.');
    final conflict = _envelope(409, 'Conflict', 'Not deleted.');

    test('fetchPage: an enveloped 403 is forbidden', () async {
      final remote = answering(forbidden, status: 403);
      await expectLater(
        remote.fetchPage(),
        throwsA(isA<AdminHouseholdForbiddenException>()),
      );
    });

    test('fetchPage: an enveloped 404 is transient (route not deployed)', () {
      final remote = answering(notFound, status: 404);
      return expectLater(
        remote.fetchPage(),
        throwsA(isA<AdminHouseholdTransientException>()),
      );
    });

    test('fetchDetail: an enveloped 404 is not found', () {
      final remote = answering(notFound, status: 404);
      return expectLater(
        remote.fetchDetail('hh_1'),
        throwsA(isA<AdminHouseholdNotFoundException>()),
      );
    });

    test('restore: an enveloped 404 is not found', () {
      final remote = answering(notFound, status: 404);
      return expectLater(
        remote.restore('hh_1'),
        throwsA(isA<AdminHouseholdNotFoundException>()),
      );
    });

    test('restore: an enveloped 409 is not deleted', () {
      final remote = answering(conflict, status: 409);
      return expectLater(
        remote.restore('hh_1'),
        throwsA(isA<AdminHouseholdNotDeletedException>()),
      );
    });

    test('restore: a retryable 409 is transient', () {
      final remote = answering(_retryableConflict(), status: 409);
      return expectLater(
        remote.restore('hh_1'),
        throwsA(isA<AdminHouseholdTransientException>()),
      );
    });

    final calls =
        <String, Future<Object?> Function(AdminHouseholdRemoteDataSource)>{
          'fetchPage': (r) => r.fetchPage(),
          'fetchDetail': (r) => r.fetchDetail('hh_1'),
          'restore': (r) => r.restore('hh_1'),
        };
    for (final entry in calls.entries) {
      test('${entry.key}: a 403 with no envelope is transient', () {
        final remote = answering('<html>Blocked</html>', status: 403);
        return expectLater(
          entry.value(remote),
          throwsA(isA<AdminHouseholdTransientException>()),
        );
      });

      test('${entry.key}: a 500 is transient', () {
        final remote = answering('boom', status: 500);
        return expectLater(
          entry.value(remote),
          throwsA(isA<AdminHouseholdTransientException>()),
        );
      });
    }

    for (final entry in {
      'fetchPage': (AdminHouseholdRemoteDataSource r) => r.fetchPage(),
      'fetchDetail': (AdminHouseholdRemoteDataSource r) =>
          r.fetchDetail('hh_1'),
    }.entries) {
      test(
        '${entry.key}: a malformed 2xx body is permanent with its status',
        () {
          final remote = answering('<html>captive portal</html>');
          return expectLater(
            entry.value(remote),
            throwsA(
              isA<AdminHouseholdPermanentException>().having(
                (e) => e.statusCode,
                'statusCode',
                200,
              ),
            ),
          );
        },
      );
    }

    Map<String, dynamic> household() =>
        (jsonDecode(_detail()) as Map<String, dynamic>)['household']
            as Map<String, dynamic>;
    for (final (label, body, says) in [
      ('no household', <String, dynamic>{}, 'missing the "household" object'),
      (
        'a household that is not an object',
        {'household': 'hh_1'},
        '"household" is String, expected an object',
      ),
      (
        'no members',
        {'household': household()..remove('members')},
        'missing the "members" array',
      ),
      (
        'members that are not a list',
        {
          'household': household()..['members'] = {'m1': 'ann'},
        },
        'expected a list',
      ),
      (
        'a languageTag that is not an object',
        {'household': household()..['languageTag'] = 'en'},
        '"languageTag" is String, expected an object or null',
      ),
    ]) {
      test('fetchDetail: a body with $label is permanent with its status', () {
        final remote = answering(jsonEncode(body));
        return expectLater(
          remote.fetchDetail('hh_1'),
          throwsA(
            isA<AdminHouseholdPermanentException>()
                .having((e) => e.statusCode, 'statusCode', 200)
                .having((e) => e.cause, 'cause', isA<FormatException>())
                .having((e) => e.message, 'message', contains(says)),
          ),
        );
      });
    }
  });
}
