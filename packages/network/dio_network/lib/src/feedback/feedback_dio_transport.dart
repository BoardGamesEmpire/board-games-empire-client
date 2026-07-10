import 'package:dio/dio.dart';
import 'package:observability/observability.dart';

/// Concrete [FeedbackTransport] posting through a **per-server** Dio
/// instance (#69).
///
/// Wire contract (backend `libs/api/feedback`): `POST /feedback/reports`
/// → 201. The path is relative — the per-server Dio carries the base URL
/// (path-prefix deployments included), and the existing per-server auth
/// plumbing attaches the BetterAuth session the endpoint requires (CASL
/// `create:feedback_report`; feedback-banned users get 403; throttled at
/// 30/user/hour → 429). This class adds no auth handling of its own;
/// constructing it from the active server context is #37's wiring, which
/// also hooks `FeedbackService.drainPending` to auth success.
///
/// Every failure — Dio-level or unexpected — is wrapped as
/// [FeedbackSubmissionException] per the [FeedbackTransport] contract, so
/// the service never sees a raw transport exception type.
class FeedbackDioTransport implements FeedbackTransport {
  const FeedbackDioTransport(this._dio);

  final Dio _dio;

  @override
  Future<void> send(FeedbackReport report) async {
    try {
      final response = await _dio.post<dynamic>(
        '/feedback/reports',
        data: report.toJson(),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        // Defensive: Dio throws on non-2xx by default, but a custom
        // validateStatus on the injected instance must not turn a
        // rejection into a silent "sent".
        throw FeedbackSubmissionException('Feedback endpoint returned $status');
      }
    } on FeedbackSubmissionException {
      rethrow;
    } on DioException catch (error) {
      throw FeedbackSubmissionException(
        'Feedback submission failed',
        cause: error,
      );
    } on Object catch (error) {
      throw FeedbackSubmissionException(
        'Feedback submission failed unexpectedly',
        cause: error,
      );
    }
  }
}
