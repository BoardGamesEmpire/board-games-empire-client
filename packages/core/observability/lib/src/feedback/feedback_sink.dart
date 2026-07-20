import 'queued_feedback_report.dart';

/// Durable store for **user-approved** feedback reports that couldn't be
/// sent yet — offline, unauthenticated, or with no active server (#69,
/// #97).
///
/// The #34 privacy contract (nothing persists without explicit review +
/// approval) is upheld by the approval gate upstream, not by this
/// interface; by the time a record reaches [persist] the user has
/// approved it. Records are keyed by [QueuedFeedbackReport.correlationKey]
/// (the idempotency token), so a later drain racing a resubmission can't
/// duplicate server-side.
///
/// Records are [QueuedFeedbackReport] envelopes (#97): the report plus
/// the `bgeServerId` it was approved for (null = no active server), so
/// the drain can gate on the active server and one server's reports
/// never drain into another.
///
/// Implementations: `FileFeedbackSink` (native, durable JSON files) and
/// `MemoryFeedbackSink` (the web stand-in until #63, and the
/// resolve-or-default fallback).
abstract interface class FeedbackSink {
  /// Persists [record]. Throws [ArgumentError] if its report has no
  /// correlationKey — the sink is keyed by it.
  Future<void> persist(QueuedFeedbackReport record);

  /// All currently-queued records.
  Future<List<QueuedFeedbackReport>> pending();

  /// Removes the record with [correlationKey]; a no-op if none matches.
  Future<void> remove(String correlationKey);
}
