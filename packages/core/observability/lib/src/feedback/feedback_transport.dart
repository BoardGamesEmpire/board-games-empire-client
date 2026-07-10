import 'feedback_report.dart';
import 'feedback_service.dart';

/// Sends a [FeedbackReport] to a server's feedback endpoint (#69).
///
/// Deliberately minimal and **per-server**: the concrete implementation
/// (`FeedbackDioTransport` in `dio_network`) posts through the active
/// server context's authenticated Dio — the endpoint requires a
/// BetterAuth session (CASL `create:feedback_report`), which the
/// per-server Dio already attaches. The device-global [FeedbackService]
/// holds a resolver that yields the active server's transport or null (no
/// authenticated server → the report is queued to the durable sink).
///
/// Implementations wrap any failure as [FeedbackSubmissionException] so
/// the service never sees a raw transport exception type.
abstract interface class FeedbackTransport {
  /// Posts [report]; completes on success, throws
  /// [FeedbackSubmissionException] on any failure.
  Future<void> send(FeedbackReport report);
}
