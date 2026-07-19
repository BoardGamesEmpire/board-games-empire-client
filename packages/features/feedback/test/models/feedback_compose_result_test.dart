import 'package:feedback/feedback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

/// Pins the [FeedbackComposeResult] constructor invariants (#107,
/// PR #110 review): crash is forbidden outright (it originates from the
/// #69 reporter, never the compose flow), bug requires severity, feature
/// request forbids it, and the message must be non-empty.
void main() {
  group('FeedbackComposeResult invariants', () {
    test('forbids the crash category, with or without a severity', () {
      expect(
        () => FeedbackComposeResult(
          category: FeedbackCategory.crash,
          message: 'boom',
        ),
        throwsAssertionError,
      );
      expect(
        () => FeedbackComposeResult(
          category: FeedbackCategory.crash,
          severity: FeedbackSeverity.critical,
          message: 'boom',
        ),
        throwsAssertionError,
      );
    });

    test('requires severity for bug', () {
      expect(
        () => FeedbackComposeResult(
          category: FeedbackCategory.bug,
          message: 'it broke',
        ),
        throwsAssertionError,
      );
    });

    test('forbids severity for feature request', () {
      expect(
        () => FeedbackComposeResult(
          category: FeedbackCategory.featureRequest,
          severity: FeedbackSeverity.low,
          message: 'please add dice',
        ),
        throwsAssertionError,
      );
    });

    test('requires a non-empty message', () {
      expect(
        () => FeedbackComposeResult(
          category: FeedbackCategory.featureRequest,
          message: '',
        ),
        throwsAssertionError,
      );
    });

    test('accepts the two valid shapes', () {
      expect(
        const FeedbackComposeResult(
          category: FeedbackCategory.bug,
          severity: FeedbackSeverity.high,
          message: 'it broke',
        ).severity,
        FeedbackSeverity.high,
      );
      expect(
        const FeedbackComposeResult(
          category: FeedbackCategory.featureRequest,
          message: 'please add dice',
        ).severity,
        isNull,
      );
    });
  });
}
