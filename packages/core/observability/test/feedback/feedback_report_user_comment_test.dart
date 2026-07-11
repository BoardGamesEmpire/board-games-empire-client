import 'package:observability/observability.dart';
import 'package:test/test.dart';

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

    test('leaves the message untouched when not even one comment '
        'character fits after the separator', () {
      // Message two under the cap: the separator alone (\n\n) would fill
      // the remaining budget, leaving no room for comment text. The
      // report must come back byte-identical rather than gaining a bare
      // separator.
      final full = FeedbackReport(
        category: FeedbackCategory.crash,
        severity: FeedbackSeverity.critical,
        message: 'm' * (FeedbackConstants.maxMessageLength - 2),
        correlationKey: 'key-1',
      );

      final result = full.withUserComment('would not fit');

      expect(result, full);
      expect(result.message.length, FeedbackConstants.maxMessageLength - 2);
    });

    test('appends exactly the comment characters that fit the remaining '
        'budget', () {
      // One character of headroom for the comment after the separator.
      final nearFull = FeedbackReport(
        category: FeedbackCategory.crash,
        severity: FeedbackSeverity.critical,
        message: 'm' * (FeedbackConstants.maxMessageLength - 3),
        correlationKey: 'key-1',
      );

      final result = nearFull.withUserComment('AB');

      expect(result.message.length, FeedbackConstants.maxMessageLength);
      expect(result.message, endsWith('\n\nA'));
      expect(result.message, isNot(contains('B')));
      expect(result.validate(), isNot(contains(contains('message'))));
    });
  });
}
