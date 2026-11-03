import 'package:freezed_annotation/freezed_annotation.dart';

import 'feedback_report.dart';

part 'queued_feedback_report.freezed.dart';
part 'queued_feedback_report.g.dart';

/// A [FeedbackReport] persisted to the durable sink, tagged with the
/// server it was approved for (#97).
///
/// The tag is client bookkeeping and deliberately lives on this envelope
/// rather than on [FeedbackReport] itself: the report mirrors the
/// backend's `CreateFeedbackReportDto` and is what the transport POSTs
/// verbatim — a client-only field there would leak into the wire payload.
///
/// [serverId] is the **stable server-vended UUID** (`bgeServerId`, read
/// from `ActiveServer.identity.serverId`), not the client-local
/// `ServerConfig.id` — it is uniform across native and web and survives
/// remove/re-add of the same server, so queued reports are never
/// orphaned by a re-add. Null means no server was active when the user
/// approved the report (e.g. a failed-boot crash report): such
/// device-global diagnostics drain into whatever server is active at
/// drain time, while records tagged for a *different* server never do.
@freezed
abstract class QueuedFeedbackReport with _$QueuedFeedbackReport {
  const factory QueuedFeedbackReport({
    /// The user-approved report, exactly as the transport will send it.
    required FeedbackReport report,

    /// `bgeServerId` of the server the report was approved for, or null
    /// when no server was active at approval time.
    String? serverId,

    /// When this record entered the queue, for the sink's cap to evict by
    /// (#359).
    ///
    /// Deliberately **not** storage mtime. `FileFeedbackSink` rewrites a
    /// record's file whenever the drain counts a failed attempt against
    /// [retryCount], and that restamps its mtime to newest — mtime answers
    /// "last written", and eviction needs "oldest queued".
    ///
    /// **Always UTC.** `toIso8601String()` writes no zone designator for a
    /// local `DateTime`, and `DateTime.parse` then reads that back as local
    /// in whatever zone the device is in at read time — so a naive stamp
    /// shifts by hours when the user travels or DST flips, reordering
    /// eviction and skewing the retry window. Stamped through `.toUtc()` at
    /// every write site.
    ///
    /// Nullable because records written before this field existed decode
    /// without it. That degrades correctly: a record with no `queuedAt`
    /// predates the field and so genuinely *is* oldest, which is exactly
    /// how eviction orders it.
    DateTime? queuedAt,

    /// Send attempts that failed against a response this client could not
    /// verify. Capped at [maxRetries]; see [isExhausted].
    ///
    /// Counted **only** for `FeedbackUnverifiedDeliveryException` (declared
    /// in `feedback_service.dart`; not imported here, so the name is not a
    /// doc link) — see #359. A throttle, an offline device or a 5xx stops
    /// the drain before reaching the increment, so a week off the network
    /// costs a record nothing — which is the only reason [maxRetries] can
    /// be as low as it is.
    @Default(0) int retryCount,

    /// Last failure message, for diagnostics. Null until one fails.
    String? lastError,

    /// When the last attempt failed. Null until one does.
    DateTime? lastAttemptAt,
  }) = _QueuedFeedbackReport;

  const QueuedFeedbackReport._();

  /// Attempts before a record stops being retried.
  ///
  /// The value `SyncQueueEntry.maxRetries` already uses (#359). The two
  /// queues are separate stores with no shared code, but a reader who knows
  /// one bound should not have to check the other.
  static const int maxRetries = 5;

  /// Minimum gap between two *counted* attempts on one record.
  ///
  /// Without this, [maxRetries] measures drain triggers rather than time.
  /// `drainPending` fires on every authenticated signal — duplicates are
  /// documented, and a server switch fires it again — so a hotel captive
  /// portal could burn all five attempts in a single session and strand the
  /// report permanently, on a network fault that clears itself an hour later.
  ///
  /// An hour makes exhaustion mean what [maxRetries] claims it means: the
  /// record has failed across at least four hours of app usage, not four
  /// taps. A record still inside the window is skipped entirely — not sent
  /// and not counted — so the cooldown also stops a broken deployment being
  /// re-POSTed on every signal.
  static const Duration retryCooldown = Duration(hours: 1);

