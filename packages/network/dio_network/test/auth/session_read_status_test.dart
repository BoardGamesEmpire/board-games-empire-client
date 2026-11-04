import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('readSessionStatus', () {
    const table = <(int?, SessionReadStatus)>[
      (401, SessionReadStatus.noSession),
      (403, SessionReadStatus.noSession),
      (200, SessionReadStatus.readBody),
      // A missing status, any other 2xx, a 3xx and every other 4xx or 5xx
      // say nothing about the session.
      (null, SessionReadStatus.undecided),
      (201, SessionReadStatus.undecided),
      (204, SessionReadStatus.undecided),
      (301, SessionReadStatus.undecided),
      (304, SessionReadStatus.undecided),
      (400, SessionReadStatus.undecided),
      (404, SessionReadStatus.undecided),
      (407, SessionReadStatus.undecided),
      (408, SessionReadStatus.undecided),
      (429, SessionReadStatus.undecided),
      (500, SessionReadStatus.undecided),
      (502, SessionReadStatus.undecided),
      (503, SessionReadStatus.undecided),
    ];

    for (final (status, expected) in table) {
      test('$status → $expected', () {
        expect(readSessionStatus(status), expected);
      });
    }
  });
}
