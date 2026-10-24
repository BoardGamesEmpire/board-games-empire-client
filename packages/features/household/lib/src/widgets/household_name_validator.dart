import 'package:reactive_forms/reactive_forms.dart';

/// Required-after-trim (PR #130 review), matching the
/// `FeedbackComposeFormModel` precedent: `Validators.required` admits
/// whitespace-only input, which the repository then rejects after trimming
/// — surfacing as a generic failure snackbar instead of an inline field
/// error. Validity must match the trimmed hand-off value. Emits the
/// standard required error key so the existing localized message applies.
///
/// Shared by the create and edit forms (#476). The server accepts a blank
/// name on both (backend#884), so this is the only guard.
Map<String, dynamic>? requiredTrimmed(AbstractControl<dynamic> control) {
  final value = control.value;
  final trimmed = value is String ? value.trim() : '';
  return trimmed.isEmpty
      ? <String, dynamic>{ValidationMessage.required: true}
      : null;
}
