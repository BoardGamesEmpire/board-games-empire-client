/// Server-corrected time source (#12, Tier 3).
///
/// Client timestamps drive the sync queue's tombstone ordering and the
/// GameCollection canonical-row selection. A device whose wall clock is
/// minutes (or hours) off produces tombstones that win or lose
/// cross-device tiebreaks purely by virtue of the skew. This interface
/// is the read surface consumers use instead of `DateTime.now()` for
/// every **consensus-relevant** timestamp (tombstone `deletedAt`,
/// resurrection `updatedAt`, sync-queue bookkeeping). UI-display
/// timestamps (`lastPlayed`, `lastUpdated` shown in lists) deliberately
/// keep using the raw local clock — those are user-facing, not
/// consensus-relevant.
///
/// The service is **per-server**: each server has its own clock, so the
/// implementation is registered in the per-server `DependencyContainer`
/// just like `AuthRepository`, and estimates never leak across scopes.
///
/// Per ISP, lifecycle (`dispose`) is deliberately **not** part of this
/// interface: it lives on the concrete implementation and is owned by
/// the composition root that constructs it (matching
/// [ConnectivityService]). Sample ingestion is likewise split out into
/// [ClockSkewRecorder] so transport code depends only on the feed
/// surface (matching the `ActiveLocaleReader` / `ActiveLocaleController`
/// split).
///
/// Concrete implementations live in `packages/core/di`:
/// `ServerSkewClockService` (skew-corrected, fed by the network layer)
/// and `LocalClockService` (pass-through null object for scopes without
/// a skew source — e.g. web until its feeder lands).
abstract interface class ClockService {
  /// The current UTC time, adjusted by the most recent server-skew
  /// estimate.
  ///
  /// Returns the unmodified local clock (as UTC) while [skewEstimate]
  /// is `null` — before the first sample there is no evidence either
  /// way. Implementations that correct for skew guarantee the returned
  /// value is **non-decreasing across calls on the same instance**: a
  /// skew update arriving mid-session must not make consensus
  /// timestamps regress on this device (row-id tiebreakers already
  /// disambiguate equal timestamps).
  DateTime nowUtc();

  /// Estimated skew between the local clock and the server.
  ///
  /// Positive = local clock is ahead of the server. `null` = no
  /// estimate yet. This exposes the **raw** rolling estimate for debug
  /// surfacing; implementations may apply a small deadband before
  /// actually correcting [nowUtc] (the `Date` header only carries
  /// one-second resolution, so sub-deadband estimates are noise).
  Duration? get skewEstimate;

  /// Stream of skew-estimate updates (rare events; mostly useful for
  /// debug surfacing).
  ///
  /// Replays the current [skewEstimate] to every new subscriber, then
  /// emits whenever the estimate changes value. Consecutive duplicates
  /// are not re-emitted.
  Stream<Duration?> watchSkew();
}

/// Feed surface for clock-skew samples.
///
/// The transport layer (a Dio interceptor on native; a `web_network`
/// feeder later — see #118) observes the `Date` header on server
/// responses and reports one sample per response. Splitting this from
/// [ClockService] keeps transport code off the concrete estimator and
/// consumers off the ingestion API (ISP; same split as
/// `ActiveLocaleReader` / `ActiveLocaleController`).
abstract interface class ClockSkewRecorder {
  /// Records one instantaneous skew observation.
  ///
  /// [serverDate] is the parsed `Date` header (UTC; one-second
  /// resolution per RFC 9110). [requestSentAt] and
  /// [responseReceivedAt] are **raw local-clock UTC** stamps taken
  /// immediately before dispatch and immediately after the response
  /// arrived; the estimator compares the server time against their
  /// midpoint so network transit cancels out to first order
  /// (NTP-style). Implementations silently discard nonsense samples
  /// (received-before-sent, implausibly large skew).
  void recordSample({
    required DateTime serverDate,
    required DateTime requestSentAt,
    required DateTime responseReceivedAt,
  });
}
