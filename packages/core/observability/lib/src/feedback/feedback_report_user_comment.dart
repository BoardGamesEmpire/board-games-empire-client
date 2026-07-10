import 'feedback_constants.dart';
import 'feedback_report.dart';

/// Weaves the user's comment into an already-built crash [FeedbackReport]
/// at approval time (#69).
///
/// The crash draft is built at capture time (fresh breadcrumbs — see
/// `FeedbackUncaughtErrorReporter`); the user's comment arrives later,
/// when they approve the prompt. Rebuilding via
/// `FeedbackService.buildReport` would re-snapshot post-crash breadcrumb
/// noise, so the comment is appended to the existing draft's message
/// instead — everything else (stack trace, breadcrumbs, correlationKey,
/// environment) is preserved.
extension FeedbackReportUserComment on FeedbackReport {
  /// Returns a copy with [comment] appended after the existing message,
  /// separated by a blank line. An empty or whitespace-only comment — or
  /// a message already so close to [FeedbackConstants.maxMessageLength]
  /// that not even one character of the comment would fit after the
  /// separator — returns the report unchanged (the original message is
  /// never mutated just to append a bare separator). Otherwise the
  /// comment is trimmed to the remaining budget so the result stays at or
  /// under the cap.
  FeedbackReport withUserComment(String comment) {
    final trimmed = comment.trim();
    if (trimmed.isEmpty) return this;

    const separator = '\n\n';
    final budget =
        FeedbackConstants.maxMessageLength - message.length - separator.length;
    // No room for even one character of the comment (also covers an
    // already over-cap message, where budget is negative): leave the
    // message untouched rather than appending a partial separator.
    if (budget < 1) return this;

    final fitted = trimmed.length <= budget
        ? trimmed
        : trimmed.substring(0, budget);
    return copyWith(message: '$message$separator$fitted');
  }
}
