import 'dart:convert';
import 'dart:typed_data';

import 'package:bge_test_support/network.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

Map<String, dynamic> _entry(String id, {String type = 'MailTestResult'}) => {
  'id': id,
  'type': type,
  'payload': {'outcome': 'sent', 'message': 'ok'},
  'read': false,
  'createdAt': '2026-11-12T10:30:00.000Z',
};

class _MockDio extends Mock implements Dio {}

/// A real Dio whose every request is answered with no status, before it
/// reaches an adapter.
Dio _statuslessDio(String body) => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response<String>(requestOptions: options, data: body),
      ),
    ),
  );

const Object _unset = Object();

typedef _Sent = ({
  String method,
  String path,
  Object? data,
  Map<String, dynamic> query,
});

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
      data: options.data,
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

  NotificationRemoteDataSource answering(String body, {int status = 200}) {
    adapter = _RecordingAdapter(body, status);
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
    return NotificationRemoteDataSourceImpl(dio);
  }

  group('fetchUnread', () {
    test('maps the entries in order', () async {
      final remote = answering(jsonEncode([_entry('n2'), _entry('n1')]));

      final unread = await remote.fetchUnread();

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/notifications/unread');
      expect(unread, [
        UnreadNotification(
          id: 'n2',
          type: 'MailTestResult',
          payload: const {'outcome': 'sent', 'message': 'ok'},
          createdAt: DateTime.utc(2026, 11, 12, 10, 30),
        ),
        UnreadNotification(
          id: 'n1',
          type: 'MailTestResult',
          payload: const {'outcome': 'sent', 'message': 'ok'},
          createdAt: DateTime.utc(2026, 11, 12, 10, 30),
        ),
      ]);
    });

    test('an empty array is no notifications', () async {
      final remote = answering('[]');

      expect(await remote.fetchUnread(), isEmpty);
    });

    test('a top-level object is permanent', () async {
      final remote = answering(jsonEncode({'notifications': <Object>[]}));

      await expectLater(
        remote.fetchUnread(),
        throwsA(isA<NotificationPermanentException>()),
      );
    });

    test(
      'an entry with no payload fails the whole read as permanent',
      () async {
        final bad = _entry('n2')..remove('payload');
        final remote = answering(jsonEncode([_entry('n1'), bad]));

        await expectLater(
          remote.fetchUnread(),
          throwsA(isA<NotificationPermanentException>()),
        );
      },
    );

    test(
      'an entry whose id is not a string fails the whole read as permanent',
      () async {
        final bad = _entry('n2')..['id'] = 42;
        final remote = answering(jsonEncode([_entry('n1'), bad]));

        await expectLater(
          remote.fetchUnread(),
          throwsA(isA<NotificationPermanentException>()),
        );
      },
    );

    test(
      'an entry whose createdAt is not a date fails the whole read as '
      'permanent',
      () async {
        final bad = _entry('n2')..['createdAt'] = 'yesterday';
        final remote = answering(jsonEncode([_entry('n1'), bad]));

        await expectLater(
          remote.fetchUnread(),
          throwsA(isA<NotificationPermanentException>()),
        );
      },
    );

    test(
      'an entry that is not an object fails the whole read as permanent',
      () async {
        final remote = answering(jsonEncode([_entry('n1'), 'n2']));

        await expectLater(
          remote.fetchUnread(),
          throwsA(isA<NotificationPermanentException>()),
        );
      },
    );

    test('a body that is not JSON is permanent', () async {
      final remote = answering('<html></html>');

      await expectLater(
        remote.fetchUnread(),
        throwsA(isA<NotificationPermanentException>()),
      );
    });

    test('a 500 is transient', () async {
      final remote = answering('oops', status: 500);

      await expectLater(
        remote.fetchUnread(),
        throwsA(isA<NotificationTransientException>()),
      );
    });

    test('a 400 is permanent', () async {
      final remote = answering('{}', status: 400);

      await expectLater(
        remote.fetchUnread(),
        throwsA(isA<NotificationPermanentException>()),
      );
    });

    test('an empty body is permanent', () async {
      final remote = answering('');

      await expectLater(
        remote.fetchUnread(),
        throwsA(isA<NotificationPermanentException>()),
      );
    });

    test('an unreachable server is transient', () async {
      final remote = NotificationRemoteDataSourceImpl(
        unreachableDio(DioExceptionType.connectionError),
      );

      await expectLater(
        remote.fetchUnread(),
        throwsA(isA<NotificationTransientException>()),
      );
    });

    test('a response with no status is transient', () async {
      final remote = NotificationRemoteDataSourceImpl(_statuslessDio('[]'));

      await expectLater(
        remote.fetchUnread(),
        throwsA(isA<NotificationTransientException>()),
      );
    });

    test("a failure that is not Dio's is transient", () async {
      final dio = _MockDio();
      when(
        () => dio.get<String>(any(), options: any(named: 'options')),
      ).thenThrow(StateError('boom'));

      await expectLater(
        NotificationRemoteDataSourceImpl(dio).fetchUnread(),
        throwsA(isA<NotificationTransientException>()),
      );
    });
  });

  group('markRead', () {
    // The server takes the ids alone.
    test('posts the ids', () async {
      final remote = answering('');

      await remote.markRead(['n1']);

      expect(adapter.sent.single.method, 'POST');
      expect(adapter.sent.single.path, '/api/notifications/mark-read');
      expect(adapter.sent.single.data, {
        'notificationIds': ['n1'],
      });
    });

    test('an empty list is an ArgumentError with nothing sent', () async {
      final remote = answering('');

      await expectLater(remote.markRead([]), throwsA(isA<ArgumentError>()));
      expect(adapter.sent, isEmpty);
    });

    test('refuses more than 100 ids before any request', () async {
      final remote = answering('');
      final ids = [for (var i = 0; i < 101; i++) 'n$i'];

      await expectLater(remote.markRead(ids), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test('sends exactly 100 ids', () async {
      final remote = answering('');
      final ids = [for (var i = 0; i < 100; i++) 'n$i'];

      await remote.markRead(ids);

      expect(adapter.sent.single.data, {'notificationIds': ids});
    });

    test('a 503 is transient', () async {
      final remote = answering('', status: 503);

      await expectLater(
        remote.markRead(['n1']),
        throwsA(isA<NotificationTransientException>()),
      );
    });
  });

  group('markAllRead', () {
    test('posts to /api/notifications/mark-all-read with no body', () async {
      final remote = answering('');

      await remote.markAllRead();

      expect(adapter.sent.single.method, 'POST');
      expect(adapter.sent.single.path, '/api/notifications/mark-all-read');
      expect(adapter.sent.single.data, isNull);
    });

    // The shared rules read a 401 as an expired session a later attempt can
    // survive, so it is transient, not permanent.
    test('maps 401 to NotificationTransientException', () async {
      final remote = answering('', status: 401);

      await expectLater(
        remote.markAllRead(),
        throwsA(isA<NotificationTransientException>()),
      );
    });

    test('maps a 400 to NotificationPermanentException', () async {
      final remote = answering('{}', status: 400);

      await expectLater(
        remote.markAllRead(),
        throwsA(isA<NotificationPermanentException>()),
      );
    });

    test('maps a timeout to NotificationTransientException', () async {
      final remote = NotificationRemoteDataSourceImpl(
        unreachableDio(DioExceptionType.receiveTimeout),
      );

      await expectLater(
        remote.markAllRead(),
        throwsA(isA<NotificationTransientException>()),
      );
    });
  });

  group('fetchPage', () {
    Map<String, dynamic> page(
      List<Map<String, dynamic>> notifications, {
      String? nextCursor,
      Object? pagination = _unset,
    }) => {
      'notifications': notifications,
      'pagination': identical(pagination, _unset)
          ? {
              'limit': 25,
              'hasMore': nextCursor != null,
              'nextCursor': nextCursor,
            }
          : pagination,
    };

    test(
      'sends limit and the cursor as query parameters, the cursor unchanged',
      () async {
        final remote = answering(jsonEncode(page([])));

        await remote.fetchPage(cursor: 'a b+c/d=', limit: 10);

        expect(adapter.sent.single.method, 'GET');
        expect(adapter.sent.single.path, '/api/notifications');
        expect(adapter.sent.single.query, {'limit': 10, 'cursor': 'a b+c/d='});
      },
    );

    test('leaves the cursor out on the first page', () async {
      final remote = answering(jsonEncode(page([])));

      await remote.fetchPage();

      expect(adapter.sent.single.query, {
        'limit': NotificationRemoteDataSource.defaultPageSize,
      });
    });

    test(
      'parses notifications with read and readAt, readAt null while unread',
      () async {
        final read = _entry('n1')
          ..['read'] = true
          ..['readAt'] = '2026-11-13T08:00:00.000Z';
        final unread = _entry('n2')..['readAt'] = null;
        final remote = answering(
          jsonEncode(page([read, unread], nextCursor: 'c')),
        );

        final result = await remote.fetchPage();

        expect(result.items, [
          UserNotification(
            id: 'n1',
            type: 'MailTestResult',
            payload: const {'outcome': 'sent', 'message': 'ok'},
            read: true,
            readAt: DateTime.utc(2026, 11, 13, 8),
            createdAt: DateTime.utc(2026, 11, 12, 10, 30),
          ),
          UserNotification(
            id: 'n2',
            type: 'MailTestResult',
            payload: const {'outcome': 'sent', 'message': 'ok'},
            read: false,
            createdAt: DateTime.utc(2026, 11, 12, 10, 30),
          ),
        ]);
        expect(result.nextCursor, 'c');
        expect(result.hasMore, isTrue);
      },
    );

    test('a null pagination.nextCursor means no more', () async {
      final remote = answering(jsonEncode(page([_entry('n1')])));

      final result = await remote.fetchPage();

      expect(result.nextCursor, isNull);
      expect(result.hasMore, isFalse);
    });

    test('refuses a limit of 0 or 101 before any request', () async {
      final remote = answering(jsonEncode(page([])));

      await expectLater(remote.fetchPage(limit: 0), throwsArgumentError);
      await expectLater(remote.fetchPage(limit: 101), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test(
      'a 400 for a malformed cursor is NotificationPermanentException',
      () async {
        final remote = answering('{}', status: 400);

        await expectLater(
          remote.fetchPage(cursor: 'garbage'),
          throwsA(isA<NotificationPermanentException>()),
        );
      },
    );

    // One entry the client can't read must not fail the list (#475): a
    // payload it can't read is a plain row, and an entry it can neither show
    // nor mark is left out. Only a broken envelope fails the page.
    test(
      'a payload that is not an object reads as an empty payload',
      () async {
        final missing = _entry('n1')..remove('payload');
        final text = _entry('n2')..['payload'] = 'sent';
        final list = _entry('n3')..['payload'] = [1, 2];
        final nul = _entry('n4')..['payload'] = null;
        final remote = answering(
          jsonEncode(page([missing, text, list, nul, _entry('n5')])),
        );

        final result = await remote.fetchPage();

        expect(result.items.map((n) => n.id), ['n1', 'n2', 'n3', 'n4', 'n5']);
        expect(
          result.items.take(4).map((n) => n.payload),
          everyElement(isEmpty),
        );
        expect(result.items.last.payload, {'outcome': 'sent', 'message': 'ok'});
      },
    );

    test('a read that is not a bool follows readAt', () async {
      final readAtOnly = _entry('n1')
        ..['read'] = 'yes'
        ..['readAt'] = '2026-11-13T08:00:00.000Z';
      final neither = _entry('n2')..remove('read');
      final remote = answering(jsonEncode(page([readAtOnly, neither])));

      final result = await remote.fetchPage();

      expect(result.items.map((n) => n.read), [true, false]);
      expect(result.items.first.readAt, DateTime.utc(2026, 11, 13, 8));
    });

    test('a readAt that is missing or unparseable is null', () async {
      final missing = _entry('n1')..['read'] = true;
      final garbage = _entry('n2')
        ..['read'] = true
        ..['readAt'] = 'yesterday';
      final number = _entry('n3')
        ..['read'] = true
        ..['readAt'] = 42;
      final remote = answering(jsonEncode(page([missing, garbage, number])));

      final result = await remote.fetchPage();

      expect(result.items.map((n) => n.readAt), [null, null, null]);
      expect(result.items.map((n) => n.read), [true, true, true]);
    });

    test(
      'an entry whose id, type or createdAt cannot be read is left out',
      () async {
        final remote = answering(
          jsonEncode(
            page([
              _entry('n1'),
              _entry('n2')..remove('id'),
              _entry('n3')..['id'] = 3,
              _entry('n4')..remove('type'),
              _entry('n5')..['type'] = ['MailTestResult'],
              _entry('n6')..remove('createdAt'),
              _entry('n7')..['createdAt'] = 'last week',
              _entry('n8')..['createdAt'] = 1700000000,
              _entry('n9'),
            ]),
          ),
        );

        final result = await remote.fetchPage();

        expect(result.items.map((n) => n.id), ['n1', 'n9']);
      },
    );

    test('an entry that is not an object is left out', () async {
      final remote = answering(
        jsonEncode({
          'notifications': [_entry('n1'), 'n2', null, 7, _entry('n3')],
          'pagination': {'limit': 25, 'hasMore': false, 'nextCursor': null},
        }),
      );

      final result = await remote.fetchPage();

      expect(result.items.map((n) => n.id), ['n1', 'n3']);
    });

    test(
      'a nextCursor that is not a string fails the page as '
      'NotificationPermanentException',
      () async {
        for (final cursor in [7, true, <String, dynamic>{}]) {
          final remote = answering(
            jsonEncode(
              page(
                [_entry('n1')],
                pagination: {
                  'limit': 25,
                  'hasMore': true,
                  'nextCursor': cursor,
                },
              ),
            ),
          );

          await expectLater(
            remote.fetchPage(),
            throwsA(isA<NotificationPermanentException>()),
            reason: '$cursor',
          );
        }
      },
    );

    test(
      'a body with no notifications array, or no pagination object, is '
      'NotificationPermanentException',
      () async {
        for (final body in [
          {'pagination': <String, dynamic>{}},
          {'notifications': <Object>[]},
          {'notifications': <Object>[], 'pagination': 'next'},
          {'notifications': 'none', 'pagination': <String, dynamic>{}},
        ]) {
          final remote = answering(jsonEncode(body));

          await expectLater(
            remote.fetchPage(),
            throwsA(isA<NotificationPermanentException>()),
            reason: '$body',
          );
        }
      },
    );
  });

  group('fetchUnreadCount', () {
    test('reads count from GET /api/notifications/unread/count', () async {
      final remote = answering(jsonEncode({'count': 7}));

      expect(await remote.fetchUnreadCount(), 7);
      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/notifications/unread/count');
    });

    test(
      'a count that is not a non-negative integer is '
      'NotificationPermanentException',
      () async {
        for (final count in <Object?>[-1, 1.5, '3', null]) {
          final remote = answering(jsonEncode({'count': count}));

          await expectLater(
            remote.fetchUnreadCount(),
            throwsA(isA<NotificationPermanentException>()),
            reason: '$count',
          );
        }
      },
    );

    test('a timeout is NotificationTransientException', () async {
      final remote = NotificationRemoteDataSourceImpl(
        unreachableDio(DioExceptionType.connectionTimeout),
      );

      await expectLater(
        remote.fetchUnreadCount(),
        throwsA(isA<NotificationTransientException>()),
      );
    });
  });
}
