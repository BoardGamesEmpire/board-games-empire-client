import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('tryParseHttpDate', () {
    test('parses the RFC 9110 canonical example as UTC', () {
      final parsed = tryParseHttpDate('Sun, 06 Nov 1994 08:49:37 GMT');

      expect(parsed, DateTime.utc(1994, 11, 6, 8, 49, 37));
      expect(parsed!.isUtc, isTrue);
    });

    test('parses a current-era instant', () {
      expect(
        tryParseHttpDate('Tue, 21 Jul 2026 12:00:00 GMT'),
        DateTime.utc(2026, 7, 21, 12),
      );
    });

    test('tolerates surrounding whitespace', () {
      expect(
        tryParseHttpDate('  Tue, 21 Jul 2026 12:00:00 GMT '),
        DateTime.utc(2026, 7, 21, 12),
      );
    });

    test('does not validate the weekday name against the date', () {
      // 6 Nov 1994 was a Sunday; a wrong weekday still communicates an
      // unambiguous instant.
      expect(
        tryParseHttpDate('Mon, 06 Nov 1994 08:49:37 GMT'),
        DateTime.utc(1994, 11, 6, 8, 49, 37),
      );
    });

    test('accepts a real leap day', () {
      expect(
        tryParseHttpDate('Thu, 29 Feb 2024 00:00:00 GMT'),
        DateTime.utc(2024, 2, 29),
      );
    });

    group('returns null for', () {
      final rejected = <String, String>{
        'obsolete RFC 850 form': 'Sunday, 06-Nov-94 08:49:37 GMT',
        'obsolete asctime form': 'Sun Nov  6 08:49:37 1994',
        'missing GMT designator': 'Sun, 06 Nov 1994 08:49:37',
        'non-GMT zone designator': 'Sun, 06 Nov 1994 08:49:37 UTC',
        'numeric zone offset': 'Sun, 06 Nov 1994 08:49:37 +0000',
        'one-digit day': 'Sun, 6 Nov 1994 08:49:37 GMT',
        'lowercase month (case-sensitive grammar)':
            'Sun, 06 nov 1994 08:49:37 GMT',
        'nonexistent calendar day': 'Mon, 32 Jan 2026 00:00:00 GMT',
        'nonexistent leap day': 'Wed, 29 Feb 2023 00:00:00 GMT',
        'hour out of range': 'Tue, 21 Jul 2026 24:00:00 GMT',
        'leap second': 'Tue, 21 Jul 2026 12:00:60 GMT',
        'trailing junk': 'Tue, 21 Jul 2026 12:00:00 GMT extra',
        'empty string': '',
        'garbage': 'not-a-date',
      };

      rejected.forEach((label, input) {
        test(label, () => expect(tryParseHttpDate(input), isNull));
      });
    });
  });
}
