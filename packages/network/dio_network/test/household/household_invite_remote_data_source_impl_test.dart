import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// An invite row as the backend's `householdInviteSelect` renders it at
/// `c119cedb`.
Map<String, dynamic> _row({
  String id = 'i_1',
  String status = 'Pending',
  String? inviteeName = 'Ana',
  Object? role = const {'id': 'r_1', 'name': 'HouseholdMember'},
  Object? inviterProfile = const {'avatarUrl': null, 'displayName': 'Bo B'},
  Map<String, dynamic> extra = const {},
}) => {
  'id': id,
  'status': status,
  'type': 'Direct',
  'inviteeName': inviteeName,
  'expiresAt': '2026-10-26T10:00:00.000Z',
  'createdAt': '2026-10-19T10:00:00.000Z',
  'role': role,
  'inviter': {'id': 'u_1', 'username': 'bo', 'profile': inviterProfile},
  ...extra,
};

String _list(
  String key,
  List<Map<String, dynamic>> rows, {
  int total = 2,
  bool hasMore = false,
}) => jsonEncode({
  key: rows,
  'pagination': {
    'page': 1,
    'limit': 25,
    'total': total,
    'totalPages': 1,
    'hasMore': hasMore,
  },
});

String _single(
  Map<String, dynamic> row, [
  Map<String, dynamic> extra = const {},
]) => jsonEncode({'message': 'translated', 'invite': row, ...extra});

/// Nest's rendering of an `HttpException` carrying a message.
String _envelope(int status, [Map<String, dynamic> extra = const {}]) =>
    jsonEncode({
      'statusCode': status,
      'message': 'translated',
      'error': 'Error',
      ...extra,
    });

