import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:observability/observability.dart';

/// Wire contract (resolved from backend source): `POST /api/feedback/reports`
/// → 201. The path is relative — the per-server Dio carries the base URL
/// (path-prefix deployments included), and the existing per-server auth
/// plumbing attaches the BetterAuth session (the endpoint requires it:
/// CASL `create:feedback_report`, 30/user/hour throttle → 429,
/// feedback-banned → 403). Registration into the per-server container is
/// the network installer's (#97).
///
/// Classification table pinned (#97):
///
/// | failure                                   | classified as |
/// |-------------------------------------------|---------------|
/// | connection error / timeouts / cancel      | transient     |
/// | badCertificate / unknown (no status)      | transient     |
/// | 401, 408, 429                             | transient     |
/// | 5xx                                       | transient     |
/// | 400, 403, and every other 4xx             | permanent     |
///
/// These cases stub `Dio` itself, so Dio's own body handling never runs.
/// The cases that need it — a body Dio cannot decode, and an unparseable
/// 2xx that must not read as "sent" (#358) — drive a real `Dio` in
/// `feedback_dio_transport_body_test.dart`.
class _MockDio extends Mock implements Dio {}

void main() {
  const report = FeedbackReport(
    category: FeedbackCategory.crash,
    severity: FeedbackSeverity.critical,
    message: 'It broke',
    stackTrace: '#0 main (file.dart:1)',
    clientRequestId: 'key-1',
  );

  late _MockDio dio;

  setUp(() {
    dio = _MockDio();
  });

  RequestOptions options() => RequestOptions(path: '/api/feedback/reports');

  Response<String> response(int statusCode) =>
      Response<String>(requestOptions: options(), statusCode: statusCode);

  DioException statusError(int statusCode) => DioException(
    requestOptions: options(),
    type: DioExceptionType.badResponse,
    response: response(statusCode),
  );

  DioException typedError(DioExceptionType type) =>
      DioException(requestOptions: options(), type: type);

  void stubThrow(Object error) => when(
    () => dio.post<String>(
      any(),
      data: any<dynamic>(named: 'data'),
      options: any(named: 'options'),
    ),
  ).thenThrow(error);

  Future<void> send() => FeedbackDioTransport(dio).send(report);

  group('FeedbackDioTransport', () {
    test('is a FeedbackTransport', () {
      expect(FeedbackDioTransport(dio), isA<FeedbackTransport>());
    });

    test('POSTs the report JSON to /api/feedback/reports and completes on '
        '201', () async {
      when(
        () => dio.post<String>(
          any(),
          data: any<dynamic>(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => response(201));

      await send();

      final captured = verify(
        () => dio.post<String>(
          '/api/feedback/reports',
          data: report.toJson(),
          options: captureAny(named: 'options'),
        ),
      ).captured.single;

      // Pinned here, not left to `any(named: 'options')`, because this suite
      // owns the call shape. `responseType` is part of the fix, not a
      // detail: leaving it to the injected Dio lets a bytes/stream instance
      // drive Dio's own cast and lose the status again (#358).
      expect(
        (captured as Options?)?.responseType,
        ResponseType.plain,
        reason: 'the transport must pin responseType, not inherit it',
      );
    });

    group('classifies as transient (retryable)', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.connectionError,
        DioExceptionType.cancel,
        DioExceptionType.badCertificate,
        DioExceptionType.unknown,
      ]) {
        test('$type (no response status)', () async {
          final error = typedError(type);
          stubThrow(error);

          await expectLater(
            send(),
            throwsA(
              isA<FeedbackTransientSubmissionException>()
                  .having((e) => e.cause, 'cause', same(error))
                  .having((e) => e.statusCode, 'statusCode', isNull),
            ),
          );
        });
      }

      for (final status in [401, 408, 429, 500, 502, 503]) {
        test('HTTP $status', () async {
          stubThrow(statusError(status));

          await expectLater(
            send(),
            throwsA(
              isA<FeedbackTransientSubmissionException>().having(
                (e) => e.statusCode,
                'statusCode',
                status,
              ),
            ),
          );
        });
      }
    });

    group('classifies as permanent (never queued, never retried)', () {
      for (final status in [400, 403, 404, 413, 422]) {
        test('HTTP $status', () async {
          stubThrow(statusError(status));

          await expectLater(
            send(),
            throwsA(
              isA<FeedbackPermanentSubmissionException>().having(
                (e) => e.statusCode,
                'statusCode',
                status,
              ),
            ),
          );
        });
      }
    });

    test('attaches the DioException as cause on the status path '
        'too', () async {
      final error = statusError(403);
      stubThrow(error);

      await expectLater(
        send(),
        throwsA(
          isA<FeedbackSubmissionException>().having(
            (e) => e.cause,
            'cause',
            same(error),
          ),
        ),
      );
    });

    test('wraps any unexpected error as transient — send never leaks a '
        'raw exception type, and an approved report is never dropped on '
        'a contract breach', () async {
      stubThrow(StateError('unexpected'));

      await expectLater(
        send(),
        throwsA(
          isA<FeedbackTransientSubmissionException>().having(
            (e) => e.cause,
            'cause',
            isA<StateError>(),
          ),
        ),
      );
    });

    test('classifies a non-2xx status surfaced by a permissive '
        'validateStatus instead of treating it as sent — a rejection '
        'must never look like success', () async {
      when(
        () => dio.post<String>(
          any(),
          data: any<dynamic>(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => response(403));

      await expectLater(
        send(),
        throwsA(
          isA<FeedbackPermanentSubmissionException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
    });

    test('a response with NO statusCode classifies transient with a '
        'null statusCode — never a fabricated 0', () async {
      when(
        () => dio.post<String>(
          any(),
          data: any<dynamic>(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => Response<String>(requestOptions: options()));

      await expectLater(
        send(),
        throwsA(
          isA<FeedbackTransientSubmissionException>().having(
            (e) => e.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
    });

    test('a permissive-validateStatus 5xx classifies transient the same '
        'as the exception path', () async {
      when(
        () => dio.post<String>(
          any(),
          data: any<dynamic>(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => response(503));

      await expectLater(
        send(),
        throwsA(
          isA<FeedbackTransientSubmissionException>().having(
            (e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    });
  });
}
