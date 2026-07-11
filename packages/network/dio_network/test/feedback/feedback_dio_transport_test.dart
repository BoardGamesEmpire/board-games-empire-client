import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:observability/observability.dart';

/// Wire contract (resolved from backend source): `POST /feedback/reports`
/// → 201. The path is relative — the per-server Dio carries the base URL
/// (path-prefix deployments included), and the existing per-server auth
/// plumbing attaches the BetterAuth session (the endpoint requires it:
/// CASL `create:feedback_report`, 30/user/hour throttle). This transport
/// therefore adds no auth handling of its own — construction from an
/// active server context is #37's wiring.
class _MockDio extends Mock implements Dio {}

void main() {
  const report = FeedbackReport(
    category: FeedbackCategory.crash,
    severity: FeedbackSeverity.critical,
    message: 'It broke',
    stackTrace: '#0 main (file.dart:1)',
    correlationKey: 'key-1',
  );

  late _MockDio dio;

  setUp(() {
    dio = _MockDio();
  });

  Response<dynamic> response(int statusCode) => Response<dynamic>(
    requestOptions: RequestOptions(path: '/feedback/reports'),
    statusCode: statusCode,
  );

  group('FeedbackDioTransport', () {
    test('is a FeedbackTransport', () {
      expect(FeedbackDioTransport(dio), isA<FeedbackTransport>());
    });

    test('POSTs the report JSON to /feedback/reports and completes on '
        '201', () async {
      when(
        () => dio.post<dynamic>(any(), data: any<dynamic>(named: 'data')),
      ).thenAnswer((_) async => response(201));

      await FeedbackDioTransport(dio).send(report);

      verify(
        () => dio.post<dynamic>('/feedback/reports', data: report.toJson()),
      ).called(1);
    });

    test('wraps a DioException in FeedbackSubmissionException with the '
        'cause attached', () async {
      final dioError = DioException(
        requestOptions: RequestOptions(path: '/feedback/reports'),
        type: DioExceptionType.connectionError,
      );
      when(
        () => dio.post<dynamic>(any(), data: any<dynamic>(named: 'data')),
      ).thenThrow(dioError);

      await expectLater(
        FeedbackDioTransport(dio).send(report),
        throwsA(
          isA<FeedbackSubmissionException>().having(
            (e) => e.cause,
            'cause',
            same(dioError),
          ),
        ),
      );
    });

    test('wraps any unexpected error the same way — send never leaks a '
        'raw exception type to the service', () async {
      when(
        () => dio.post<dynamic>(any(), data: any<dynamic>(named: 'data')),
      ).thenThrow(StateError('unexpected'));

      await expectLater(
        FeedbackDioTransport(dio).send(report),
        throwsA(isA<FeedbackSubmissionException>()),
      );
    });
  });
}
