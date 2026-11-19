import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';

// BetterAuth wire shape, as the native repository's suite has it.
Map<String, dynamic> _sessionJson() => {
  'session': {
    'id': 'sess-1',
    'token': 'session-tok-renewed',
    'expiresAt': '2099-01-01T00:00:00.000Z',
    'userId': 'user-1',
  },
  'user': {
    'id': 'user-1',
    'name': 'testuser',
    'email': 'test@example.com',
    'emailVerified': true,
    'createdAt': '2024-01-01T00:00:00.000Z',
    'updatedAt': '2024-01-01T00:00:00.000Z',
  },
};

Response<String> _response(int? status, [String? data]) => Response(
  data: data,
  statusCode: status,
  requestOptions: RequestOptions(path: '/api/auth/get-session'),
);

void main() {
  group('readSessionResponse', () {
    late List<bool> supersededAnswers;
    late int supersededCalls;
    late int decodeCalls;

    setUp(() {
      supersededAnswers = [];
      supersededCalls = 0;
      decodeCalls = 0;
    });

    // Answers from [supersededAnswers] in turn, then false.
    bool superseded() {
      final call = supersededCalls++;
      return call < supersededAnswers.length && supersededAnswers[call];
    }

    Future<Object?> countingDecode(String raw) {
      decodeCalls++;
      return decodeJsonBody(raw);
    }

    Future<SessionRead> read(
      Response<String> response, {
      Future<Object?> Function(String)? decode,
    }) => readSessionResponse(
      response,
      decode: decode ?? countingDecode,
      superseded: superseded,
    );

    test('200 with a session body is found', () async {
      final result = await read(_response(200, jsonEncode(_sessionJson())));

      expect(result, isA<SessionReadFound>());
      final found = result as SessionReadFound;
      expect(found.response.session.token, 'session-tok-renewed');
      expect(found.response.user.id, 'user-1');
    });

    for (final status in [401, 403]) {
      test('$status is no session', () async {
        final result = await read(_response(status, 'ignored'));

        expect(
          result,
          isA<SessionReadNoSession>().having((r) => r.status, 'status', status),
        );
        expect(decodeCalls, 0);
      });
    }

    test('200 with an empty body is no session', () async {
      final result = await read(_response(200, ''));

      expect(
        result,
        isA<SessionReadNoSession>().having((r) => r.status, 'status', 200),
      );
    });

    test('200 with a JSON null is no session', () async {
      final result = await read(_response(200, 'null'));

      expect(
        result,
        isA<SessionReadNoSession>().having((r) => r.status, 'status', 200),
      );
    });

    test('502 with no body throws a server fault, not no session', () async {
      await expectLater(
        read(_response(502)),
        throwsA(
          isA<AuthServerException>().having(
            (e) => e.statusCode,
            'statusCode',
            502,
          ),
        ),
      );
    });

    test('200 with HTML throws a server fault', () async {
      await expectLater(
        read(_response(200, '<html><body>Sign in to Wi-Fi</body></html>')),
        throwsA(
          isA<AuthServerException>().having(
            (e) => e.message,
            'message',
            contains('not JSON'),
          ),
        ),
      );
    });

    test('a decode that cannot run throws AuthLocalDecodeException', () async {
      await expectLater(
        read(
          _response(200, jsonEncode(_sessionJson())),
          decode: (_) => throw StateError('isolate would not spawn'),
        ),
        throwsA(isA<AuthLocalDecodeException>()),
      );
    });

    test('200 with a JSON list throws not-an-object', () async {
      await expectLater(
        read(_response(200, '[]')),
        throwsA(
          isA<AuthServerException>()
              .having(
                (e) => e.message,
                'message',
                'The session endpoint returned a body that is not a JSON '
                    'object.',
              )
              .having((e) => e.statusCode, 'statusCode', 200),
        ),
      );
    });

    test('200 with an object missing session throws unreadable', () async {
      await expectLater(
        read(_response(200, jsonEncode({'user': _sessionJson()['user']}))),
        throwsA(
          isA<AuthServerException>()
              .having(
                (e) => e.message,
                'message',
                'The session endpoint returned an unreadable response.',
              )
              .having((e) => e.statusCode, 'statusCode', 200)
              .having((e) => e.cause, 'cause', isNotNull),
        ),
      );
    });

    test('superseded at the response checkpoint wins over a 401', () async {
      supersededAnswers = [true];

      final result = await read(_response(401));

      expect(
        result,
        isA<SessionReadSuperseded>().having(
          (r) => r.checkpoint,
          'checkpoint',
          SessionReadCheckpoint.response,
        ),
      );
      expect(decodeCalls, 0);
    });

    test(
      'superseded at the decode checkpoint wins over a decode failure',
      () async {
        supersededAnswers = [false, true];

        final result = await read(_response(200, '<html></html>'));

        expect(
          result,
          isA<SessionReadSuperseded>().having(
            (r) => r.checkpoint,
            'checkpoint',
            SessionReadCheckpoint.decode,
          ),
        );
      },
    );

    test(
      'superseded at the decode checkpoint wins over a found session',
      () async {
        supersededAnswers = [false, true];

        final result = await read(_response(200, jsonEncode(_sessionJson())));

        expect(
          result,
          isA<SessionReadSuperseded>().having(
            (r) => r.checkpoint,
            'checkpoint',
            SessionReadCheckpoint.decode,
          ),
        );
      },
    );

    test('superseded is asked exactly twice on a found session', () async {
      await read(_response(200, jsonEncode(_sessionJson())));

      expect(supersededCalls, 2);
    });
  });
}
