import 'feedback_category.dart';
import 'feedback_report.dart';
import 'feedback_severity.dart';

/// Assembles and submits [FeedbackReport]s (issue #8; "BugReportService"
/// in the original issue text, renamed alongside the model to match the
/// backend's generalised feedback domain).
///
/// The device-global service registered in the app-scope root container
/// (#72); the concrete [FeedbackServiceImpl] holds a late-bound transport
/// resolver (the network leg is per-server and post-auth) plus a durable
/// [FeedbackSink].
abstract class FeedbackService {
  /// Composes a submittable [FeedbackReport] from the pieces a caller
  /// has at hand when something goes wrong.
  ///
  /// Implementations are responsible for:
  ///
  /// - **Message composition**: [FeedbackReport.message] is
  ///   [errorMessage] then [userComment] (error text leads, comment
  ///   follows); the **stack trace is NOT woven into the message** — it
  ///   goes to the dedicated [FeedbackReport.stackTrace] field (backend
  ///   #77), tail-truncated to [FeedbackConstants.maxStackTraceLength].
  ///   At least one of [errorMessage]/[userComment] must be non-empty
  ///   (the model requires a non-empty message).
  /// - **Environment stamping**: filling `appVersion`, `platform`,
  ///   `locale`, and `deviceInfo` from an injected environment value.
  /// - **Context capture**: snapshotting the breadcrumb trail into
  ///   [FeedbackReport.breadcrumbs] at build time — not at submit time,
  ///   which for an offline-queued report could be hours later with the
  ///   relevant crumbs long since evicted — trimmed oldest-first to
  ///   [FeedbackConstants.maxBreadcrumbsBytes].
  ///
  /// [severity] must be supplied when [category] is crash or bug
  /// (constructor assert on the model).
  ///
  /// [correlationKey] is the idempotency token for the offline queue;
  /// implementations generate one (cuid2, matching the repo's id
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

  /// Submits [report], returning whether it was [FeedbackSubmitResult.sent]
  /// to the server or [FeedbackSubmitResult.queued] to the durable sink
  /// for a later drain (offline, or no authenticated server).
  ///
  /// Implementations run [FeedbackReport.validate] first and throw
  /// [FeedbackSubmissionException] on violations rather than letting the
  /// backend reject the payload. A transport failure falls back to the
  /// sink (→ [FeedbackSubmitResult.queued]); the exception surfaces only
  /// when both the transport and the sink fail.
  Future<FeedbackSubmitResult> submit(FeedbackReport report);

  /// Attempts to send every report the sink has queued, removing each on
  /// success and returning the number sent. Best-effort and sequential:
  /// stops at the first failure, leaving that report and the rest
  /// persisted for the next attempt. A no-op when no transport is
  /// available. The trigger (auth success / session restore) is wired by
  /// the auth layer (#37), not here.
  Future<int> drainPending();
}

/// The outcome of [FeedbackService.submit] — the prompt uses this to tell
/// the user the truth ("sent" vs "saved, will send later"; on web the
/// latter only lasts until reload).
enum FeedbackSubmitResult {
  /// Delivered to the server (201).
  sent,

  /// Persisted to the durable sink for a later [FeedbackService.drainPending].
  queued,
}

/// Thrown by [FeedbackService.submit] when a report cannot be submitted
/// (validation failure, or transport failure that the sink could not
/// absorb).
class FeedbackSubmissionException implements Exception {
  const FeedbackSubmissionException(this.message, {this.cause});

  /// Human-readable description of the failure.
  final String message;

  /// The underlying error, when one exists (e.g. a DioException).
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'FeedbackSubmissionException: $message'
      : 'FeedbackSubmissionException: $message (cause: $cause)';
}
