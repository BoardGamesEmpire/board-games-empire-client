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
  /// [clientRequestId] is the idempotency token for the offline queue;
  /// implementations generate one (cuid2, matching the repo's id
  /// convention) when the caller doesn't supply it. It doubles as the
  /// durable sink's address for the record, so implementations must
  /// generate a value usable as one.
  FeedbackReport buildReport({
    required FeedbackCategory category,
    FeedbackSeverity? severity,
    String? title,
    String? errorMessage,
    String? stackTrace,
    String? userComment,
    String? clientRequestId,
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
  /// Delivered to the server (a 2xx that looked like the API answering;
  /// the documented success status is 201).
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
///   between resolve and send), 408, 429 (throttle), 5xx, and — via its
///   subtype [FeedbackUnverifiedDeliveryException] — a 2xx whose body does
///   not look like the API answering (#358, #363). That last one is a
///   *smell test, not proof*: it catches the common interception shape — a
///   page where a payload belongs — but a truncated genuine response lands
///   in it too, and that report DID arrive. Transient is chosen for exactly
///   that reason: re-sending a delivered report is recoverable (the backend
///   dedupes on `clientRequestId`), discarding an undelivered one is not.
///   `submit` falls back to the durable sink for these. `drainPending`
///   stops the whole run on them — covering the 429-stop requirement — and
///   leaves the record persisted for the next opportunity, **except** for
///   [FeedbackUnverifiedDeliveryException]: that one describes a single
///   response rather than the server or the network, so the drain counts an
///   attempt against the record and carries on to the next (#359).
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
/// 408, 429, or 5xx. Queue-and-drain-later is the correct response, and
/// `drainPending` stops its run on one.
///
/// A 2xx whose body does not look like the API answering is raised as the
/// subtype [FeedbackUnverifiedDeliveryException], not as this class, and
/// the drain treats it differently — see there.
final class FeedbackTransientSubmissionException
    extends FeedbackSubmissionException {
  const FeedbackTransientSubmissionException(
    super.message, {
    super.cause,
    this.statusCode,
  });

  /// The status the response carried, or null when there was no response
  /// (connection-level failures).
  ///
  /// Usually the status that classified the failure — 401 / 408 / 429 / 5xx.
  /// Not always: on an undecodable 2xx (#358) the status is context and the
  /// classification came from the body, and a device-local decode fault
  /// reports the 2xx it was reading. Do not read this field as "the server
  /// said this was transient".
  final int? statusCode;
}

/// A 2xx whose body does not look like the API answering, so delivery could
/// not be confirmed (#358, #363).
///
/// **A refinement of [FeedbackTransientSubmissionException], not a fourth
/// mode.** Everything the transient contract promises still holds — the
/// report is retryable, `submit` queues it, and it is never discarded — and
/// every existing `on FeedbackTransientSubmissionException` site keeps
/// catching it. What the subtype adds is a fact only the drain needs: this
/// failure is a statement about *one response*, not about the server or the
/// connection.
///
/// That distinction is what lets `drainPending` skip the record and keep
/// going, where a throttle, an offline device or a 5xx must stop the whole
/// run (#359). Reading it off [statusCode] instead would mean
/// treating a 2xx status as the signal — precisely the inference
/// [FeedbackTransientSubmissionException.statusCode]'s own doc warns
/// against, and correct only until another branch carries a 2xx.
///
/// Raised for: a page where a payload belongs, a body that is not JSON, a
/// body that is JSON but not an object, and an empty or whitespace-only
/// body. The messages stay distinct so a log still says which happened.
///
/// **Not** raised for a failure to *perform* the decode — in practice no
/// offload isolate available under memory pressure. That says nothing about
/// the response, only that the device is out of room, and every record
/// behind it in a drain would fail identically, so it stays the plain
/// [FeedbackTransientSubmissionException]: the run stops and no attempt is
/// counted (#359).
final class FeedbackUnverifiedDeliveryException
    extends FeedbackTransientSubmissionException {
  const FeedbackUnverifiedDeliveryException(
    super.message, {
    super.cause,
    super.statusCode,
  });
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
