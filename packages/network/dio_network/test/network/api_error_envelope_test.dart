import 'package:dio_network/src/network/api_error_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('probeJsonBody', () {
    test('returns null for an empty body', () {
      expect(probeJsonBody(''), isNull);
    });

    test('probes a body at the bound, not one past it', () {
      final atBound = '"${'a' * (probeJsonMaxChars - 2)}"';
      expect(atBound.length, probeJsonMaxChars);

      expect(probeJsonBody(atBound), 'a' * (probeJsonMaxChars - 2));
      expect(probeJsonBody('$atBound '), isNull);
    });

    test('returns null for a body that is not JSON', () {
      expect(probeJsonBody('<html>'), isNull);
    });

    test('decodes an envelope', () {
      expect(
        probeJsonBody('{"statusCode":403,"message":"m","error":"Forbidden"}'),
        {'statusCode': 403, 'message': 'm', 'error': 'Forbidden'},
      );
    });

    test('passes an already-decoded body through', () {
      final map = {'code': 'EMAIL_NOT_VERIFIED'};
      expect(probeJsonBody(map), same(map));
      expect(probeJsonBody([1]), [1]);
      expect(probeJsonBody(null), isNull);
    });

    test('does not parse a multi-megabyte body, even valid JSON', () {
      // What the bound is for: a captive portal's 2 MB page must not be
      // parsed on the UI isolate. Any envelope-sized bound passes this.
      expect(probeJsonBody('"${'a' * (2 * 1024 * 1024)}"'), isNull);
    });
  });
}
