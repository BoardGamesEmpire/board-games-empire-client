import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';

import 'package:household/l10n/household_localizations.dart';

/// The create-household form: a required name and an optional description.
///
/// Owns its [FormGroup] (reactive_forms, per the project's form convention —
/// no `valueChanges` subscriptions; state is derived synchronously and
/// validated at submit). Calls [onSubmit] with the field values when valid,
/// otherwise marks the controls touched so validation messages show.
///
/// Accessibility: each field carries a visible label via [InputDecoration]
/// (which the framework also exposes to screen readers as the field's
/// accessible name); the name field advances to the description with the
/// keyboard's "next" action, and the description's "done" action submits.
///
/// The in-flight treatment follows `ServerAddForm` (#36), which is the
/// house pattern for this (#132): the button is disabled but **keeps an
/// accessible name** — it swaps the submit label for a localized progress
/// label rather than leaving a bare spinner, and the swap sits in a
/// [Semantics] live region so assistive tech announces the state change
/// instead of only exposing it on next focus. The fields go read-only for
/// the same reason they do there: their values were captured at submit, so
/// edits during the send would be silently discarded, and read-only also
/// tears down the input connection, which closes the keyboard submit path
/// while in flight.
class CreateHouseholdForm extends StatefulWidget {
  const CreateHouseholdForm({
    required this.onSubmit,
    this.submitting = false,
    super.key,
  });

  /// Invoked with validated values. [description] is `null` when blank.
  final void Function({required String name, String? description}) onSubmit;

  /// When true, the fields are read-only and the submit button is disabled
  /// and shows the localized progress label with a spinner.
  final bool submitting;

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

  @override
  void dispose() {
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
          ReactiveTextField<String>(
            key: CreateHouseholdForm.nameFieldKey,
            formControlName: 'name',
            readOnly: widget.submitting,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: l10n.createHouseholdNameLabel,
              border: const OutlineInputBorder(),
            ),
            validationMessages: {
              ValidationMessage.required: (_) =>
                  l10n.createHouseholdNameRequired,
            },
          ),
          const SizedBox(height: 16),
          ReactiveTextField<String>(
            key: CreateHouseholdForm.descriptionFieldKey,
            formControlName: 'description',
            readOnly: widget.submitting,
            textInputAction: TextInputAction.done,
            minLines: 1,
            maxLines: 3,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.createHouseholdDescriptionLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            key: CreateHouseholdForm.submitButtonKey,
            onPressed: widget.submitting ? null : _submit,
            child: widget.submitting
                ? Semantics(
                    liveRegion: true,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        // Flexible, not a bare Text: the label's intrinsic
                        // width outgrows a narrow screen at large text scale,
                        // and an unbounded child in a Row overflows rather
                        // than wrapping. Let it wrap and grow the button.
                        Flexible(child: Text(l10n.createHouseholdInProgress)),
                      ],
                    ),
                  )
                : Text(l10n.createHouseholdSubmit),
          ),
        ],
      ),
    );
  }
}
