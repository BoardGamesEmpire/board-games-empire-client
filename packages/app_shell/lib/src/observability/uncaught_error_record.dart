import 'package:observability/observability.dart';

/// Immutable, RAM-only record of the last uncaught error (issue #34).
///
/// One instance feeds two consumers: `ShellObservability`'s single-slot
/// last-error notifier (read later by the alpha "ask each time" feedback
/// prompt) and the injectable `UncaughtErrorReporter` seam.
///
/// ## Sanitisation at capture
///
/// [message] is the error's `toString()` run through
/// [Redaction.redactEmailsIn] at construction — matching the
/// BreadcrumbBuffer's capture-time philosophy, so nothing downstream has
/// to remember to redact. The raw error object is deliberately **not**
/// retained: keeping it would reintroduce the unredacted text through the
/// back door.
///
/// ## Stack traces
///
/// [stackTrace] is kept verbatim — it is the one piece
/// `FeedbackService.buildReport` needs untouched (tail-preserving
/// truncation against protocol caps happens there, not here). Traces are
/// not pattern-redacted anywhere; the privacy control is that this record
/// lives only in RAM and never persists to disk, so it is wiped when the
/// OS ends the process. It leaves the device only inside a feedback
/// report the user has explicitly reviewed and submitted.
final class UncaughtErrorRecord {
  /// Captures [error] and [stackTrace], redacting the error text now.
  ///
  /// [timestamp] defaults to construction time; injectable for tests.
  UncaughtErrorRecord.capture(
    Object error,
    this.stackTrace, {
    DateTime? timestamp,
  }) : message = Redaction.redactEmailsIn(error.toString()),
       errorType = error.runtimeType.toString(),
       timestamp = timestamp ?? DateTime.now();

  /// The error's `toString()`, email-redacted at capture.
  final String message;

  /// The error's runtime type name (e.g. `StateError`) — safe to put in
  /// breadcrumb context and report titles without leaking message
  /// contents.
  final String errorType;

  /// The stack trace exactly as thrown. Never logged into the breadcrumb
  /// ring; see the class docs for where it is (and isn't) allowed to go.
  final StackTrace stackTrace;

  /// When the error was captured.
  final DateTime timestamp;

  /// Deliberately excludes [message] and [stackTrace] so an incidental
  /// `toString()` (interpolation, `Object?` logging) can't re-leak
  /// details outside the reviewed feedback path.
  @override
  String toString() => 'UncaughtErrorRecord($errorType at $timestamp)';
}
