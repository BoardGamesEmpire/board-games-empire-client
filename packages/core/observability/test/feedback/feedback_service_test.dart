import 'package:observability/observability.dart';
import 'package:test/test.dart';

void main() {
  group('FeedbackSubmissionException', () {
    test('toString without a cause is the message alone', () {
      const exception = FeedbackSubmissionException('queue full');
      expect(
        exception.toString(),
        'FeedbackSubmissionException: queue full',
      );
    });

    test('toString includes the cause when present', () {
      final exception = FeedbackSubmissionException(
        'transport failed',
        cause: StateError('socket closed'),
      );
      expect(
        exception.toString(),
        'FeedbackSubmissionException: transport failed '
        '(cause: Bad state: socket closed)',
      );
    });
  });
}
