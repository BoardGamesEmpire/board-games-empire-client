import 'queued_feedback_report.dart';

/// Durable store for **user-approved** feedback reports that couldn't be
/// sent yet — offline, unauthenticated, or with no active server (#69,
/// #97).
///
/// The #34 privacy contract (nothing persists without explicit review +
/// approval) is upheld by the approval gate upstream, not by this
/// interface; by the time a record reaches [persist] the user has
/// approved it.
///
/// Records are [QueuedFeedbackReport] envelopes (#97): the report plus
/// the `bgeServerId` it was approved for (null = no active server), so
/// the drain can gate on the active server and one server's reports
/// never drain into another.
///
/// ## Addressing
///
/// A record is addressed by its [QueuedFeedbackReport.storageKey]. That
/// value happens to be the report's `clientRequestId` — the wire
/// idempotency token, so a drain racing a resubmission can't duplicate
/// server-side — but this interface deliberately does **not** name it
/// that. A sink needs a unique, addressable key; it has no stake in what
/// the backend calls the field that supplies one. Keeping the storage
/// vocabulary separate means a wire-contract rename (#161) stops at
/// `QueuedFeedbackReport` instead of reaching into every platform
/// implementation.
///
/// Implementations: `FileFeedbackSink` (native, durable JSON files) and
/// `MemoryFeedbackSink` (the web stand-in until #63, and the
/// resolve-or-default fallback).
abstract interface class FeedbackSink {
  /// Persists [record]. Throws [ArgumentError] if it has no
  /// [QueuedFeedbackReport.storageKey] — the sink is addressed by it.
  Future<void> persist(QueuedFeedbackReport record);

  /// All currently-queued records that are still **drainable**.
  ///
  /// A record this method declines to emit must be **discarded, not
  /// merely skipped** (#161). Every reason for declining — no usable
  /// storage key, a key disagreeing with the record's own address,
  /// undecodable persisted state — makes the record permanently
  /// un-[remove]able, so a drain could never clear it: it would re-send
  /// on every cycle and then fail at removal. Skipping without
  /// discarding leaks it for the life of the install.
  ///
  /// An implementation whose storage cannot hold an un-addressable record
  /// satisfies this trivially — `MemoryFeedbackSink` rejects keyless
  /// records at [persist] and keys by the value it read, so it has no
  /// reject path to discard from.
  ///
  /// Discarding must not extend to *transient* faults. An I/O error
  /// reading otherwise-intact persisted state is not corruption, and
  /// deleting on one would destroy a recoverable, user-approved report;
  /// such a record is skipped and retried on the next call.
  Future<List<QueuedFeedbackReport>> pending();

  /// Removes the record addressed by [storageKey]; a no-op if none
  /// matches.
  Future<void> remove(String storageKey);
}
