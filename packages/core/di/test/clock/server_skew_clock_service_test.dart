import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Fixed epoch anchor for readable arithmetic. All stamps are UTC.
  final t0 = DateTime.utc(2026, 7, 21, 12);

  /// Reports a zero-RTT sample implying the local clock is ahead of
  /// the server by [skew] (negative = local behind).
  void sample(ServerSkewClockService clock, Duration skew) =>
      clock.recordSample(
        serverDate: t0.subtract(skew),
        requestSentAt: t0,
        responseReceivedAt: t0,
      );

  group('ServerSkewClockService', () {
    group('initial state', () {
      test('skewEstimate is null before any sample', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);
        expect(clock.skewEstimate, isNull);
      });

      test('nowUtc returns the unmodified local clock with no estimate', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);
        expect(clock.nowUtc(), t0);
      });
    });

    group('recordSample() — confirmation and stepping', () {
      test('a single sample is never adopted (awaiting confirmation)', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);

        sample(clock, const Duration(hours: 23));

        expect(
          clock.skewEstimate,
          isNull,
          reason:
              'one anomalous-but-in-bound Date must not yank the '
              'estimate on its own',
        );
      });

      test('two consecutive agreeing samples establish the estimate', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);

        sample(clock, const Duration(minutes: 5));
        sample(clock, const Duration(minutes: 5));

        expect(clock.skewEstimate, const Duration(minutes: 5));
      });

      test('steps to the newer of the two agreeing samples', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);

        // 8s apart: within the default 10s agreement tolerance.
        sample(clock, const Duration(minutes: 5));
        sample(clock, const Duration(minutes: 5, seconds: 8));

        expect(
          clock.skewEstimate,
          const Duration(minutes: 5, seconds: 8),
          reason: 'most recent evidence wins the step',
        );
      });

      test('two disagreeing samples do not establish an estimate', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);

        sample(clock, const Duration(minutes: 5));
        sample(clock, const Duration(minutes: 10));

        expect(clock.skewEstimate, isNull);
      });

      test('in-gate samples are EWMA-smoothed once established', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);

        sample(clock, const Duration(seconds: 10));
        sample(clock, const Duration(seconds: 10));
        // Third sample: +20s, within the 30s gate. Default factor 0.2:
        // 0.2 * 20s + 0.8 * 10s = 12s.
        sample(clock, const Duration(seconds: 20));

        expect(clock.skewEstimate, const Duration(seconds: 12));
      });

      test('sample is measured against the round-trip midpoint', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);

        // 2s round trip; server Date equals the send instant. The
        // midpoint is sent + 1s, so each skew sample is +1s — NOT +2s
        // (receive-time comparison) and NOT 0 (send-time comparison).
        for (var i = 0; i < 2; i++) {
          clock.recordSample(
            serverDate: t0,
            requestSentAt: t0,
            responseReceivedAt: t0.add(const Duration(seconds: 2)),
          );
        }

        expect(clock.skewEstimate, const Duration(seconds: 1));
      });
    });

    group('recordSample() — outlier handling', () {
      test('a lone out-of-gate outlier is ignored', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);
        sample(clock, const Duration(seconds: 10));
        sample(clock, const Duration(seconds: 10));

        // One 23h spike — within maxPlausibleSkew, far outside the gate.
        sample(clock, const Duration(hours: 23));

        expect(clock.skewEstimate, const Duration(seconds: 10));
      });

      test('an in-gate sample clears a quarantined outlier', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);
        sample(clock, const Duration(seconds: 10));
        sample(clock, const Duration(seconds: 10));

        sample(clock, const Duration(minutes: 10)); // spike, quarantined
        sample(clock, const Duration(seconds: 10)); // normal traffic resumes
        sample(clock, const Duration(minutes: 10)); // fresh spike, alone again

        expect(
          clock.skewEstimate,
          const Duration(seconds: 10),
          reason: 'non-consecutive outliers never confirm each other',
        );
      });

      test('re-steps after two consecutive agreeing out-of-gate samples', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);
        sample(clock, const Duration(seconds: 10));
        sample(clock, const Duration(seconds: 10));

        // The server's clock was genuinely fixed/changed: sustained
        // disagreement re-establishes the estimate.
        sample(clock, const Duration(minutes: 10));
        sample(clock, const Duration(minutes: 10));

        expect(clock.skewEstimate, const Duration(minutes: 10));
      });

      test('discards samples where the response predates the request '
          'without quarantining them', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);

        clock.recordSample(
          serverDate: t0.subtract(const Duration(minutes: 5)),
          requestSentAt: t0,
          responseReceivedAt: t0.subtract(const Duration(seconds: 1)),
        );
        expect(clock.skewEstimate, isNull);

        // A discarded sample must not act as the first of an agreeing
        // pair: one good sample after it still cannot step.
        sample(clock, const Duration(minutes: 5));
        expect(clock.skewEstimate, isNull);

        sample(clock, const Duration(minutes: 5));
        expect(clock.skewEstimate, const Duration(minutes: 5));
      });

      test('discards samples beyond maxPlausibleSkew without '
          'quarantining them', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);

        sample(clock, const Duration(hours: 25));
        sample(clock, const Duration(hours: 25));

        expect(
          clock.skewEstimate,
          isNull,
          reason:
              'nonsense samples never enter the confirmation pipeline, '
              'even in agreement',
        );
      });

      test('bound rejection preserves an existing estimate', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);
        sample(clock, const Duration(minutes: 5));
        sample(clock, const Duration(minutes: 5));

        sample(clock, const Duration(hours: 25));

        expect(clock.skewEstimate, const Duration(minutes: 5));
      });
    });

    group('nowUtc() — correction', () {
      test('subtracts the estimate once it exceeds the deadband', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);
        sample(clock, const Duration(minutes: 5));
        sample(clock, const Duration(minutes: 5));

        expect(clock.nowUtc(), t0.subtract(const Duration(minutes: 5)));
      });

      test('adds when the estimate is negative (local behind server)', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);
        sample(clock, const Duration(minutes: -3));
        sample(clock, const Duration(minutes: -3));

        expect(clock.skewEstimate, const Duration(minutes: -3));
        expect(clock.nowUtc(), t0.add(const Duration(minutes: 3)));
      });

      test('deadband: sub-threshold estimate is exposed but not applied', () {
        final clock = ServerSkewClockService(localNowUtc: () => t0);

        // 1s estimate: within the Date header's noise floor.
        sample(clock, const Duration(seconds: 1));
        sample(clock, const Duration(seconds: 1));

        expect(clock.skewEstimate, const Duration(seconds: 1));
        expect(clock.nowUtc(), t0, reason: 'correction suppressed');
      });

      test('never regresses below the last returned value — correction is '
          'delayed by up to the skew when a baseline predates it', () {
        var localNow = t0;
        final clock = ServerSkewClockService(localNowUtc: () => localNow);

        // Consensus timestamp issued BEFORE any estimate: the baseline
        // is the uncorrected (skewed-forward) instant.
        expect(clock.nowUtc(), t0);

        sample(clock, const Duration(minutes: 5));
        sample(clock, const Duration(minutes: 5));

        // The corrected clock now sits before the baseline: frozen at
        // the pre-correction instant, NOT corrected — the documented
        // trade-off protecting within-device updatedAt ordering.
        localNow = t0.add(const Duration(seconds: 1));
        expect(clock.nowUtc(), t0);

        // Once the corrected clock catches up, output resumes normally.
        localNow = t0.add(const Duration(minutes: 6));
        expect(clock.nowUtc(), t0.add(const Duration(minutes: 1)));
      });
    });

    group('watchSkew()', () {
      test('replays the current estimate to a new subscriber', () async {
        final clock = ServerSkewClockService(localNowUtc: () => t0);

        expect(await clock.watchSkew().first, isNull);

        sample(clock, const Duration(minutes: 5));
        sample(clock, const Duration(minutes: 5));

        expect(await clock.watchSkew().first, const Duration(minutes: 5));
      });

      test('emits on change and suppresses duplicate estimates', () async {
        final clock = ServerSkewClockService(localNowUtc: () => t0);
        final seen = <Duration?>[];
        final sub = clock.watchSkew().listen(seen.add);
        addTearDown(sub.cancel);
        await pumpEventQueue();

        sample(clock, const Duration(seconds: 10)); // quarantined, no emit
        sample(clock, const Duration(seconds: 10)); // step → 10s
        sample(clock, const Duration(seconds: 10)); // EWMA(10,10)=10, no emit
        sample(clock, const Duration(seconds: 20)); // EWMA → 12s
        await pumpEventQueue();

        expect(seen, [
          null, // replayed current
          const Duration(seconds: 10),
          const Duration(seconds: 12), // 0.2*20 + 0.8*10
        ]);
      });

      test('completes subscribers on dispose; late subscribers get the '
          'final estimate then done', () async {
        final clock = ServerSkewClockService(localNowUtc: () => t0);
        sample(clock, const Duration(minutes: 5));
        sample(clock, const Duration(minutes: 5));

        final live = clock.watchSkew().toList();
        await pumpEventQueue();
        await clock.dispose();

        expect(await live, [const Duration(minutes: 5)]);
        expect(await clock.watchSkew().toList(), [const Duration(minutes: 5)]);
      });

      test('recordSample after dispose is a no-op', () async {
        final clock = ServerSkewClockService(localNowUtc: () => t0);
        await clock.dispose();

        sample(clock, const Duration(minutes: 5));
        sample(clock, const Duration(minutes: 5));

        expect(clock.skewEstimate, isNull);
      });
    });
  });
}
