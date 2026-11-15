import 'package:flutter_test/flutter_test.dart';
import 'package:server_settings/src/widgets/day_count_field.dart';

void main() {
  group('dayCount', () {
    test('takes whole numbers in the server range, trimmed', () {
      expect(dayCount('1'), 1);
      expect(dayCount('36500'), 36500);
      expect(dayCount(' 14 '), 14);
    });

    test('refuses what is out of range or not digits only', () {
      for (final value in ['0', '36501', '-1', '+5', '0x10', '1.5', '', null]) {
        expect(dayCount(value), isNull, reason: '$value');
      }
    });
  });
}
