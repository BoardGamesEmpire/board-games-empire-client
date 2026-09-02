import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dio_network/src/network/decode_json_body.dart';

/// Comfortably over the 50 KB threshold that sends decoding to another isolate.
String _large(String suffix) => '{"pad": "${'x' * (60 * 1024)}"$suffix';

void main() {
  group('decodeJsonBody', () {
    test('decodes a small object inline', () async {
      expect(await decodeJsonBody('{"a": 1}'), {'a': 1});
    });

    test('decodes a small array inline', () async {
      expect(await decodeJsonBody('[1, 2]'), [1, 2]);
    });

    test('throws FormatException on a small malformed body', () async {
      await expectLater(
        () => decodeJsonBody('<html>nope</html>'),
        throwsA(isA<FormatException>()),
      );
    });

    // Everything below crosses the isolate boundary. Both the success type and
    // the exception type have to survive it, or the callers' `is! Map` check
    // and `on FormatException` clause would silently stop matching.
    test('a body over the threshold still decodes', () async {
      final source = _large(', "a": 1}');
      expect(source.codeUnits.length, greaterThan(50 * 1024));

      final decoded = await decodeJsonBody(source);

      expect(decoded, isA<Map<String, dynamic>>());
      expect((decoded! as Map<String, dynamic>)['a'], 1);
    });

    test('a malformed body over the threshold still throws '
        'FormatException', () async {
      final source = _large(', "a":');
      expect(source.codeUnits.length, greaterThan(50 * 1024));

      await expectLater(
        () => decodeJsonBody(source),
        throwsA(isA<FormatException>()),
      );
    });

    test('an HTML page over the threshold throws FormatException', () async {
      final source = '<html>${'x' * (60 * 1024)}</html>';
      expect(source.codeUnits.length, greaterThan(50 * 1024));

      await expectLater(
        () => decodeJsonBody(source),
        throwsA(isA<FormatException>()),
      );
    });

    test('an empty string is a FormatException, not null', () async {
      // Callers guard for empty before calling, but pinning it keeps the
      // contract explicit rather than incidental.
      await expectLater(
        () => decodeJsonBody(''),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'round-trips a realistic paginated envelope over the threshold',
      () async {
        final envelope = {
          'households': List.generate(
            100,
            (i) => {'id': 'hh_$i', 'name': 'Household $i ${'pad' * 200}'},
          ),
          'pagination': {'page': 1, 'limit': 100},
        };
        final source = jsonEncode(envelope);
        expect(source.codeUnits.length, greaterThan(50 * 1024));

        final decoded = await decodeJsonBody(source) as Map<String, dynamic>;

        expect(decoded['households'], hasLength(100));
        expect(decoded['pagination'], isA<Map<String, dynamic>>());
      },
    );
  });
}
