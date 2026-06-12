import 'feedback_category.dart';
import 'feedback_report.dart';
import 'feedback_severity.dart';

/// Assembles and submits [FeedbackReport]s (issue #8; "BugReportService"
/// in the original issue text, renamed alongside the model to match the
/// backend's generalised feedback domain).
///
/// Interface only — concrete implementations (network submission via the
/// DioFactory stack, offline queueing, the always-available local-file
/// sink) are a separate issue. The contract below is what those
/// implementations must honour.
abstract class FeedbackService {
  /// Composes a submittable [FeedbackReport] from the pieces a caller
  /// has at hand when something goes wrong.
  ///
  /// Implementations are responsible for:
  ///
  /// - **Message composition**: weaving [errorMessage], [stackTrace],
  ///   and [userComment] into [FeedbackReport.message] (truncating
  ///   against the protocol caps as needed — the stack trace is the
  ///   piece to trim first, tail-preserved, since the throw site is at
  ///   the top).
  /// - **Environment stamping**: filling `appVersion`, `platform`,
  ///   `locale`, and `deviceInfo` from platform info providers.
  /// - **Context capture**: snapshotting the BreadcrumbBuffer into
  ///   [FeedbackReport.breadcrumbs] at build time — not at submit time,
  ///   which for an offline-queued report could be hours later with the
  ///   relevant crumbs long since evicted.
  ///
  /// [severity] must be supplied when [category] is crash or bug
  /// (constructor assert on the model).
  ///
  /// [correlationKey] is the idempotency token for the offline queue;
  /// implementations should generate one (cuid2, matching the repo's id
  /// convention) when the caller doesn't supply it.
  FeedbackReport buildReport({
    required FeedbackCategory category,
    FeedbackSeverity? severity,
    String? title,
    String? errorMessage,
    String? stackTrace,
    String? userComment,
    String? correlationKey,
  });

  /// Submits [report] to the active server's feedback endpoint.
  ///
  /// Implementations should run [FeedbackReport.validate] first and
  /// throw [FeedbackSubmissionException] on violations rather than
  /// letting the backend reject the payload. Network-layer failures
  /// surface as [FeedbackSubmissionException] with the underlying error
  /// as [FeedbackSubmissionException.cause]; offline-queueing
  /// implementations resolve once the report is durably enqueued.
  Future<void> submit(FeedbackReport report);
}

/// Thrown by [FeedbackService.submit] when a report cannot be submitted
/// (validation failure, transport failure, or queue persistence failure).
class FeedbackSubmissionException implements Exception {
  const FeedbackSubmissionException(this.message, {this.cause});

  /// Human-readable description of the failure.
  final String message;

  /// The underlying error, when one exists (e.g. a DioException).
  final Object? cause;

  @override
  String toString() => 'FeedbackSubmissionException: $message';
}
