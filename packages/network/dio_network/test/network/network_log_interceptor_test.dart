import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:observability/observability.dart';

import 'package:dio_network/src/network/network_log_interceptor.dart';

/// Minimal adapter: returns a response with a scripted status/body, or
/// throws a scripted [DioException] to exercise the transport-failure path.
class _StubAdapter implements HttpClientAdapter {
  int status = 200;
  DioException? error;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final err = error;
    if (err != null) throw err;
    return ResponseBody.fromString(
      '{}',
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> sub;
  late Level previous;

  setUp(() {
    records = [];
    previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    sub = Logger.root.onRecord.listen(records.add);
  });
  tearDown(() async {
    await sub.cancel();
    Logger.root.level = previous;
  });

  // Mirror DefaultDioFactory: validateStatus:(_)=>true means 4xx/5xx come
  // back as a Response (through onResponse), never as a throw.
  Dio buildDio(_StubAdapter adapter, {bool traceRequests = true}) =>
      Dio(BaseOptions(baseUrl: 'https://api.test', validateStatus: (_) => true))
        ..httpClientAdapter = adapter
        ..interceptors.add(NetworkLogInterceptor(traceRequests: traceRequests));

  Iterable<Map<String, dynamic>> contextsOf(Iterable<LogRecord> rs) =>
      rs.map(LogRecordFormatter.contextOf).whereType<Map<String, dynamic>>();

  test('logs request + response at debug with a redacted URI', () async {
    final dio = buildDio(_StubAdapter());

    await dio.get<dynamic>('/session', queryParameters: {'token': 'secret'});

    final debug = records.where((r) => r.level == Level.FINE).toList();
    expect(debug, isNotEmpty);
    final uris = contextsOf(
      debug,
    ).map((c) => c['uri']).whereType<String>().toList();
    expect(uris, contains('https://api.test/session'));
    // The query secret is never present in any logged context.
    expect(contextsOf(records).toString(), isNot(contains('secret')));
  });

  test(
    'logs a 5xx response at warn, even when tracing is off (ungated)',
    () async {
      final adapter = _StubAdapter()..status = 503;
      final dio = buildDio(adapter, traceRequests: false);

      await dio.get<dynamic>('/session');

      final warns = records.where((r) => r.level == Level.WARNING).toList();
      expect(warns, hasLength(1));
      expect(LogRecordFormatter.contextOf(warns.single)?['status'], 503);
      // A 5xx is not a transport failure, so nothing logs at error.
      expect(records.where((r) => r.level == Level.SEVERE), isEmpty);
    },
  );

  test('a 4xx response is not warned at the transport layer', () async {
    final adapter = _StubAdapter()..status = 401;
    final dio = buildDio(adapter);

    await dio.get<dynamic>('/session');

    expect(records.where((r) => r.level == Level.WARNING), isEmpty);
  });

  test('logs a transport failure at error with the dio error type', () async {
    final adapter = _StubAdapter();
    final dio = buildDio(adapter);
    adapter.error = DioException.connectionError(
      requestOptions: RequestOptions(path: '/session'),
      reason: 'no route to host',
    );

    await expectLater(
      dio.get<dynamic>('/session'),
      throwsA(isA<DioException>()),
    );

    final errors = records.where((r) => r.level == Level.SEVERE).toList();
    expect(errors, hasLength(1));
    expect(
      LogRecordFormatter.contextOf(errors.single)?['dio_error_type'],
      'connectionError',
    );
  });

  test(
    'suppresses request/response debug when traceRequests is false',
    () async {
      final dio = buildDio(_StubAdapter(), traceRequests: false);

      await dio.get<dynamic>('/session');

      expect(records.where((r) => r.level == Level.FINE), isEmpty);
    },
  );
}
