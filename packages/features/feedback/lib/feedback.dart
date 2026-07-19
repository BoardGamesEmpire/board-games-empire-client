/// User-initiated feedback feature (#107): the compose form for bug /
/// feature-request reports.
///
/// This package owns the form model, its validation rules, and the
/// compose widget. It deliberately does NOT touch `FeedbackService`,
/// routing, or the review & redaction surface — `app_shell` composes the
/// flow (compose → `FeedbackReviewScreen`) because the review surface
/// lives there and `app_shell` depends on features, never the reverse.
library;

export 'l10n/feedback_localizations.dart';

export 'src/forms/feedback_compose_form_model.dart';
export 'src/models/feedback_compose_result.dart';
export 'src/widgets/feedback_compose_form.dart';
