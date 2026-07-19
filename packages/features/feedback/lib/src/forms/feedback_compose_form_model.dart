import 'package:observability/observability.dart';
import 'package:reactive_forms/reactive_forms.dart';

import '../models/feedback_compose_result.dart';

/// The compose form's state model (#107): a host-owned wrapper around the
/// `reactive_forms` [FormGroup].
///
/// Host-owned deliberately: `app_shell`'s feedback flow keeps this model
/// alive across the compose → review → back-to-compose round trip, so the
/// user's typed input and selections survive backing out of review (the
/// same reason the crash review's redaction state lives above the widget
/// in #76). The widget ([FeedbackComposeForm]) is presentation over this
/// model and holds no form state of its own.
///
/// ## Conditional severity
///
/// Severity is required for bugs and **not applicable** to feature
/// requests. The model expresses this through control enablement rather
/// than validator juggling: for [FeedbackCategory.featureRequest] the
/// severity control is disabled (disabled controls are excluded from
/// group validity in `reactive_forms`) — with any previously picked value
/// preserved, so a category round trip doesn't discard the user's choice.
/// The widget layer additionally hides the field for feature requests
/// (the #107 spec: hidden, not just inert), keyed directly off the
/// category control's value.
///
/// Enablement is synchronized **synchronously at the seams that consume
/// it** ([validateForSubmit], and derived in [severityApplicable]) rather
/// than via a `valueChanges` subscription: reactive_forms delivers stream
/// events on a later microtask, so a subscription leaves a window where a
/// category change followed immediately by a submit validates against
/// stale enablement. Deterministic sync-at-read closes that race and
/// needs no subscription lifecycle at all.
class FeedbackComposeFormModel {
  FeedbackComposeFormModel() {
    form = FormGroup({
      categoryControlName: FormControl<FeedbackCategory>(
        value: FeedbackCategory.bug,
        validators: [Validators.required],
      ),
      severityControlName: FormControl<FeedbackSeverity>(
        validators: [Validators.required],
      ),
      messageControlName: FormControl<String>(
        value: '',
        validators: [Validators.required],
      ),
      titleControlName: FormControl<String>(value: ''),
    });
  }

  static const String categoryControlName = 'category';
  static const String severityControlName = 'severity';
  static const String messageControlName = 'message';
  static const String titleControlName = 'title';

  late final FormGroup form;

  FormControl<FeedbackCategory> get _category =>
      form.control(categoryControlName) as FormControl<FeedbackCategory>;
  FormControl<FeedbackSeverity> get _severity =>
      form.control(severityControlName) as FormControl<FeedbackSeverity>;
  FormControl<String> get _message =>
      form.control(messageControlName) as FormControl<String>;
  FormControl<String> get _title =>
      form.control(titleControlName) as FormControl<String>;

  /// The currently selected category. Never null — the control is seeded
  /// with [FeedbackCategory.bug] and the selector offers no empty option.
  FeedbackCategory get category => _category.value ?? FeedbackCategory.bug;

  /// Whether severity applies to the current category (true for bug).
  /// Derived from the category value — the synchronous source of truth —
  /// not from control enablement, which is only reconciled at validation
  /// time (see the class doc). The widget hides the field when this is
  /// false.
  bool get severityApplicable => category == FeedbackCategory.bug;

  /// Reconciles the severity control's enablement with the current
  /// category (see the class doc). Idempotent and synchronous; called by
  /// [validateForSubmit] before computing validity, and by the widget
  /// when it (re)shows the severity field — so a field disabled by a
  /// feature-request validation is enabled again the moment a switch back
  /// to bug makes it visible.
  void syncSeverityEnablement() {
    if (severityApplicable) {
      _severity.markAsEnabled();
    } else {
      // Disabled ⇒ excluded from validity; the value is intentionally
      // kept so switching back restores the prior choice.
      _severity.markAsDisabled();
    }
  }

  /// Validates for submission: reconciles severity enablement with the
  /// current category (see the class doc), then returns true when the
  /// form is valid; otherwise marks every enabled control touched
  /// (surfacing the localized required errors) and returns false.
  bool validateForSubmit() {
    syncSeverityEnablement();
    if (form.valid) return true;
    form.markAllAsTouched();
    return false;
  }

  /// Builds the hand-off value from the current (valid) form state:
  /// message and title trimmed, empty title normalized to null, severity
  /// carried only for bugs. Call only after [validateForSubmit] returned
  /// true — construction asserts the same invariants.
  FeedbackComposeResult buildResult() {
    final category = this.category;
    final title = _title.value?.trim() ?? '';
    return FeedbackComposeResult(
      category: category,
      message: _message.value?.trim() ?? '',
      severity: category == FeedbackCategory.bug ? _severity.value : null,
      title: title.isEmpty ? null : title,
    );
  }

  /// Disposes the form. The owning host calls this from its `dispose`.
  void dispose() => form.dispose();
}
