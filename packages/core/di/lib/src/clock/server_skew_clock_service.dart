import 'dart:async';

import 'package:interfaces/services.dart';

/// Skew-corrected [ClockService] fed by server `Date` headers (#12).
///
/// One instance per server scope. The transport layer reports one
/// sample per server response via [recordSample]; this class maintains
/// a rolling estimate and applies it in [nowUtc].
///
/// ## Estimation model
///
/// Each sample is the difference between the **local-clock midpoint**
/// of the request round trip and the server's `Date` value:
///
/// ```text
/// sample = midpoint(requestSentAt, responseReceivedAt) - serverDate
/// ```
///
/// The midpoint approximates the local time at which the server
/// generated the header, so symmetric network transit cancels out to
/// first order (NTP-style). Positive = local clock ahead of the server.
///
/// **Confirm, step, then smooth.** No single sample is ever trusted:
/// the estimate is only (re)established when **two consecutive samples
/// agree** within [stepAgreementTolerance] — one anomalous `Date` (a
/// misconfigured intermediary, a transient server fault, or a
/// hostile-but-bounded response under locked decision D3's trust
/// model) cannot yank the estimate on its own. Once established,
/// samples within [outlierGate] of the estimate are folded in with an
/// exponentially-weighted moving average ([smoothingFactor]) to damp
/// latency noise; samples outside the gate are quarantined and only
/// take effect if the next sample agrees with them (a genuine server
/// clock change re-steps after two confirming responses; a lone spike
/// is discarded when normal traffic resumes).
///
/// ## Sample hygiene
///
/// Silently discarded (no estimate change, no quarantine, no
/// emission):
///
/// - `responseReceivedAt < requestSentAt` — the local clock stepped
///   mid-flight; the midpoint is meaningless.
/// - `|sample| > maxPlausibleSkew` — an absolute nonsense bound; a
///   garbage `Date` must not even enter the confirmation pipeline.
///
/// ## Correction deadband
///
/// The `Date` header carries one-second resolution (RFC 9110), so
/// estimates below a couple of seconds are indistinguishable from
/// noise. [skewEstimate] exposes the **raw** rolling estimate for
/// debug surfacing, but [nowUtc] only applies it once its magnitude
/// reaches [correctionDeadband] — below that the local clock is
/// already as correct as we can prove. (The same resolution floor is
/// why sub-second systematic error in the transport stamps — see
/// `ClockSkewInterceptor` — is immaterial here.)
///
/// ## Monotonic output — and its deliberate cost
///
/// A skew update arriving mid-session can move the corrected time
/// backwards (local was found to be ahead). [nowUtc] therefore never
/// returns less than the last value it returned on this instance.
///
/// Be explicit about what that trades away: if consensus timestamps
/// were issued **before** the estimate was established, the frozen
/// value is the *uncorrected* (still-skewed-forward) instant, and the
/// correction only takes real effect once wall time passes it — i.e.
/// up to `|skew|` of real time after confirmation. Timestamps stamped
/// during that window remain as far ahead as they were before this
/// service existed; they are no *worse*, but they are not yet better.
///
/// The regression-free alternative was rejected because within-device
/// ordering is load-bearing: canonical-row selection orders tombstones
/// by `updatedAt DESC` (row-id breaks *ties* only, not inversions), so
/// letting a later operation stamp an **earlier** instant would make
/// resurrection revive the wrong tombstone locally — a correctness bug
/// on this device, traded against a bounded delay in cross-device
/// fairness. During the frozen window successive calls return equal
/// timestamps, which the row-id tiebreakers disambiguate
/// deterministically. The guard is per-instance; a suspend → activate
/// cycle constructs a fresh service (and, pre-#117, a fresh `null`
/// estimate). The window also only opens at all when [nowUtc] was
/// consulted before the first confirmed sample — in practice the
/// offline-at-launch path.
///
/// ## Lifecycle
///
/// Per ISP, `dispose` is not part of [ClockService]; the composition
/// root that constructs this instance registers [dispose] as the
/// container teardown callback. After disposal, [recordSample] is a
/// no-op and [watchSkew] emits the final estimate and completes.
class ServerSkewClockService implements ClockService, ClockSkewRecorder {
  /// Creates the estimator.
  ///
  /// [localNowUtc] injects the raw local clock for tests; production
  /// uses `DateTime.now().toUtc()`. [smoothingFactor] is the EWMA
  /// weight given to each new in-gate sample (`0 < f <= 1`; `1`
  /// disables smoothing entirely).
  ServerSkewClockService({
    DateTime Function()? localNowUtc,
    this.smoothingFactor = 0.2,
    this.correctionDeadband = const Duration(seconds: 2),
    this.stepAgreementTolerance = const Duration(seconds: 10),
    this.outlierGate = const Duration(seconds: 30),
    this.maxPlausibleSkew = const Duration(hours: 24),
  }) : assert(
         smoothingFactor > 0 && smoothingFactor <= 1,
         'smoothingFactor must be in (0, 1]',
       ),
       _localNowUtc = localNowUtc ?? _systemNowUtc;

