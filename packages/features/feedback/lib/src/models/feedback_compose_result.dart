import 'package:flutter/foundation.dart';
import 'package:observability/observability.dart';

/// The immutable hand-off value a valid compose form produces (#107).
///
/// The host (`app_shell`'s feedback flow) feeds this into
/// `FeedbackService.buildReport`: [message] maps to `userComment`
/// (`errorMessage` stays null — user-initiated reports carry no error
/// text, which satisfies the service's at-least-one-non-empty rule), and
/// [category]/[severity]/[title] pass through.
///
/// Invariants mirror `FeedbackReport`'s constructor asserts so an invalid
/// combination fails at the seam it was produced, not two layers later:
/// [category] must never be [FeedbackCategory.crash] — crash reports
/// originate exclusively from the #69 uncaught-error reporter, never from
/// the compose flow (PR #110 review: forbidden outright rather than left
/// as a documented assumption); [severity] is required for
/// [FeedbackCategory.bug] and must be absent for
/// [FeedbackCategory.featureRequest]; [message] must be non-empty.
@immutable
class FeedbackComposeResult {
  const FeedbackComposeResult({
    required this.category,
    required this.message,
    this.severity,
    this.title,
  }) : assert(
         category != FeedbackCategory.crash,
         'crash reports originate from the uncaught-error reporter, '
         'never from the compose flow',
       ),
       assert(
         category != FeedbackCategory.bug || severity != null,
         'severity is required when category is bug',
       ),
       assert(
         category != FeedbackCategory.featureRequest || severity == null,
         'severity is not applicable to feature requests',
       ),
       assert(message != '', 'message must not be empty');

  /// What kind of report this is: [FeedbackCategory.bug] or
  /// [FeedbackCategory.featureRequest].
  final FeedbackCategory category;

  /// The trimmed, non-empty report body — the future `userComment`.
  final String message;

  /// Required for bugs, null for feature requests.
  final FeedbackSeverity? severity;

  /// Optional short title; empty input is normalized to null by the form
  /// model before construction.
  final String? title;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FeedbackComposeResult &&
          other.category == category &&
          other.message == message &&
          other.severity == severity &&
          other.title == title;

  @override
  int get hashCode => Object.hash(category, message, severity, title);

  @override
  String toString() =>
      'FeedbackComposeResult(category: $category, severity: $severity, '
      'title: $title, message: $message)';
}
