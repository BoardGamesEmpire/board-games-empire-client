import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalClockService', () {
    test('nowUtc passes through the injected local clock', () {
      final fixed = DateTime.utc(2026, 7, 21, 12);
      final clock = LocalClockService(() => fixed);

      expect(clock.nowUtc(), fixed);
    });

    test('default clock returns UTC', () {
      const clock = LocalClockService();

      expect(clock.nowUtc().isUtc, isTrue);
    });

    test('skewEstimate is permanently null', () {
      const clock = LocalClockService();

      expect(clock.skewEstimate, isNull);
    });

    test('watchSkew replays null and completes', () async {
      const clock = LocalClockService();

      expect(await clock.watchSkew().toList(), [null]);
    });

    test('the same returned stream supports multiple listeners', () async {
      const clock = LocalClockService();
      final stream = clock.watchSkew();

      expect(await stream.toList(), [null]);
      expect(
        await stream.toList(),
        [null],
        reason: 'must be re-listenable like ServerSkewClockService (LSP)',
      );
    });
  });
}
