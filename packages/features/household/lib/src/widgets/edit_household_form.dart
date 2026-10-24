import 'dart:async';

import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

import 'household_name_validator.dart';

/// The household edit form (#476): the name and description, as the create
/// form takes them, and the member invite policy as a three-way choice that
/// says what each option means.
///
/// Works as `CreateHouseholdForm` does: it owns its [FormGroup], trims on
/// submit, hands a blank description back as null, and goes read-only while
/// submitting.
///
/// The values come from [initial] once, in `initState`. A later [initial]
/// is ignored, so a household read again under the open form never
/// replaces what was typed.
///
/// The cached policy is preselected. When there is none, or it is one this
/// client does not know, a note says so and a fourth option, to leave it as
/// it is, comes first and is chosen. Choosing it again after another undoes
/// that choice: submitting with it leaves the policy as the server has it.
class EditHouseholdForm extends StatefulWidget {
  const EditHouseholdForm({
    required this.initial,
    required this.onSubmit,
    this.submitting = false,
    this.failure,
    this.onEdited,
    super.key,
  });

  /// The household the form opens with. Read once.
  final Household initial;

  /// Invoked with validated values. [description] is null when blank, and
  /// [memberInvitePolicy] is null when no option is chosen.
  final void Function({
    required String name,
    String? description,
    MemberInvitePolicy? memberInvitePolicy,
  })
  onSubmit;

  /// When true, the fields are read-only, the options disabled, and the
  /// submit button shows its progress label.
  final bool submitting;

  /// The failure of the last submit, shown directly above the submit button.
  final BgeFormFailure? failure;

  /// Invoked on every value change, so the caller can retire a failure that
  /// describes the values being replaced.
  final VoidCallback? onEdited;

  /// Stable finder keys for widget tests.
  static const Key nameFieldKey = Key('edit_household.name');
  static const Key descriptionFieldKey = Key('edit_household.description');
  static const Key submitButtonKey = Key('edit_household.submit');

  /// The option that leaves a policy this client does not know as it is.
  static const Key policyUnchangedKey = Key('edit_household.policy_unchanged');

  /// Per-option key: `edit_household.policy_<name>`.
  static Key policyOptionKey(MemberInvitePolicy policy) =>
      Key('edit_household.policy_${policy.name}');

  /// The policies offered, in the order the form lists them. Never
  /// [MemberInvitePolicy.unknown], which has no wire name.
  static const List<MemberInvitePolicy> _offered = [
    MemberInvitePolicy.direct,
    MemberInvitePolicy.needsApproval,
    MemberInvitePolicy.off,
  ];

  @override
  State<EditHouseholdForm> createState() => _EditHouseholdFormState();
}

class _EditHouseholdFormState extends State<EditHouseholdForm> {
  late final FormGroup _form;

  /// Whether the cache held a policy this client knows, so one is
  /// preselected.
  late final bool _policyKnown;

  StreamSubscription<Object?>? _editSubscription;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    final policy = initial.settings?.memberInvitePolicy;
    _policyKnown = policy != null && policy != MemberInvitePolicy.unknown;
    _form = FormGroup({
      'name': FormControl<String>(
        value: initial.name,
        validators: [Validators.delegate(requiredTrimmed)],
      ),
      'description': FormControl<String>(value: initial.description),
      'policy': FormControl<MemberInvitePolicy>(
        value: _policyKnown ? policy : null,
      ),
    });
    _editSubscription = _form.valueChanges.listen((_) {
      if (mounted) widget.onEdited?.call();
    });
  }

  @override
  void dispose() {
    unawaited(_editSubscription?.cancel());
    _form.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.submitting) return;
    if (!_form.valid) {
      _form.rejectSubmit();
      return;
    }
    final name = (_form.control('name').value as String?)?.trim() ?? '';
    final description = (_form.control('description').value as String?)?.trim();
    widget.onSubmit(
      name: name,
      description: (description == null || description.isEmpty)
          ? null
          : description,
      memberInvitePolicy: _form.control('policy').value as MemberInvitePolicy?,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          BgeTextField(
            key: EditHouseholdForm.nameFieldKey,
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
            key: EditHouseholdForm.descriptionFieldKey,
            formControlName: 'description',
            label: l10n.createHouseholdDescriptionLabel,
            readOnly: widget.submitting,
            textInputAction: TextInputAction.done,
            minLines: 1,
            maxLines: 3,
            onSubmitted: _submit,
          ),
          const BgeGap.lg(),
          Text(
            l10n.editHouseholdPolicyLabel,
            style: theme.textTheme.titleMedium,
          ),
          const BgeGap.xs(),
          Text(
            l10n.editHouseholdPolicyIntro,
            style: theme.textTheme.bodyMedium,
          ),
          if (!_policyKnown) ...[
            const BgeGap.sm(),
            Text(
              l10n.editHouseholdPolicyNotKnown,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const BgeGap.sm(),
          ReactiveValueListenableBuilder<MemberInvitePolicy>(
            formControlName: 'policy',
            // Nullable, so that leaving it as it is is an option like the
            // others.
            builder: (context, control, _) => RadioGroup<MemberInvitePolicy?>(
              groupValue: control.value,
              // Read-only while submitting, as the fields are: the options
              // stay in the focus order and simply ignore a change.
              onChanged: (policy) {
                if (!widget.submitting) control.value = policy;
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_policyKnown)
                    RadioListTile<MemberInvitePolicy?>(
                      key: EditHouseholdForm.policyUnchangedKey,
                      value: null,
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.editHouseholdPolicyUnchanged),
                      subtitle: Text(l10n.editHouseholdPolicyUnchangedDetail),
                    ),
                  for (final policy in EditHouseholdForm._offered)
                    _option(l10n, policy),
                ],
              ),
            ),
          ),
          const BgeGap.lg(),
          BgeFormActions(
            failure: widget.failure,
            action: BgeSubmitButton(
              key: EditHouseholdForm.submitButtonKey,
              label: l10n.editHouseholdSave,
              progressLabel: l10n.editHouseholdSaving,
              submitting: widget.submitting,
              onPressed: _submit,
            ),
          ),
        ],
      ),
    );
  }

  static Widget _option(
    HouseholdLocalizations l10n,
    MemberInvitePolicy policy,
  ) {
    final (title, detail) = _labels(l10n, policy);
    return RadioListTile<MemberInvitePolicy?>(
      key: EditHouseholdForm.policyOptionKey(policy),
      value: policy,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(detail),
    );
  }

  /// An option's title, and the line under it saying what it means.
  static (String, String) _labels(
    HouseholdLocalizations l10n,
    MemberInvitePolicy policy,
  ) => switch (policy) {
    MemberInvitePolicy.direct => (
      l10n.editHouseholdPolicyDirect,
      l10n.editHouseholdPolicyDirectDetail,
    ),
    MemberInvitePolicy.needsApproval => (
      l10n.editHouseholdPolicyNeedsApproval,
      l10n.editHouseholdPolicyNeedsApprovalDetail,
    ),
    MemberInvitePolicy.off => (
      l10n.editHouseholdPolicyOff,
      l10n.editHouseholdPolicyOffDetail,
    ),
    // Never offered; see EditHouseholdForm._offered.
    MemberInvitePolicy.unknown => ('', ''),
  };
}