  static DateTime _systemNowUtc() => DateTime.now().toUtc();

  /// EWMA weight applied to each in-gate sample.
  final double smoothingFactor;

  /// Minimum estimate magnitude before [nowUtc] applies a correction.
  final Duration correctionDeadband;

  /// Maximum disagreement between two consecutive samples for them to
  /// confirm each other and (re)establish the estimate.
  final Duration stepAgreementTolerance;

  /// Maximum deviation from the current estimate for a sample to be
  /// EWMA-folded; beyond it the sample is quarantined pending
  /// confirmation by the next sample.
  final Duration outlierGate;

  /// Samples implying more skew than this are discarded as nonsense.
  final Duration maxPlausibleSkew;

  final DateTime Function() _localNowUtc;
  final StreamController<Duration?> _updates =
      StreamController<Duration?>.broadcast();

  Duration? _estimate;
  Duration? _pendingStep;
  DateTime? _lastReturned;
  bool _disposed = false;

  @override
  Duration? get skewEstimate => _estimate;

  @override
  DateTime nowUtc() {
    final local = _localNowUtc();
    final estimate = _estimate;
    final corrected = (estimate == null || estimate.abs() < correctionDeadband)
        ? local
        : local.subtract(estimate);

    final last = _lastReturned;
    if (last != null && corrected.isBefore(last)) {
      // Monotonic guard — see the class doc for the delayed-correction
      // trade-off this deliberately accepts. Return the frozen value
      // until the corrected clock catches up.
      return last;
    }
    _lastReturned = corrected;
    return corrected;
  }

  @override
  void recordSample({
    required DateTime serverDate,
    required DateTime requestSentAt,
    required DateTime responseReceivedAt,
  }) {
    if (_disposed) return;
    if (responseReceivedAt.isBefore(requestSentAt)) return;

    final midpointMicros =
        (requestSentAt.microsecondsSinceEpoch +
            responseReceivedAt.microsecondsSinceEpoch) ~/
        2;
    final sample = Duration(
      microseconds: midpointMicros - serverDate.toUtc().microsecondsSinceEpoch,
    );
    if (sample.abs() > maxPlausibleSkew) return;

    final previous = _estimate;
    if (previous != null && (sample - previous).abs() <= outlierGate) {
      // In-gate: fold into the model. Any quarantined outlier was a
      // transient spike — normal traffic has resumed; drop it.
      _pendingStep = null;
      _commit(
        Duration(
          microseconds:
              (smoothingFactor * sample.inMicroseconds +
                      (1 - smoothingFactor) * previous.inMicroseconds)
                  .round(),
        ),
      );
      return;
    }

    // No estimate yet, or the sample is far outside the current model:
    // require the previous sample's agreement before (re)stepping.
    final pending = _pendingStep;
    if (pending != null && (sample - pending).abs() <= stepAgreementTolerance) {
      _pendingStep = null;
      // Step to the newer of the two agreeing samples — the most
      // recent evidence.
      _commit(sample);
      return;
    }
    _pendingStep = sample;
  }

  void _commit(Duration next) {
    if (next == _estimate) return;
    _estimate = next;
    _updates.add(next);
  }

  @override
  Stream<Duration?> watchSkew() {
    return Stream<Duration?>.multi((controller) {
      // Replay the current estimate to every new subscriber (matches
      // ConnectivityService.watch semantics), then forward updates.
      controller.add(_estimate);
      if (_disposed) {
        controller.close();
        return;
      }
      final subscription = _updates.stream.listen(
        controller.add,
        onDone: controller.close,
      );
      controller
        ..onCancel = subscription.cancel
        ..onPause = subscription.pause
        ..onResume = subscription.resume;
    });
  }

  /// Releases the update stream. Owned by the composition root
  /// (registered as the container's `dispose:` callback); not part of
  /// the [ClockService] interface per ISP.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _updates.close();
  }
}
