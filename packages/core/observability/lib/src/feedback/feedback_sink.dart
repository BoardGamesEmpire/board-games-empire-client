import 'feedback_report.dart';

/// Durable store for **user-approved** feedback reports that couldn't be
/// sent yet — offline, or with no authenticated server (#69).
///
/// The #34 privacy contract (nothing persists without explicit review +
/// approval) is upheld by the approval gate upstream, not by this
/// interface; by the time a report reaches [persist] the user has
/// approved it. Reports are keyed by [FeedbackReport.correlationKey]
/// (the idempotency token), so a later drain racing a resubmission can't
/// duplicate server-side.
///
/// Implementations: `FileFeedbackSink` (native, durable JSON files) and
/// `MemoryFeedbackSink` (the web stand-in until #63, and the
/// resolve-or-default fallback).
abstract interface class FeedbackSink {
  /// Persists [report]. Throws [ArgumentError] if it has no
  /// [FeedbackReport.correlationKey] — the sink is keyed by it.
  Future<void> persist(FeedbackReport report);

  /// All currently-queued reports.
  Future<List<FeedbackReport>> pending();

  /// Removes the report with [correlationKey]; a no-op if none matches.
  Future<void> remove(String correlationKey);
}
