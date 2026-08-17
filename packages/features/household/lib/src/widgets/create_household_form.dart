import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

/// The create-household form: a required name and an optional description.
///
/// Owns its [FormGroup] (reactive_forms, per the project's form convention —
/// one `valueChanges` subscription, for [onEdited]; everything else is
/// derived synchronously and validated at submit). Calls [onSubmit] with the
/// field values when valid, otherwise marks the controls touched so
/// validation messages show.
///
/// Accessibility: each field carries a visible label via [InputDecoration]
/// (which the framework also exposes to screen readers as the field's
/// accessible name); the name field advances to the description with the
/// keyboard's "next" action, and the description's "done" action submits.
///
/// The in-flight treatment comes from [BgeSubmitButton] (#165). It used to be
/// hand-rolled here, copied from `ServerAddForm` — which is how #163's
/// overflow reached two screens instead of one. The button is disabled but
/// **keeps an accessible name**, swapping the submit label for a localized
/// progress label rather than leaving a bare spinner, inside a live region so
/// assistive tech announces the change instead of only exposing it on next
/// focus. All of that now lives in one widget.
///
/// The fields go read-only while submitting: their values were captured at
/// submit, so edits during the send would be silently discarded, and read-only
/// also tears down the input connection, which closes the keyboard submit path
/// while in flight.
class CreateHouseholdForm extends StatefulWidget {
  const CreateHouseholdForm({
    required this.onSubmit,
    this.submitting = false,
    this.onEdited,
    super.key,
  });

  /// Invoked with validated values. [description] is `null` when blank.
  final void Function({required String name, String? description}) onSubmit;

  /// When true, the fields are read-only and the submit button is disabled
  /// and shows the localized progress label with a spinner.
  final bool submitting;

  /// Invoked on every value change, so the caller can retire an error banner
  /// that describes the value being replaced.
  ///
  /// Every change, not just the first after a failure: the form has no view
  /// of the submission state. The caller filters — its bloc drops the event
  /// unless a failure is actually showing — which keeps form and bloc
  /// knowledge apart at the cost of a no-op event per keystroke.
  final VoidCallback? onEdited;

  /// Stable finder keys for widget tests.
  static const Key nameFieldKey = Key('create_household.name');
  static const Key descriptionFieldKey = Key('create_household.description');
  static const Key submitButtonKey = Key('create_household.submit');

  @override
  State<CreateHouseholdForm> createState() => _CreateHouseholdFormState();
}

class _CreateHouseholdFormState extends State<CreateHouseholdForm> {
  final FormGroup _form = FormGroup({
    'name': FormControl<String>(
      validators: [Validators.delegate(_requiredTrimmed)],
    ),
    'description': FormControl<String>(),
  });

  /// Required-after-trim (PR #130 review), matching the
  /// `FeedbackComposeFormModel` precedent: `Validators.required` admits
  /// whitespace-only input, which the repository then rejects after trimming
  /// — surfacing as a generic failure snackbar instead of an inline field
  /// error. Validity must match the trimmed hand-off value. Emits the
  /// standard required error key so the existing localized message applies.
  static Map<String, dynamic>? _requiredTrimmed(
    AbstractControl<dynamic> control,
  ) {
    final value = control.value;
    final trimmed = value is String ? value.trim() : '';
    return trimmed.isEmpty
        ? <String, dynamic>{ValidationMessage.required: true}
        : null;
  }

  StreamSubscription<Object?>? _editSubscription;

  @override
  void initState() {
    super.initState();
    // A stream subscription rather than an `onChanged`: BgeTextField exposes
    // none, and the control is the thing that actually changes.
    _editSubscription = _form.valueChanges.listen((_) {
      if (mounted) widget.onEdited?.call();
    });
  }

  @override
  void dispose() {
    _editSubscription?.cancel();
    _form.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.submitting) return;
    if (!_form.valid) {
      _form.markAllAsTouched();
      return;
    }
    final name = (_form.control('name').value as String?)?.trim() ?? '';
    final rawDescription = (_form.control('description').value as String?)
        ?.trim();
    widget.onSubmit(
      name: name,
      description: (rawDescription == null || rawDescription.isEmpty)
          ? null
          : rawDescription,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          BgeTextField(
            key: CreateHouseholdForm.nameFieldKey,
            formControlName: 'name',
            label: l10n.createHouseholdNameLabel,
            readOnly: widget.submitting,
            validationMessages: {
              ValidationMessage.required: (_) =>
                  l10n.createHouseholdNameRequired,
            },
          ),
          const BgeGap.md(),
          BgeTextField(
            key: CreateHouseholdForm.descriptionFieldKey,
            formControlName: 'description',
            label: l10n.createHouseholdDescriptionLabel,
            readOnly: widget.submitting,
            textInputAction: TextInputAction.done,
            minLines: 1,
            maxLines: 3,
            onSubmitted: _submit,
          ),
          const BgeGap.lg(),
          BgeSubmitButton(
            key: CreateHouseholdForm.submitButtonKey,
            label: l10n.createHouseholdSubmit,
            progressLabel: l10n.createHouseholdInProgress,
            submitting: widget.submitting,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
