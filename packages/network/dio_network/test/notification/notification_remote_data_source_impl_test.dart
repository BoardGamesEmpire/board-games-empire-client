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

typedef _Sent = ({String method, String path, Object? data});

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
    sent.add((method: options.method, path: options.path, data: options.data));
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
    // The body without `userId` is deliberate: see the interface's markRead
    // doc and BoardGamesEmpire/board-games-empire-backend#584.
    test('posts the ids', () async {
      final remote = answering('', status: 201);

      await remote.markRead(['n1']);

      expect(adapter.sent.single.method, 'POST');
      expect(adapter.sent.single.path, '/api/notifications/mark-read');
      expect(adapter.sent.single.data, {
        'notificationIds': ['n1'],
      });
    });

    test('an empty list is an ArgumentError with nothing sent', () async {
      final remote = answering('', status: 201);

      await expectLater(remote.markRead([]), throwsA(isA<ArgumentError>()));
      expect(adapter.sent, isEmpty);
    });

    test('a 503 is transient', () async {
      final remote = answering('', status: 503);

      await expectLater(
        remote.markRead(['n1']),
        throwsA(isA<NotificationTransientException>()),
      );
    });
  });
}
