import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';

import 'package:dio_network/src/network/clock_skew_interceptor.dart';

/// Captures recordSample calls without any estimation logic.
class _RecordingRecorder implements ClockSkewRecorder {
  final List<({DateTime serverDate, DateTime sentAt, DateTime receivedAt})>
  samples = [];

  @override
  void recordSample({
    required DateTime serverDate,
    required DateTime requestSentAt,
    required DateTime responseReceivedAt,
  }) {
    samples.add((
      serverDate: serverDate,
      sentAt: requestSentAt,
      receivedAt: responseReceivedAt,
    ));
  }
}

/// Stub adapter returning a canned response with configurable headers,
/// capturing the outgoing [RequestOptions] (token_interceptor_test
/// pattern).
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({this.responseHeaders = const {}});

  final Map<String, List<String>> responseHeaders;
  RequestOptions? captured;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured = options;
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...responseHeaders,
      },
    );
  }
}

void main() {
  final t0 = DateTime.utc(2026, 7, 21, 12);
  final t1 = t0.add(const Duration(milliseconds: 200));
  // Date headers carry one-second resolution; use a truncated instant
  // so format → parse round-trips exactly.
  final serverDate = DateTime.utc(2026, 7, 21, 11, 55);

  late _RecordingRecorder recorder;

  Dio buildDio(_StubAdapter adapter) {
    // Clock stamps in call order: onRequest pops t0, onResponse pops t1.
    final stamps = [t0, t1];
    return Dio(
        BaseOptions(
          baseUrl: 'https://api.example.com',
          validateStatus: (_) => true,
        ),
      )
      ..httpClientAdapter = adapter
      ..interceptors.add(
        ClockSkewInterceptor(
          recorder: recorder,
          nowUtc: () => stamps.removeAt(0),
        ),
      );
  }

  setUp(() => recorder = _RecordingRecorder());

  group('ClockSkewInterceptor', () {
    test('stamps the raw local send time into RequestOptions.extra', () async {
      final adapter = _StubAdapter(
        responseHeaders: {
          HttpHeaders.dateHeader: [HttpDate.format(serverDate)],
        },
      );

      await buildDio(adapter).get<dynamic>('/anything');

      expect(adapter.captured?.extra[ClockSkewInterceptor.sentAtKey], t0);
    });

    test('records one sample from a response carrying a Date header', () async {
      final adapter = _StubAdapter(
        responseHeaders: {
          HttpHeaders.dateHeader: [HttpDate.format(serverDate)],
        },
      );

      await buildDio(adapter).get<dynamic>('/anything');

      expect(recorder.samples, hasLength(1));
      final sample = recorder.samples.single;
      expect(sample.serverDate.toUtc(), serverDate);
      expect(sample.sentAt, t0);
      expect(sample.receivedAt, t1);
    });

    test('skips silently when the Date header is absent', () async {
      final adapter = _StubAdapter();

      final response = await buildDio(adapter).get<dynamic>('/anything');

      expect(recorder.samples, isEmpty);
      expect(response.statusCode, 200, reason: 'response still delivered');
    });

    test('skips silently when the Date header is malformed', () async {
      final adapter = _StubAdapter(
        responseHeaders: {
          HttpHeaders.dateHeader: ['not-a-date'],
        },
      );

      final response = await buildDio(adapter).get<dynamic>('/anything');

      expect(recorder.samples, isEmpty);
      expect(response.statusCode, 200);
    });
  });
}
