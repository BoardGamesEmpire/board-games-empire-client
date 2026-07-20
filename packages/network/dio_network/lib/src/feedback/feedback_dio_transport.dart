import 'package:dio/dio.dart';
import 'package:observability/observability.dart';

/// Concrete [FeedbackTransport] posting through a **per-server** Dio
/// instance (#69, #97).
///
/// Wire contract (backend `libs/api/feedback`): `POST /feedback/reports`
/// → 201. The path is relative — the per-server Dio carries the base URL
/// (path-prefix deployments included), and the existing per-server auth
/// plumbing attaches the BetterAuth session the endpoint requires (CASL
/// `create:feedback_report`; feedback-banned users get 403; throttled at
/// 30/user/hour → 429). This class adds no auth handling of its own; it
/// is constructed from the per-server container by the network installer
/// and resolved via the active server's `FeedbackTargetResolver`.
///
/// ## Failure classification (#97)
///
/// Every failure is wrapped per the [FeedbackTransport] contract — the
/// service never sees a raw transport exception type — and classified:
///
/// - [FeedbackTransientSubmissionException] (**retryable**): connection
///   errors, all timeouts, cancellation, 401 (a session can expire
///   between resolve and send), 408, 429 (throttle — the drain stops
///   here), all 5xx, and any failure without a response status
///   (including certificate errors, which can be a captive portal —
///   discarding a user-approved report on one would be wrong).
/// - [FeedbackPermanentSubmissionException]: 400 (validation), 403
///   (feedback-banned), and every other 4xx — retrying can never
///   succeed, so the service must not queue these.
class FeedbackDioTransport implements FeedbackTransport {
  const FeedbackDioTransport(this._dio);

  final Dio _dio;

  /// 4xx statuses that are nonetheless worth retrying: an expired
  /// session (401), a request timeout (408), and the throttle (429).
  static const Set<int> _retryable4xx = {401, 408, 429};

  @override
  Future<void> send(FeedbackReport report) async {
    try {
      final response = await _dio.post<dynamic>(
        '/feedback/reports',
        data: report.toJson(),
      );
      // Defensive: Dio throws on non-2xx by default, but a custom
      // validateStatus on the injected instance must not turn a
      // rejection into a silent "sent". Classify like the exception
      // path so the taxonomy holds regardless of Dio configuration. A
      // null status is not a fabricated 0: no server verdict exists, so
      // it classifies transient with no statusCode, same as the
      // connection-level path.
      final status = response.statusCode;
      if (status == null) {
        throw const FeedbackTransientSubmissionException(
          'Feedback endpoint returned no status',
        );
      }
      if (status < 200 || status >= 300) {
        throw _classifyStatus(
          status,
          'Feedback endpoint returned $status',
          cause: null,
        );
      }
    } on FeedbackSubmissionException {
      rethrow;
    } on DioException catch (error) {
      throw _classifyDioException(error);
    } on Object catch (error) {
      // Contract breach territory (nothing else should escape Dio), so
      // stay conservative: transient keeps the user-approved report
      // queued and retriable instead of silently dropped.
      throw FeedbackTransientSubmissionException(
        'Feedback submission failed unexpectedly',
        cause: error,
      );
    }
  }

  /// Classifies [error] per the #97 table. A response status, when
  /// present, is authoritative; without one the failure is a
  /// connection-level fault and always transient.
  FeedbackSubmissionException _classifyDioException(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return _classifyStatus(
        status,
        'Feedback submission failed with status $status',
        cause: error,
      );
    }
    // connectionTimeout / sendTimeout / receiveTimeout / connectionError /
    // cancel / badCertificate / unknown — no server verdict exists, so
    // the report stays retryable.
    return FeedbackTransientSubmissionException(
      'Feedback submission failed',
      cause: error,
    );
  }

  FeedbackSubmissionException _classifyStatus(
    int status,
    String message, {
    required Object? cause,
  }) {
    final transient = status >= 500 || _retryable4xx.contains(status);
    if (transient) {
      return FeedbackTransientSubmissionException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    if (status >= 400) {
      return FeedbackPermanentSubmissionException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    // A non-2xx, non-4xx/5xx status (1xx/3xx surfaced by a permissive
    // validateStatus) carries no rejection semantics — transient.
    return FeedbackTransientSubmissionException(
      message,
      cause: cause,
      statusCode: status,
    );
  }
}
