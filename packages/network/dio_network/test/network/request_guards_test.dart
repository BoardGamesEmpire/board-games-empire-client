import 'package:dio_network/src/network/request_guards.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher _argumentError(String name, String message) => isA<ArgumentError>()
    .having((e) => e.name, 'name', name)
    .having((e) => e.message, 'message', message);

const _limitMessage =
    'must be between 1 and 100 (the server rejects a larger page rather '
    'than clamping it)';

void main() {
  group('checkPage', () {
    test('accepts the bounds', () {
      expect(
        () => checkPage(page: 1, limit: 1, maxSize: 100, maxDepth: 10000),
        returnsNormally,
      );
      expect(
        () => checkPage(page: 1, limit: 100, maxSize: 100, maxDepth: 10000),
        returnsNormally,
      );
    });

    test('refuses a limit outside 1..maxSize', () {
      for (final limit in [0, 101]) {
        expect(
          () => checkPage(page: 1, limit: limit, maxSize: 100, maxDepth: 10000),
          throwsA(_argumentError('limit', _limitMessage)),
          reason: 'limit $limit',
        );
      }
    });

    test('refuses page 0', () {
      expect(
        () => checkPage(page: 0, limit: 10, maxSize: 100, maxDepth: 10000),
        throwsA(_argumentError('page', 'is 1-based')),
      );
    });

    test('checks the limit before the page', () {
      expect(
        () => checkPage(page: 0, limit: 0, maxSize: 100, maxDepth: 10000),
        throwsA(_argumentError('limit', _limitMessage)),
      );
    });

    test('refuses a page past maxDepth', () {
      expect(
        () => checkPage(page: 101, limit: 100, maxSize: 100, maxDepth: 10000),
        returnsNormally,
      );
      expect(
        () => checkPage(page: 102, limit: 100, maxSize: 100, maxDepth: 10000),
        throwsA(
          _argumentError('page', '(page - 1) * limit must not exceed 10000'),
        ),
      );
    });

    test('refuses a page whose depth overflows', () {
      // (page - 1) * limit is 2^62 * 2 = 2^63, which wraps to a negative on
      // the VM and would pass a multiplying check; dividing the ceiling
      // instead cannot wrap.
      expect(
        () => checkPage(
          page: (1 << 62) + 1,
          limit: 2,
          maxSize: 100,
          maxDepth: 10000,
        ),
        throwsA(
          _argumentError('page', '(page - 1) * limit must not exceed 10000'),
        ),
      );
    });

    test("serverMaxPageDepth is the server's DEFAULT_MAX_OFFSET", () {
      expect(serverMaxPageDepth, 100000);
    });
  });

  group('checkClientRequestId', () {
    const message =
        'must be 1 to 64 characters after trimming (the server rejects '
        'anything else with a 400)';

    test('refuses an empty, blank or over-long key', () {
      for (final key in ['', '   ', 'a' * 65]) {
        expect(
          () => checkClientRequestId(key, maxLength: 64),
          throwsA(_argumentError('clientRequestId', message)),
          reason: '"$key"',
        );
      }
    });

    test('accepts a key within bounds after trimming', () {
      for (final key in [' ab ', 'a' * 64]) {
        expect(
          () => checkClientRequestId(key, maxLength: 64),
          returnsNormally,
          reason: '"$key"',
        );
      }
    });
  });

  group('checkPathId', () {
    test('refuses empty, dot and dot-dot', () {
      expect(
        () => checkPathId('', name: 'eventId'),
        throwsA(_argumentError('eventId', 'must not be empty')),
      );
      for (final id in ['.', '..']) {
        expect(
          () => checkPathId(id, name: 'eventId'),
          throwsA(
            _argumentError(
              'eventId',
              'must not be "." or ".." (the URL would resolve it to another '
                  'route)',
            ),
          ),
          reason: '"$id"',
        );
      }
    });

    test('names the argument id by default', () {
      expect(
        () => checkPathId(''),
        throwsA(_argumentError('id', 'must not be empty')),
      );
    });

    test('accepts ids that only contain dots', () {
      for (final id in ['...', '.x', 'a.b']) {
        expect(() => checkPathId(id), returnsNormally, reason: '"$id"');
      }
    });
  });

  group('checkIdNotEmpty', () {
    test('refuses only an empty id', () {
      expect(
        () => checkIdNotEmpty('', name: 'userId'),
        throwsA(_argumentError('userId', 'must not be empty')),
      );
      for (final id in ['.', '..', 'u1']) {
        expect(() => checkIdNotEmpty(id), returnsNormally, reason: '"$id"');
      }
    });
  });
}
