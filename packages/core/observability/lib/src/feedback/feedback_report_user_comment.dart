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
  /// Returns a copy with [comment] appended after the existing message.
  /// An empty or whitespace-only comment returns the report unchanged.
  /// The result is clipped to [FeedbackConstants.maxMessageLength],
  /// preserving the head (the original message).
  FeedbackReport withUserComment(String comment) {
    final trimmed = comment.trim();
    if (trimmed.isEmpty) return this;

    final combined = '$message\n\n$trimmed';
    final capped = combined.length <= FeedbackConstants.maxMessageLength
        ? combined
        : combined.substring(0, FeedbackConstants.maxMessageLength);
    return copyWith(message: capped);
  }
}
