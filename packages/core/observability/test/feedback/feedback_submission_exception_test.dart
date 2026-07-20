import 'package:observability/observability.dart';
import 'package:test/test.dart';

/// The #97 failure taxonomy, matching the AuthException sealed style:
/// transient (retryable) vs permanent vs persistence ("couldn't even
/// queue"). Sealed means every consumer switch is compiler-checked
/// exhaustive — [describe] below fails to compile if a variant is added
/// without handling.
String describe(FeedbackSubmissionException e) => switch (e) {
  FeedbackTransientSubmissionException(:final statusCode) =>
    'transient:$statusCode',
  FeedbackPermanentSubmissionException(:final statusCode) =>
    'permanent:$statusCode',
  FeedbackPersistenceException(:final transportCause) =>
    'persistence:$transportCause',
};

void main() {
  group('FeedbackSubmissionException taxonomy', () {
    test('is sealed and exhaustively switchable', () {
      expect(
        describe(const FeedbackTransientSubmissionException('x')),
        'transient:null',
      );
      expect(
        describe(
          const FeedbackTransientSubmissionException('x', statusCode: 429),
        ),
        'transient:429',
      );
      expect(
        describe(
          const FeedbackPermanentSubmissionException('x', statusCode: 403),
        ),
        'permanent:403',
      );
      expect(
        describe(
          const FeedbackPersistenceException('x', transportCause: 'offline'),
        ),
        'persistence:offline',
      );
    });

    test('all variants are FeedbackSubmissionExceptions — pre-#97 '
        'catch-alls keep working', () {
      expect(
        const FeedbackTransientSubmissionException('x'),
        isA<FeedbackSubmissionException>(),
      );
      expect(
        const FeedbackPermanentSubmissionException('x'),
        isA<FeedbackSubmissionException>(),
      );
      expect(
        const FeedbackPersistenceException('x'),
        isA<FeedbackSubmissionException>(),
      );
    });

    test('toString names the concrete variant and includes the cause '
        'when present', () {
      expect(
        const FeedbackTransientSubmissionException('network down').toString(),
        allOf(
          contains('FeedbackTransientSubmissionException'),
          contains('network down'),
        ),
      );
      expect(
        const FeedbackPersistenceException(
          'disk full',
          cause: 'ENOSPC',
        ).toString(),
        allOf(contains('FeedbackPersistenceException'), contains('ENOSPC')),
      );
    });

    test('persistence variant carries the sink fault as cause and the '
        'prior transport failure alongside', () {
      const e = FeedbackPersistenceException(
        'could not queue',
        cause: 'disk full',
        transportCause: 'timeout',
      );

      expect(e.cause, 'disk full');
      expect(e.transportCause, 'timeout');
    });
  });
}
