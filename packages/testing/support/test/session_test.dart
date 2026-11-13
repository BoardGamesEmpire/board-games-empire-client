import 'package:bge_test_support/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FakeSessionLease', () {
    test('is live unless started otherwise', () {
      expect(FakeSessionLease().isLive, isTrue);
      expect(FakeSessionLease(isLive: false).isLive, isFalse);
    });

    test('ends when a test sets it', () {
      final lease = FakeSessionLease()..isLive = false;

      expect(lease.isLive, isFalse);
    });
  });
}