  /// Records a sink holds before evicting oldest-first by [queuedAt] (#359).
  ///
  /// A count rather than a byte budget: it is the simpler thing to test,
  /// and a byte budget would key local storage policy off
  /// `FeedbackConstants.maxBodyBytes`, which mirrors a backend protocol cap
  /// and has nothing to say about disk. At realistic report sizes this is a
  /// few hundred KB; at the 256 KB per-report protocol ceiling it bounds at
  /// roughly 12.5 MB.
  static const int maxQueuedReports = 50;

  /// Sort position for a record written before [queuedAt] existed.
  ///
  /// Shared by every sink so the age rule cannot drift between them. UTC
  /// because every stamp is UTC (see [queuedAt]); `compareTo` works on the
  /// absolute instant regardless, but a mixed-zone sentinel reads as a bug.
  static final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(
    0,
    isUtc: true,
  );

  /// The instant this record is ordered by when a sink evicts.
  ///
  /// A record with no [queuedAt] predates the field and so genuinely is
  /// oldest, which [epoch] expresses directly.
  DateTime get ageKey => queuedAt ?? epoch;

  /// Keys to delete so [entries] fits [maxQueuedReports]: oldest first by
  /// age, then [tieBreak]. [exempt] counts toward the total and is never
  /// returned. Callers pass only entries whose age they know.
  ///
  /// Deliberately one function rather than a rule each sink restates (#359):
  /// two implementations have already disagreed once about how to apply it,
  /// and a divergence here silently deletes the wrong report. Every sink's
  /// cap calls it, the web sink's persist cap included: that one reads ages
  /// from an index, so it gets them without reading a report.
  ///
  /// [tieBreak] is per sink — storage path, key, or arrival order — because
  /// this cannot see one. It decides only between equal ages. [entries] is
  /// read once and never mutated, and [exempt] is compared with `==`.
  static List<K> keysToEvict<K>(
    Iterable<(K, DateTime)> entries, {
    K? exempt,
    required Comparator<K> tieBreak,
  }) {
    final all = entries.toList();
    final excess = all.length - maxQueuedReports;
    if (excess <= 0) return <K>[];
    final candidates =
        [
          for (final e in all)
            if (exempt == null || e.$1 != exempt) e,
        ]..sort((a, b) {
          final byAge = a.$2.compareTo(b.$2);
          return byAge != 0 ? byAge : tieBreak(a.$1, b.$1);
        });
    return [for (final e in candidates.take(excess)) e.$1];
  }

  /// Whether this record has used up [maxRetries].
  ///
  /// An exhausted record is **kept and skipped**, never dropped (#359): the
  /// server never judged it, so discarding it would destroy user-approved
  /// words over what may be a captive portal. Only the sink's cap ever
  /// deletes.
  bool get isExhausted => retryCount >= maxRetries;

  /// Whether [retryCooldown] has elapsed since [lastAttemptAt], so another
  /// attempt may be counted against this record.
  ///
  /// True when no attempt has failed yet. A `lastAttemptAt` in the future —
  /// a clock that moved backwards between runs — also reads as ready rather
  /// than stranding the record until the clock catches up.
  bool isRetryableAt(DateTime now) {
    final last = lastAttemptAt;
    if (last == null) return true;
    if (last.isAfter(now)) return true;
    return now.difference(last) >= retryCooldown;
  }

  factory QueuedFeedbackReport.fromJson(Map<String, dynamic> json) =>
      _$QueuedFeedbackReportFromJson(json);

  /// The sink's address for this record.
  ///
  /// This getter is the **only** place the wire vocabulary and the
  /// storage vocabulary meet. [FeedbackSink] and its implementations know
  /// records by `storageKey`; the value they get is the report's
  /// [FeedbackReport.clientRequestId], because reusing the idempotency
  /// token as the address is what makes a drain racing a resubmission
  /// safe — the same record can't be queued under two names, a second
  /// persist under the same key keeps the first (#379), and a replayed send
  /// dedupes server-side (backend #251), which keeps its first report too.
  ///
  /// Not a stored field: deriving it keeps a single source of truth, so
  /// the address can never drift from the token that has to match it.
  ///
  /// Null when the report carries no `clientRequestId`. Such a record is
  /// un-addressable: `FeedbackSink.persist` rejects it, and
  /// `FeedbackSink.pending` discards it rather than emitting something no
  /// drain could ever remove.
  String? get storageKey => report.clientRequestId;
}