typedef _Sent = ({
  String method,
  String path,
  Map<String, dynamic> query,
  Object? body,
});

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
    sent.add((
      method: options.method,
      path: options.path,
      query: options.queryParameters,
      body: requestBody,
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

  HouseholdInviteRemoteDataSource answering(String body, {int status = 200}) {
    adapter = _RecordingAdapter(body, status);
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
    return HouseholdInviteRemoteDataSourceImpl(dio);
  }

  group('send', () {
    test('invites a user by id, sending no empty optional field', () async {
      final remote = answering(_single(_row()), status: 201);

      final invite = await remote.send(
        'hh_1',
        HouseholdInviteDraft(invitee: const InviteeUser('u_2')),
      );

      expect(adapter.sent.single.method, 'POST');
      expect(adapter.sent.single.path, '/api/households/hh_1/invites');
      expect(adapter.sent.single.body, {
        'inviteeId': 'u_2',
        'role': 'HouseholdMember',
      });
      expect(invite.id, 'i_1');
      expect(invite.status, HouseholdInviteStatus.pending);
      expect(invite.role, HouseholdRole.householdMember);
      expect(invite.inviteeName, 'Ana');
      expect(
        invite.inviter,
        const UserSummary(id: 'u_1', username: 'bo', displayName: 'Bo B'),
      );
      expect(invite.expiresAt, DateTime.utc(2026, 10, 26, 10));
      expect(invite.createdAt, DateTime.utc(2026, 10, 19, 10));
    });

    test('invites an address with a name, a role and a message', () async {
      final remote = answering(_single(_row()), status: 201);

      await remote.send(
        'hh_1',
        HouseholdInviteDraft(
          invitee: InviteeEmail('a@b.c'),
          inviteeName: 'Ana',
          role: HouseholdRole.householdGuest,
          message: 'hi',
        ),
      );

      expect(adapter.sent.single.body, {
        'inviteeEmail': 'a@b.c',
        'inviteeName': 'Ana',
        'role': 'HouseholdGuest',
        'message': 'hi',
      });
    });
  });

  group('fetchHouseholdInvites', () {
    test('asks for every status unless one is given', () async {
      final remote = answering(_list('invites', [_row()], total: 1));

      await remote.fetchHouseholdInvites('hh_1');

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/households/hh_1/invites');
      expect(adapter.sent.single.query, {'page': 1, 'limit': 25});
    });

    test('sends the status filter when one is given', () async {
      final remote = answering(_list('invites', [_row()], total: 1));

      await remote.fetchHouseholdInvites(
        'hh_1',
        status: HouseholdInviteStatus.awaitingApproval,
        page: 2,
        limit: 1,
      );

      expect(adapter.sent.single.query, {
        'page': 2,
        'limit': 1,
        'status': 'AwaitingApproval',
      });
    });

    test('maps a page of rows and its paging', () async {
      final remote = answering(
        _list(
          'invites',
          [
            _row(inviteeName: null, extra: {'inviteeEmail': 'a@b.c'}),
            _row(id: 'i_2', status: 'AwaitingApproval', inviterProfile: null),
          ],
          total: 7,
          hasMore: true,
        ),
      );

      final page = await remote.fetchHouseholdInvites('hh_1');

      expect(page.meta.total, 7);
      expect(page.meta.hasMore, isTrue);
      expect(page.items, hasLength(2));
      expect(page.items[0].inviteeEmail, 'a@b.c');
      expect(page.items[0].inviteeLabel, 'a@b.c');
      expect(page.items[0].message, isNull);
      expect(page.items[1].status, HouseholdInviteStatus.awaitingApproval);
      expect(page.items[1].inviter.displayName, isNull);
      expect(page.items[1].inviter.label, 'bo');
    });

    test('keeps a row with no role as a row with no role', () async {
      final remote = answering(_list('invites', [_row(role: null)], total: 1));

      final page = await remote.fetchHouseholdInvites('hh_1');

      expect(page.items.single.role, isNull);
    });

    test('refuses a status filter of unknown before any request', () {
      final remote = answering(_list('invites', const [], total: 0));

      expect(
        () => remote.fetchHouseholdInvites(
          'hh_1',
          status: HouseholdInviteStatus.unknown,
        ),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });
  });

  group('fetchInbox', () {
    test('names each row\'s household', () async {
      final remote = answering(
        _list('invites', [
          _row(
            extra: {
              'message': 'Come play',
              'household': {'id': 'hh_9', 'name': 'Sunday Crew'},
            },
          ),
        ], total: 1),
      );

      final page = await remote.fetchInbox();

      expect(adapter.sent.single.path, '/api/invites');
      expect(adapter.sent.single.query, {'page': 1, 'limit': 25});
      expect(page.items.single.householdId, 'hh_9');
      expect(page.items.single.householdName, 'Sunday Crew');
      expect(page.items.single.message, 'Come play');
    });
  });

  group('fetchSent', () {
    test('asks for open and expired unless a status is given', () async {
      final remote = answering(_list('invites', const [], total: 0));

      await remote.fetchSent();

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/invites/sent');
      expect(adapter.sent.single.query, {'page': 1, 'limit': 25});
    });

    test('sends the status filter when one is given', () async {
      final remote = answering(_list('invites', const [], total: 0));

      await remote.fetchSent(
        status: HouseholdInviteStatus.revoked,
        page: 2,
        limit: 1,
      );

      expect(adapter.sent.single.query, {
        'page': 2,
        'limit': 1,
        'status': 'Revoked',
      });
    });

    test('names each row\'s household and reads its status', () async {
      final remote = answering(
        _list('invites', [
          _row(
            status: 'Expired',
            extra: {
              'household': {'id': 'hh_9', 'name': 'Sunday Crew'},
            },
          ),
        ], total: 1),
      );

      final page = await remote.fetchSent();

      expect(page.items.single.status, HouseholdInviteStatus.expired);
      expect(page.items.single.householdId, 'hh_9');
      expect(page.items.single.householdName, 'Sunday Crew');
    });

    test('refuses a status filter of unknown before any request', () {
      final remote = answering(_list('invites', const [], total: 0));

      expect(
        () => remote.fetchSent(status: HouseholdInviteStatus.unknown),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });
  });

  group('answers and actions', () {
    test(
      'accept returns the accepted invite and the household joined',
      () async {
        final remote = answering(
          _single(_row(status: 'Accepted'), {
            'member': {'id': 'm_1', 'householdId': 'hh_9', 'userId': 'u_2'},
          }),
        );

        final accepted = await remote.accept('i_1');

        expect(adapter.sent.single.method, 'POST');
        expect(adapter.sent.single.path, '/api/invites/i_1/accept');
        expect(accepted.invite.status, HouseholdInviteStatus.accepted);
        expect(accepted.householdId, 'hh_9');
      },
    );

    test('an accept answer without the membership is permanent', () {
      final remote = answering(_single(_row(status: 'Accepted')));

      expect(
        remote.accept('i_1'),
        throwsA(isA<HouseholdInvitePermanentException>()),
      );
    });

    final paths =
        <
          String,
          Future<HouseholdInvite> Function(HouseholdInviteRemoteDataSource)
        >{
          '/api/invites/a%2Fb/decline': (r) => r.decline('a/b'),
          '/api/invites/a%2Fb/withdraw': (r) => r.withdraw('a/b'),
          '/api/households/h%2F1/invites/a%2Fb/revoke': (r) =>
              r.revoke('h/1', 'a/b'),
          '/api/households/h%2F1/invites/a%2Fb/approve': (r) =>
              r.approve('h/1', 'a/b'),
        };
    for (final MapEntry(key: path, value: call) in paths.entries) {
      test('posts $path and maps the answer', () async {
        final remote = answering(_single(_row(status: 'Revoked')));

        final invite = await call(remote);

        expect(adapter.sent.single.method, 'POST');
        expect(adapter.sent.single.path, path);
        expect(invite.status, HouseholdInviteStatus.revoked);
      });
    }
  });

  group('paging guards', () {
    test('refuses page 0 before any request', () {
      final remote = answering(_list('invites', const [], total: 0));

      expect(() => remote.fetchInbox(page: 0), throwsArgumentError);
      expect(() => remote.fetchSent(page: 0), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test('refuses a limit over 100 before any request', () {
      final remote = answering(_list('invites', const [], total: 0));

      expect(
        () => remote.fetchHouseholdInvites('hh_1', limit: 101),
        throwsArgumentError,
      );
      expect(() => remote.fetchSent(limit: 101), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });
  });

  group('classification', () {
    Matcher refused(int status) => throwsA(
      isA<HouseholdInviteRefusedException>().having(
        (e) => e.statusCode,
        'statusCode',
        status,
      ),
    );
    final transient = throwsA(isA<HouseholdInviteTransientException>());
    final permanent = throwsA(isA<HouseholdInvitePermanentException>());

    test('no response at all is transient', () {
      final dio = Dio()..httpClientAdapter = _UnreachableAdapter();
      final remote = HouseholdInviteRemoteDataSourceImpl(dio);

      expect(remote.withdraw('i_1'), transient);
    });

    for (final status in [500, 503, 401, 407, 408, 429]) {
      test('$status is transient', () {
        expect(
          answering(_envelope(status), status: status).withdraw('i_1'),
          transient,
        );
      });
    }

    test('a 409 saying retryable is transient', () {
      expect(
        answering(
          _envelope(409, {'retryable': true}),
          status: 409,
        ).withdraw('i_1'),
        transient,
      );
    });

    for (final status in [403, 404]) {
      test('a $status without the envelope is transient', () {
        expect(
          answering('<html>blocked</html>', status: status).withdraw('i_1'),
          transient,
        );
      });
    }

    test('an enveloped 404 from a list route is transient', () {
      expect(answering(_envelope(404), status: 404).fetchInbox(), transient);
      expect(answering(_envelope(404), status: 404).fetchSent(), transient);
      expect(
        answering(_envelope(404), status: 404).fetchHouseholdInvites('hh_1'),
        transient,
      );
    });

    for (final status in [400, 403, 409, 410]) {
      test('an enveloped $status is a refusal', () {
        expect(
          answering(_envelope(status), status: status).withdraw('i_1'),
          refused(status),
        );
      });
    }

    test('an enveloped 404 from a route naming an invite is a refusal', () {
      expect(
        answering(_envelope(404), status: 404).revoke('hh_1', 'i_1'),
        refused(404),
      );
      expect(
        answering(
          _envelope(404),
          status: 404,
        ).send('hh_1', HouseholdInviteDraft(invitee: const InviteeUser('u_2'))),
        refused(404),
      );
    });

    test('a 402 carries the limit it hit', () async {
      final remote = answering(
        jsonEncode({
          'statusCode': 402,
          'error': 'Quota Exceeded',
          'message': 'translated',
          'resource': 'household_invite_daily_count',
          'scope': 'User',
          'limit': 10,
          'currentUsage': 10,
          'attemptedAmount': 1,
        }),
        status: 402,
      );

      final error = await remote
          .send('hh_1', HouseholdInviteDraft(invitee: const InviteeUser('u_2')))
          .then<HouseholdInviteRefusedException?>((_) => null)
          .onError<HouseholdInviteRefusedException>((e, _) => e);

      expect(error?.statusCode, 402);
      expect(error?.quota?.resource, 'household_invite_daily_count');
      expect(error?.quota?.scope, 'User');
    });

    test('a refusal never carries a quota but a 402\'s', () async {
      final error = await answering(_envelope(409), status: 409)
          .withdraw('i_1')
          .then<HouseholdInviteRefusedException?>((_) => null)
          .onError<HouseholdInviteRefusedException>((e, _) => e);

      expect(error?.quota, isNull);
    });

    test('another 4xx is permanent', () {
      expect(answering(_envelope(422), status: 422).withdraw('i_1'), permanent);
      expect(
        answering('<html>no</html>', status: 400).withdraw('i_1'),
        permanent,
      );
    });

    test('a 2xx that is not the contract is permanent', () {
      expect(answering('{"invite": 1}').withdraw('i_1'), permanent);
      expect(answering('not json').withdraw('i_1'), permanent);
      expect(answering('{"invites": []}').fetchInbox(), permanent);
    });
  });
}
