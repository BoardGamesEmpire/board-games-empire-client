// The rate-limit subtype and the `X-Retry-After` reading behind it (#559).
//
// Both repositories classify a 429 through these; their suites drive it end
// to end through a real Dio. This is the unit half, here beside the code.

import 'package:interfaces/repositories.dart';
import 'package:test/test.dart';

void main() {
  group('AuthRateLimitedException', () {
    test('is an AuthException carrying the wait, with a default message', () {
      final e = AuthRateLimitedException(retryAfter: parseRetryAfter('7'));
      expect(e, isA<AuthException>());
      expect(e.retryAfter, const Duration(seconds: 7));
      expect(e.message, 'Too many attempts.');
    });

    test('may carry no wait', () {
      expect(
        AuthRateLimitedException(retryAfter: parseRetryAfter(null)).retryAfter,
        isNull,
      );
    });
  });

  group('parseRetryAfter', () {
    test('reads whole seconds', () {
      expect(parseRetryAfter('7'), const Duration(seconds: 7));
      expect(parseRetryAfter('0'), Duration.zero);
    });

    test('is null for anything but a run of digits', () {
      for (final header in [null, '', '7.5', '-1', ' 7', '7 ', 'soon']) {
        expect(parseRetryAfter(header), isNull, reason: '$header');
      }
    });

    test('is null, not a throw, for a number too large to hold', () {
      expect(parseRetryAfter('9' * 40), isNull);
    });

    test('is null for a number an int holds but a Duration does not', () {
      // 1e13 seconds is 1e19 microseconds, past the largest int: a Duration
      // of it would wrap to a negative wait on the VM.
      expect(parseRetryAfter('10000000000000'), isNull);
      expect(parseRetryAfter('9223372036855'), isNull);
    });

    test('reads the most whole seconds a Duration holds', () {
      expect(
        parseRetryAfter('9223372036854'),
        const Duration(seconds: 9223372036854),
      );
    });
  });
}
