import 'package:observability/observability.dart';
import 'package:test/test.dart';

/// Red-phase tests for the `withUserComment` extension on
/// `FeedbackReport` (issue #69).
///
/// The crash draft is built at **capture** time (fresh breadcrumbs); the
/// user's comment arrives at **approval** time. Rebuilding via
/// `buildReport` would re-snapshot post-crash breadcrumb noise, so the
/// comment is woven into the existing draft's message instead — a pure
/// helper the prompt uses.
void main() {
  const draft = FeedbackReport(
    category: FeedbackCategory.crash,
    severity: FeedbackSeverity.critical,
    message: 'StateError: bad state',
    correlationKey: 'key-1',
  );

  group('FeedbackReport.withUserComment', () {
    test('appends the comment after the existing message', () {
      final result = draft.withUserComment('I was adding a game');

      expect(result.message, contains('StateError: bad state'));
      expect(result.message, contains('I was adding a game'));
      expect(
        result.message.indexOf('StateError'),
        lessThan(result.message.indexOf('I was adding')),
      );
    });

    test('leaves everything but the message untouched', () {
      final result = draft.withUserComment('a comment');

      expect(result.category, draft.category);
      expect(result.severity, draft.severity);
      expect(result.correlationKey, draft.correlationKey);
    });

    test('an empty or whitespace-only comment returns the report '
        'unchanged', () {
      expect(draft.withUserComment(''), draft);
      expect(draft.withUserComment('   \n'), draft);
    });

    test('stays within the message cap — the comment is trimmed to fit, '
        'the original message is preserved', () {
      final result = draft.withUserComment(
        'c' * (FeedbackConstants.maxMessageLength + 100),
      );

      expect(
        result.message.length,
        lessThanOrEqualTo(FeedbackConstants.maxMessageLength),
      );
      expect(result.message, startsWith('StateError: bad state'));
      expect(result.validate(), isNot(contains(contains('message'))));
    });
  });
}
