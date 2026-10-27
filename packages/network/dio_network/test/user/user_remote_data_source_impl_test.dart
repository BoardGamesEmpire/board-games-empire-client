import 'dart:convert';
import 'dart:typed_data';

import 'package:bge_test_support/network.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A user search answer as the backend renders it: each row is a
/// `UserSearchResultDto`, whose name columns the model has no home for, and
/// whose profile is null for a user who has none.
String _users() => jsonEncode({
  'users': [
    {
      'id': 'u_2',
      'username': 'ana',
      'firstName': 'Ana',
      'lastName': 'B',
      'profile': {'displayName': 'Ana B', 'avatarUrl': null},
    },
    {
      'id': 'u_3',
      'username': 'anna',
      'firstName': null,
      'lastName': null,
      'profile': null,
    },
    {
      'id': 'u_4',
      'username': 'anya',
      'firstName': null,
      'lastName': null,
      'profile': {'displayName': null, 'avatarUrl': null},
    },
  ],
  'pagination': {
    'page': 1,
    'limit': 20,
    'total': 3,
    'totalPages': 1,
    'hasMore': false,
  },
});

/// Nest's rendering of an `HttpException` carrying a message.
String _envelope(int status, [Map<String, dynamic> extra = const {}]) =>
    jsonEncode({
      'statusCode': status,
      'message': 'translated',
      'error': 'Error',
      ...extra,
    });

/// One request as the transport received it.
typedef _Sent = ({String method, String path, Map<String, dynamic> query});

/// Answers every request with one canned response, and records what it was
/// sent. [CannedAdapter] can't do the second half.
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

  /// A data source over a real Dio, permissive about status like the
  /// production factories.
  UserRemoteDataSource answering(String body, {int status = 200}) {
    adapter = _RecordingAdapter(body, status);
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
    return UserRemoteDataSourceImpl(dio);
  }

  group('searchUsers', () {
    test('sends the trimmed query at the search page size', () async {
      final remote = answering(_users());

      final page = await remote.searchUsers('  an ');

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/users/search');
      expect(adapter.sent.single.query, {'q': 'an', 'page': 1, 'limit': 20});
      expect(page.items, hasLength(3));
    });

    test('sends the page and limit it was given', () async {
      final remote = answering(_users());

      await remote.searchUsers('ana', page: 2, limit: 5);

      expect(adapter.sent.single.query, {'q': 'ana', 'page': 2, 'limit': 5});
    });

    test('maps id, username and profile.displayName', () async {
      final remote = answering(_users());

      final page = await remote.searchUsers('an');

      // A null profile, and a profile with no display name, both leave the
      // display name null.
      expect(page.items, const [
        UserSummary(id: 'u_2', username: 'ana', displayName: 'Ana B'),
        UserSummary(id: 'u_3', username: 'anna', displayName: null),
        UserSummary(id: 'u_4', username: 'anya', displayName: null),
      ]);
    });

    test('refuses a query under 2 characters before any request', () async {
      final remote = answering(_users());

      await expectLater(remote.searchUsers(' a '), throwsArgumentError);
      await expectLater(remote.searchUsers('   '), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test('refuses a limit over 20 before any request', () async {
      final remote = answering(_users());

      await expectLater(
        remote.searchUsers('ana', limit: 21),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });

    test('refuses a limit below 1 and a page before the first before any '
        'request', () async {
      final remote = answering(_users());

      await expectLater(
        remote.searchUsers('ana', limit: 0),
        throwsArgumentError,
      );
      await expectLater(
        remote.searchUsers('ana', page: 0),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });
  });

  group('classification', () {
    Matcher transient(int status) => throwsA(
      isA<UserRemoteTransientException>().having(
        (e) => e.statusCode,
        'statusCode',
        status,
      ),
    );
    Matcher permanent(int status) => throwsA(
      isA<UserRemotePermanentException>().having(
        (e) => e.statusCode,
        'statusCode',
        status,
      ),
    );

    test('no response at all is transient', () async {
      final remote = UserRemoteDataSourceImpl(
        unreachableDio(DioExceptionType.connectionError),
      );

      await expectLater(
        remote.searchUsers('ana'),
        throwsA(
          isA<UserRemoteTransientException>()
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.cause, 'cause', isA<DioException>()),
        ),
      );
    });

    for (final status in [500, 503, 401, 407, 408, 429]) {
      test('$status is transient', () async {
        final remote = answering(_envelope(status), status: status);

        await expectLater(remote.searchUsers('ana'), transient(status));
      });
    }

    test('a 409 saying retryable is transient', () async {
      final remote = answering(
        _envelope(409, {'retryable': true}),
        status: 409,
      );

      await expectLater(remote.searchUsers('ana'), transient(409));
    });

    for (final status in [403, 404]) {
      test('a $status without the envelope is transient', () async {
        // A proxy or gateway answered, not the API.
        final remote = answering('<html>blocked</html>', status: status);

        await expectLater(remote.searchUsers('ana'), transient(status));
      });
    }

    test('an enveloped 404 is transient', () async {
      // A list route is never absent, and Nest answers an unrouted path with
      // this same envelope, so this is a server without the route and not
      // "no users".
      final remote = answering(_envelope(404), status: 404);

      await expectLater(remote.searchUsers('ana'), transient(404));
    });

    test('a 400 is permanent', () async {
      final remote = answering(_envelope(400), status: 400);

      await expectLater(remote.searchUsers('ana'), permanent(400));
    });

    for (final status in [402, 403, 409, 410]) {
      test('an enveloped $status is permanent', () async {
        // Search has no refusal of its own: what the household invite remote
        // calls one is permanent here.
        final remote = answering(_envelope(status), status: status);

        await expectLater(remote.searchUsers('ana'), permanent(status));
      });
    }

    test('another 4xx is permanent', () async {
      await expectLater(
        answering(_envelope(422), status: 422).searchUsers('ana'),
        permanent(422),
      );
      await expectLater(
        answering('<html>no</html>', status: 400).searchUsers('ana'),
        permanent(400),
      );
    });

    test('a 3xx is transient', () async {
      final remote = answering('', status: 304);

      await expectLater(remote.searchUsers('ana'), transient(304));
    });

    test('a status Dio throws on is classified the same way', () async {
      // The production factories hand every status back as a response, but the
      // remote takes any Dio, and one with Dio's default validateStatus throws
      // the response instead.
      UserRemoteDataSource over(int status) => UserRemoteDataSourceImpl(
        cannedDio(
          body: _envelope(status),
          statusCode: status,
          permissiveStatus: false,
        ),
      );

      await expectLater(over(404).searchUsers('ana'), transient(404));
      await expectLater(over(400).searchUsers('ana'), permanent(400));
    });

    test('a 2xx that is not the contract is permanent', () async {
      final rowWithoutUsername = jsonEncode({
        'users': [
          {'id': 'u_2'},
        ],
        'pagination': {
          'page': 1,
          'limit': 20,
          'total': 1,
          'totalPages': 1,
          'hasMore': false,
        },
      });

      for (final body in [
        '{"users": 1}',
        '{"invites": []}',
        rowWithoutUsername,
        '[]',
        'not json',
        '',
      ]) {
        await expectLater(
          answering(body).searchUsers('ana'),
          permanent(200),
          reason: 'body: $body',
        );
      }
    });
  });
}
