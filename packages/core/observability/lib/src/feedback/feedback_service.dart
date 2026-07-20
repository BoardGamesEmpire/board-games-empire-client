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
  /// for a later drain (offline, unauthenticated, or no active server).
  ///
  /// Implementations run [FeedbackReport.validate] first and throw
  /// [FeedbackPermanentSubmissionException] on violations rather than
  /// letting the backend reject the payload. Failure taxonomy (#97):
  /// a **transient** transport failure falls back to the sink
  /// (→ [FeedbackSubmitResult.queued], tagged with the active server's
  /// `bgeServerId` when one exists); a **permanent** rejection surfaces
  /// to the caller un-queued; [FeedbackPersistenceException] surfaces
  /// when the sink itself fails.
  Future<FeedbackSubmitResult> submit(FeedbackReport report);

  /// Attempts to send the queued reports belonging to the active server
  /// (records tagged with its `bgeServerId`, plus untagged records
  /// approved when no server was active — device-global diagnostics),
  /// removing each on success and returning the number sent.
  ///
  /// Best-effort and sequential (#97): a **transient** failure —
  /// including 429, respecting the backend throttle — stops the drain,
  /// leaving that record and the rest persisted for the next attempt. A
  /// **permanent** rejection drops the record (it can never succeed, and
  /// keeping it would build an un-drainable backlog) and continues.
  /// Records tagged for a different server are never touched. A no-op
  /// when no transport is available. Overlapping calls coalesce into the
  /// in-flight run (the trigger legitimately fires on duplicate auth
  /// signals). The trigger (auth success / session restore) is wired by
  /// the auth layer, not here.
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

/// Failure taxonomy for feedback submission (#97), matching the
/// [AuthException] sealed-hierarchy style.
///
/// Three modes:
///
/// - [FeedbackTransientSubmissionException] — **retryable**: offline /
///   connection errors, timeouts, cancellation, 401 (session expired
///   between resolve and send), 408, 429 (throttle), and 5xx. `submit`
///   falls back to the durable sink for these; `drainPending` stops on
///   them (covering the 429-stop requirement) and leaves the record
///   persisted for the next opportunity.
/// - [FeedbackPermanentSubmissionException] — will **never** succeed on
///   retry: 400 (validation), 403 (feedback-banned), and every other
///   4xx. `submit` surfaces these to the caller without queueing
///   (queueing would mislead the user with "will send later" and build
///   an un-drainable backlog); `drainPending` drops the record.
/// - [FeedbackPersistenceException] — the third mode: the report could
///   not even be **persisted** to the sink. Not a server rejection; the
///   sink fault is the primary [cause], with any prior transport failure
///   carried alongside as [FeedbackPersistenceException.transportCause]
///   for telemetry.
sealed class FeedbackSubmissionException implements Exception {
  const FeedbackSubmissionException(this.message, {this.cause});

  /// Human-readable description of the failure.
  final String message;

  /// The underlying error, when one exists (e.g. a DioException).
  final Object? cause;

  @override
  String toString() => cause == null
      ? '$runtimeType: $message'
      : '$runtimeType: $message (cause: $cause)';
}

/// A retryable submission failure — offline, timeout, cancellation, 401,
/// 408, 429, or 5xx. Queue-and-drain-later is the correct response.
final class FeedbackTransientSubmissionException
    extends FeedbackSubmissionException {
  const FeedbackTransientSubmissionException(
    super.message, {
    super.cause,
    this.statusCode,
  });

  /// The HTTP status that classified as transient (401 / 408 / 429 /
  /// 5xx), or null for connection-level failures with no response.
  final int? statusCode;
}

/// A permanent server rejection — 400, 403, or any other 4xx. Retrying
/// can never succeed; the report must not be queued.
final class FeedbackPermanentSubmissionException
    extends FeedbackSubmissionException {
  const FeedbackPermanentSubmissionException(
    super.message, {
    super.cause,
    this.statusCode,
  });

  /// The rejecting HTTP status, or null when the rejection did not come
  /// off the wire (e.g. client-side validation in `submit`).
  final int? statusCode;
}

/// The report could not be persisted to the durable sink — the "couldn't
/// even queue" mode, distinct from any server rejection.
final class FeedbackPersistenceException extends FeedbackSubmissionException {
  const FeedbackPersistenceException(
    super.message, {
    super.cause,
    this.transportCause,
  });

  /// The transport failure that preceded the queue attempt, when one
  /// occurred (null when queueing was the first resort — no transport
  /// available). The sink fault itself is [cause].
  final Object? transportCause;
}
