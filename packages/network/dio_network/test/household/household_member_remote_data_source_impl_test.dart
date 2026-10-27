import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A member row as the backend's `MEMBER_SELECT` renders it: the scalar
/// columns, the account under `user`, and the role as the join row with the
/// role nested inside it.
Map<String, dynamic> _member({
  String id = 'm1',
  String roleName = 'HouseholdGuest',
  Object? user = const {
    'id': 'u1',
    'username': 'ada',
    'profile': {'avatarUrl': 'https://cdn.test/ada.png', 'displayName': 'Ada'},
  },
}) => {
  'id': id,
  'userId': 'u1',
  'householdId': 'h1',
  'showAllGames': false,
  'createdAt': '2026-10-19T10:00:00.000Z',
  'updatedAt': '2026-10-26T10:00:00.000Z',
  'user': user,
  'role': {
    'id': 'hmr1',
    'role': {'id': 'r1', 'name': roleName},
  },
};

String _answer([Map<String, dynamic>? member]) =>
    jsonEncode({'message': 'translated', 'member': member ?? _member()});

/// Nest's rendering of an `HttpException` carrying a message.
String _envelope(int status, [Map<String, dynamic> extra = const {}]) =>
    jsonEncode({
      'statusCode': status,
      'message': 'translated',
      'error': 'Error',
      ...extra,
    });

typedef _Sent = ({String method, String path, Object? body});

/// Answers every request with one canned response, and records what it was
/// sent.
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
    Object? requestBody;
    if (requestStream != null) {
      final bytes = await requestStream.expand((chunk) => chunk).toList();
      requestBody = jsonDecode(utf8.decode(bytes));
    }
    sent.add((method: options.method, path: options.path, body: requestBody));
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

