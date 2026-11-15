import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/widgets/day_count_field.dart';
import 'package:server_settings/src/widgets/settings_group_binding.dart';
import 'package:server_settings/src/widgets/settings_group_form.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The Contributions group of the server settings (#894): whether media
/// contributions wait for staff approval, and for how many days a rejected
/// one may be reclaimed.
///
/// A [SettingsGroupForm], which says how it takes new values from the server
/// and what a role that may not save sees. The patch [binding] gets is what
/// changed, against the settings the form last took: each setting only when it
/// changed.
class ContributionsSettingsForm extends StatelessWidget {
  const ContributionsSettingsForm({
    required this.binding,
    super.key,
  });

  static const Key approvalSwitchKey = Key(
    'contributions_settings_form.approval',
  );
  static const Key reclaimFieldKey = Key('contributions_settings_form.reclaim');
  static const Key saveKey = Key('contributions_settings_form.save');
  static const Key savedKey = Key('contributions_settings_form.saved');
  static const Key failureKey = Key('contributions_settings_form.failure');

  static const String _approval = 'approval';
  static const String _reclaim = 'reclaim';

  final SettingsGroupBinding binding;

  static FormGroup _buildForm(Map<String, Object?> values) => FormGroup({
    _approval: FormControl<bool>(value: values[_approval] as bool?),
    _reclaim: FormControl<String>(
      value: values[_reclaim] as String?,
      validators: [Validators.delegate(validDayCount)],
    ),
  });

  static Map<String, Object?> _valuesOf(SystemSettings settings) => {
    _approval: settings.requireContributionApproval,
    _reclaim: '${settings.contributionReclaimDays}',
  };

  static SystemSettingsPatch _patchOf(SystemSettings base, FormGroup form) {
    final approval = form.control(_approval).value == true;
    final days = dayCount(form.control(_reclaim).value)!;
    return SystemSettingsPatch(
      requireContributionApproval: approval == base.requireContributionApproval
          ? null
          : approval,
      contributionReclaimDays: days == base.contributionReclaimDays
          ? null
          : days,
    );
  }

  static String _lastField(FormGroup _) => _reclaim;

  @override
  Widget build(BuildContext context) {
    final l10n = ServerSettingsLocalizations.of(context);

    return SettingsGroupForm(
      binding: binding,
      buildForm: _buildForm,
      valuesOf: _valuesOf,
      patchOf: _patchOf,
      lastField: _lastField,
      labels: SettingsGroupLabels(
        saveKey: saveKey,
        saveLabel: l10n.contributionsSave,
        savingLabel: l10n.contributionsSaving,
        savedKey: savedKey,
        savedMessage: l10n.contributionsSaved,
        failureKey: failureKey,
        failureTitle: l10n.contributionsNotSavedTitle,
      ),
      fields: _fields,
    );
  }

  Widget _fields(
    BuildContext context, {
    required bool readOnly,
    required VoidCallback submit,
  }) {
    final l10n = ServerSettingsLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        BgeSwitchField(
          formControlName: _approval,
          label: l10n.contributionsApprovalLabel,
          subtitle: l10n.contributionsApprovalSubtitle,
          readOnly: readOnly,
          switchKey: approvalSwitchKey,
        ),
        const BgeGap.md(),
        DayCountField(
          fieldKey: reclaimFieldKey,
          formControlName: _reclaim,
          label: l10n.contributionsReclaimLabel,
          readOnly: readOnly,
          onSubmitted: binding.maySave ? submit : null,
        ),
      ],
    );
  }
}
