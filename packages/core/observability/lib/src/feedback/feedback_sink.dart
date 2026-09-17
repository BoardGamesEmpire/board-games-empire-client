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
/// ## Capacity (#359)
///
/// A sink is **bounded**, and the bound is part of this contract rather
/// than a coincidence between the implementations that exist today. A
/// deployment where nothing can ever drain — a proxy or SPA catch-all
/// answering every POST with its own 200 — otherwise grows the queue
/// without limit, which is the failure #359 was filed for.
///
/// An implementation holds at most [QueuedFeedbackReport.maxQueuedReports]
/// records and, once full, evicts oldest-first by
/// [QueuedFeedbackReport.compareByAge] — the shared age rule, so two sinks
/// cannot disagree about which record dies. Note what it orders by:
/// [QueuedFeedbackReport.queuedAt], *not* a storage timestamp. The drain
/// [update]s a record to count a failed attempt, so anything derived from
/// last-written time says "new" about the oldest record in the queue.
///
/// Eviction is the **only** discard permitted on a full sink, and it is
/// still subject to the transient-fault rule above. What that rule forbids
/// is letting unreadability stand in for *age*: a record the implementation
/// cannot read is not thereby old, and no readable record may be deleted to
/// pay for the slot it occupies.
///
/// It does not forbid evicting a record whose age is genuinely known. An
/// implementation that already holds the `queuedAt` it wrote itself keeps
/// that age while the file is briefly unreadable, and the record stays
/// evictable on it — the age is real, so the arithmetic stays exact. See
/// `FileFeedbackSink._enforceCap` for the case worked through.
///
/// Implementations: `FileFeedbackSink` (native, durable JSON files) and
/// `MemoryFeedbackSink` (the web stand-in until #63, and the
/// resolve-or-default fallback). A durable web sink (#292) inherits this
/// section rather than deciding a second policy.
abstract interface class FeedbackSink {
  /// Persists [record]. Throws [ArgumentError] if it has no
  /// [QueuedFeedbackReport.storageKey] — the sink is addressed by it.
  ///
  /// On return, [record] **is** stored. An implementation enforcing the
  /// capacity bound below must never satisfy it by discarding the record it
  /// was just handed: `submit` reports [FeedbackSubmitResult.queued] on the
  /// strength of this call, and a sink that dropped the new record would
  /// have the prompt promise a later send for a report that no longer
  /// exists.
  Future<void> persist(QueuedFeedbackReport record);

  /// Rewrites a record **that is already stored**, addressed by
  /// [QueuedFeedbackReport.storageKey]. Throws [ArgumentError] if [record]
  /// has no storage key, exactly as [persist] does.
  ///
  /// If no record is stored under that key, this is a **no-op**: the record
  /// is not created, and the caller is not told (#376). Both conditions are
  /// ordinary, so neither is an error and neither is logged.
  ///
  /// ## Why absent means "do nothing" (#376)
  ///
  /// This exists because [persist] is the wrong verb for the only two writes
  /// the drain performs after [pending] — counting a failed attempt and
  /// clearing a spent retry bound. Both rewrite a record the drain is holding
  /// from a snapshot, and a snapshot goes stale: the sink is bounded, so a
  /// `submit` arriving mid-drain can evict the very record the drain is
  /// partway through. [persist] would then write that record back, and the
  /// eviction it triggers cannot fall on the record just handed over — so
  /// the evicted report returns and a *different*, still-live report dies in
  /// its place.
  ///
  /// The drain has no way to notice, and nothing about it is recoverable
  /// afterwards: the queue looks the same size either way. Making the write
  /// conditional on the record still being there is what removes the
  /// possibility rather than narrowing the window, and a sink can check that
  /// atomically with the write where a caller cannot.
  ///
  /// So an absent key means the record left the queue while the drain was
  /// working — evicted by the cap, or removed by a drain that got there
  /// first. In every such case there is nothing left to update and nothing
  /// the caller could usefully do about it.
  ///
  /// ## Presence is all that is checked
  ///
  /// Whether the key is stored, and nothing else. An implementation does not
  /// compare what it holds against [record], so this cannot distinguish a
  /// rewrite of the record the caller read from a rewrite of a *different*
  /// record that arrived under the same key since. That is deliberate rather
  /// than overlooked: the storage key is the report's idempotency token, so
  /// two records sharing one are the same submission by definition, and
  /// [persist] has always overwritten on that basis.
  ///
  /// ## Capacity
  ///
  /// An update cannot grow the sink, so it must **not** run the eviction
  /// pass. It also must not change the record's position in the age order:
  /// eviction keys on [QueuedFeedbackReport.queuedAt], which is stamped once
  /// at [persist] and never rewritten, so a counted attempt cannot make the
  /// oldest record in the queue look new.
  ///
  /// That last rule binds the **caller**, and no implementation verifies it:
  /// a record handed here with a moved or cleared `queuedAt` silently
  /// reorders eviction, and a cleared one sorts at
  /// [QueuedFeedbackReport.epoch] and dies next. Rewrite with `copyWith`,
  /// which carries the stamp forward.
  Future<void> update(QueuedFeedbackReport record);

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