/// Fails every request at the transport, with no response.
class _UnreachableAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => throw DioException.connectionError(
    requestOptions: options,
    reason: 'offline',
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  late _RecordingAdapter adapter;

  HouseholdMemberRemoteDataSource answering(String body, {int status = 200}) {
    adapter = _RecordingAdapter(body, status);
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
    return HouseholdMemberRemoteDataSourceImpl(dio);
  }

  group('changeRole', () {
    test('patches the role and parses the member', () async {
      final remote = answering(_answer());

      final member = await remote.changeRole(
        'h1',
        'm1',
        HouseholdRole.householdGuest,
      );

      expect(adapter.sent.single.method, 'PATCH');
      expect(adapter.sent.single.path, '/api/households/h1/members/m1/role');
      expect(adapter.sent.single.body, {'role': 'HouseholdGuest'});
      expect(member.id, 'm1');
      expect(member.userId, 'u1');
      expect(member.householdId, 'h1');
      expect(member.role, HouseholdRole.householdGuest);
      expect(member.showAllGames, isFalse);
      expect(member.username, 'ada');
      expect(member.displayName, 'Ada');
      expect(member.avatarUrl, 'https://cdn.test/ada.png');
      expect(member.createdAt, DateTime.utc(2026, 10, 19, 10));
      expect(member.updatedAt, DateTime.utc(2026, 10, 26, 10));
    });

    for (final (role, wire) in [
      (HouseholdRole.householdAdmin, 'HouseholdAdmin'),
      (HouseholdRole.householdMember, 'HouseholdMember'),
      (HouseholdRole.householdGuest, 'HouseholdGuest'),
    ]) {
      test('sends $wire for $role', () async {
        final remote = answering(_answer(_member(roleName: wire)));

        final member = await remote.changeRole('h1', 'm1', role);

        expect(adapter.sent.single.body, {'role': wire});
        expect(member.role, role);
      });
    }

    test('an owner or unknown role is refused before any request', () async {
      final remote = answering(_answer());

      await expectLater(
        remote.changeRole('h1', 'm1', HouseholdRole.householdOwner),
        throwsArgumentError,
      );
      await expectLater(
        remote.changeRole('h1', 'm1', HouseholdRole.unknown),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });

    test('offers the three roles an admin may hand out', () {
      expect(HouseholdMemberRemoteDataSource.assignableRoles, const {
        HouseholdRole.householdAdmin,
        HouseholdRole.householdMember,
        HouseholdRole.householdGuest,
      });
    });
  });

  group('remove', () {
    test('deletes the member and parses it', () async {
      final remote = answering(_answer(_member(roleName: 'HouseholdMember')));

      final member = await remote.remove('h1', 'm1');

      expect(adapter.sent.single.method, 'DELETE');
      expect(adapter.sent.single.path, '/api/households/h1/members/m1');
      expect(adapter.sent.single.body, isNull);
      expect(member.id, 'm1');
      expect(member.role, HouseholdRole.householdMember);
      expect(member.username, 'ada');
    });
  });

  group('the answer', () {
    test('keeps a member with no account projection nameless', () async {
      final remote = answering(_answer(_member(user: null)));

      final member = await remote.remove('h1', 'm1');

      expect(member.username, isNull);
      expect(member.displayName, isNull);
      expect(member.avatarUrl, isNull);
    });

    test('reads a role name it does not know as unknown', () async {
      final remote = answering(_answer(_member(roleName: 'Custom')));

      final member = await remote.remove('h1', 'm1');

      expect(member.role, HouseholdRole.unknown);
    });
  });

  group('paths', () {
    test('ids are path-encoded', () async {
      final remote = answering(_answer());

      await remote.changeRole('h/1', 'a/b', HouseholdRole.householdMember);
      await remote.remove('h/1', 'a/b');

      expect(adapter.sent.map((s) => (s.method, s.path)), const [
        ('PATCH', '/api/households/h%2F1/members/a%2Fb/role'),
        ('DELETE', '/api/households/h%2F1/members/a%2Fb'),
      ]);
    });
  });

  group('classification', () {
    Matcher refused(int status) => throwsA(
      isA<HouseholdMemberRefusedException>().having(
        (e) => e.statusCode,
        'statusCode',
        status,
      ),
    );
    final transient = throwsA(isA<HouseholdMemberTransientException>());
    final permanent = throwsA(isA<HouseholdMemberPermanentException>());

    test('no response at all is transient', () {
      final dio = Dio()..httpClientAdapter = _UnreachableAdapter();
      final remote = HouseholdMemberRemoteDataSourceImpl(dio);

      expect(remote.remove('h1', 'm1'), transient);
      expect(
        remote.changeRole('h1', 'm1', HouseholdRole.householdGuest),
        transient,
      );
    });

    for (final status in [500, 503, 401, 407, 408, 429]) {
      test('$status is transient', () {
        expect(
          answering(_envelope(status), status: status).remove('h1', 'm1'),
          transient,
        );
      });
    }

    test('a status that is no verdict is transient', () {
      expect(answering('', status: 302).remove('h1', 'm1'), transient);
    });

    test('a 409 saying retryable is transient', () {
      expect(
        answering(
          _envelope(409, {'retryable': true}),
          status: 409,
        ).remove('h1', 'm1'),
        transient,
      );
    });

    test('a 403 without the envelope is transient', () {
      expect(
        answering('<html>blocked</html>', status: 403).remove('h1', 'm1'),
        transient,
      );
    });

    test('a 404 without the envelope is transient', () {
      expect(
        answering('<html>missing</html>', status: 404).remove('h1', 'm1'),
        transient,
      );
      expect(
        answering(
          '<html>missing</html>',
          status: 404,
        ).changeRole('h1', 'm1', HouseholdRole.householdGuest),
        transient,
      );
    });

    for (final status in [400, 403, 409]) {
      test('an enveloped $status is a refusal', () {
        expect(
          answering(_envelope(status), status: status).remove('h1', 'm1'),
          refused(status),
        );
        expect(
          answering(
            _envelope(status),
            status: status,
          ).changeRole('h1', 'm1', HouseholdRole.householdGuest),
          refused(status),
        );
      });
    }

    test('a 404 with the envelope is a refusal', () {
      expect(
        answering(_envelope(404), status: 404).remove('h1', 'm1'),
        refused(404),
      );
      expect(
        answering(
          _envelope(404),
          status: 404,
        ).changeRole('h1', 'm1', HouseholdRole.householdGuest),
        refused(404),
      );
    });

    test('another 4xx is permanent', () {
      expect(
        answering(_envelope(422), status: 422).remove('h1', 'm1'),
        permanent,
      );
      expect(
        answering(_envelope(402), status: 402).remove('h1', 'm1'),
        permanent,
      );
      expect(
        answering(_envelope(410), status: 410).remove('h1', 'm1'),
        permanent,
      );
    });

    test('a 400 or 409 without the envelope is permanent', () {
      expect(
        answering('<html>no</html>', status: 400).remove('h1', 'm1'),
        permanent,
      );
      expect(
        answering('<html>no</html>', status: 409).remove('h1', 'm1'),
        permanent,
      );
    });

    test('a 2xx whose member does not parse is permanent', () {
      expect(answering('{"message": "ok"}').remove('h1', 'm1'), permanent);
      expect(answering('{"member": 1}').remove('h1', 'm1'), permanent);
      expect(
        answering('{"member": {"id": "m1"}}').remove('h1', 'm1'),
        permanent,
      );
      expect(
        answering(_answer(_member(user: 'ada')))
            .changeRole('h1', 'm1', HouseholdRole.householdGuest),
        permanent,
      );
    });

    test('a 2xx that is not a JSON object is permanent', () {
      expect(answering('').remove('h1', 'm1'), permanent);
      expect(answering('not json').remove('h1', 'm1'), permanent);
      expect(answering('[]').remove('h1', 'm1'), permanent);
    });
  });
}
