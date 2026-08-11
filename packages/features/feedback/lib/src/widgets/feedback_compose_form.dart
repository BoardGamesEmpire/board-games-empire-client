import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:observability/observability.dart';
import 'package:reactive_forms/reactive_forms.dart';

import '../../l10n/feedback_localizations.dart';
import '../forms/feedback_compose_form_model.dart';
import '../models/feedback_compose_result.dart';

/// The user-initiated feedback compose form (#107): category, conditional
/// severity, message, optional title.
///
/// Presentation over a **host-owned** [FeedbackComposeFormModel] — the
/// host keeps the model alive across the compose → review round trip so
/// backing out of review restores the user's input (see the model doc).
/// The submit affordance is labelled "Review report" and hands a
/// [FeedbackComposeResult] up via [onSubmit]; nothing is sent from this
/// form (#34 contract) — the host builds the report and presents the
/// review & redaction surface.
///
/// i18n (#33): all copy comes from [FeedbackLocalizations]. WCAG: every
/// field carries a semantic label through its decoration, validation
/// errors render inline through the reactive decorations, the severity
/// field is hidden (not merely disabled) when not applicable, and the
/// submit button exposes an explicit button semantic, mirroring the auth
/// forms (#37).
class FeedbackComposeForm extends StatelessWidget {
  const FeedbackComposeForm({
    required this.model,
    required this.onSubmit,
    this.enabled = true,
    super.key,
  });

  /// The host-owned form state.
  final FeedbackComposeFormModel model;

  /// Receives the validated, trimmed hand-off value when the user submits
  /// a valid form.
  final ValueChanged<FeedbackComposeResult> onSubmit;

  /// Disables every input and the submit affordance (e.g. while the host
  /// is busy). Defaults to true.
  final bool enabled;

  /// Stable finder keys — tests use these so they hold across locales.
  static const Key categoryFieldKey = Key('feedback_compose.category');
  static const Key severityFieldKey = Key('feedback_compose.severity');
  static const Key messageFieldKey = Key('feedback_compose.message');
  static const Key titleFieldKey = Key('feedback_compose.title');
  static const Key submitButtonKey = Key('feedback_compose.submit');

  void _submit() {
    if (!model.validateForSubmit()) return;
    onSubmit(model.buildResult());
  }

  String _categoryLabel(FeedbackLocalizations l10n, FeedbackCategory value) =>
      switch (value) {
        FeedbackCategory.bug => l10n.feedbackComposeCategoryBug,
        FeedbackCategory.featureRequest =>
          l10n.feedbackComposeCategoryFeatureRequest,
        // Crash reports originate from the #69 reporter, never from this
        // form; the label exists only so the switch is exhaustive.
        FeedbackCategory.crash => FeedbackCategory.crash.toWire(),
      };

  String _severityLabel(FeedbackLocalizations l10n, FeedbackSeverity value) =>
      switch (value) {
        FeedbackSeverity.low => l10n.feedbackComposeSeverityLow,
        FeedbackSeverity.medium => l10n.feedbackComposeSeverityMedium,
        FeedbackSeverity.high => l10n.feedbackComposeSeverityHigh,
        FeedbackSeverity.critical => l10n.feedbackComposeSeverityCritical,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = FeedbackLocalizations.of(context);

    return ReactiveForm(
      formGroup: model.form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.feedbackComposeExplanation),
          const BgeGap.md(),
          ReactiveDropdownField<FeedbackCategory>(
            key: FeedbackComposeForm.categoryFieldKey,
            formControlName: FeedbackComposeFormModel.categoryControlName,
            decoration: InputDecoration(
              labelText: l10n.feedbackComposeCategoryLabel,
            ),
            readOnly: !enabled,
            items: [
              for (final category in const [
                FeedbackCategory.bug,
                FeedbackCategory.featureRequest,
              ])
                DropdownMenuItem(
                  value: category,
                  child: Text(_categoryLabel(l10n, category)),
                ),
            ],
            validationMessages: {
              ValidationMessage.required: (_) =>
                  l10n.feedbackComposeErrorRequired,
            },
          ),
          // Severity: shown (and validity-participating — see the model)
          // only for bugs. The builder listens to the category control so
          // the field appears/disappears with the selection.
          ReactiveValueListenableBuilder<FeedbackCategory>(
            formControlName: FeedbackComposeFormModel.categoryControlName,
            builder: (context, control, _) {
              if (control.value != FeedbackCategory.bug) {
                return const SizedBox.shrink();
              }
              // Idempotent reconciliation: a prior feature-request
              // validation may have disabled the control — re-enable it
              // the moment the field is shown again (see the model doc).
              model.syncSeverityEnablement();
              return Padding(
                padding: EdgeInsets.only(top: BgeTokens.of(context).spaceMd),
                child: ReactiveDropdownField<FeedbackSeverity>(
                  key: FeedbackComposeForm.severityFieldKey,
                  formControlName: FeedbackComposeFormModel.severityControlName,
                  readOnly: !enabled,
                  decoration: InputDecoration(
                    labelText: l10n.feedbackComposeSeverityLabel,
                  ),
                  items: [
                    for (final severity in FeedbackSeverity.values)
                      DropdownMenuItem(
                        value: severity,
                        child: Text(_severityLabel(l10n, severity)),
                      ),
                  ],
                  validationMessages: {
                    ValidationMessage.required: (_) =>
                        l10n.feedbackComposeErrorRequired,
                  },
                ),
              );
            },
          ),
          const BgeGap.md(),
          BgeTextField(
            key: FeedbackComposeForm.messageFieldKey,
            formControlName: FeedbackComposeFormModel.messageControlName,
            label: l10n.feedbackComposeMessageLabel,
            hint: l10n.feedbackComposeMessageHint,
            readOnly: !enabled,
            minLines: 3,
            maxLines: 6,
            textInputAction: TextInputAction.newline,
            keyboardType: TextInputType.multiline,
            validationMessages: {
              ValidationMessage.required: (_) =>
                  l10n.feedbackComposeErrorRequired,
            },
          ),
          const BgeGap.md(),
          BgeTextField(
            key: FeedbackComposeForm.titleFieldKey,
            formControlName: FeedbackComposeFormModel.titleControlName,
            label: l10n.feedbackComposeTitleLabel,
            readOnly: !enabled,
            textInputAction: TextInputAction.done,
            onSubmitted: _submit,
          ),
          const BgeGap.lg(),
          BgeSubmitButton(
            key: FeedbackComposeForm.submitButtonKey,
            label: l10n.feedbackComposeReviewButton,
            onPressed: enabled ? _submit : null,
          ),
        ],
      ),
    );
  }
}
