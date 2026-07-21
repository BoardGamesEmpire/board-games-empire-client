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
  });
}
