import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/widgets/day_count_field.dart';
import 'package:server_settings/src/widgets/settings_group_binding.dart';
import 'package:server_settings/src/widgets/settings_group_form.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The Data retention group of the server settings (#894): for how many days
/// feedback reports are kept, whether the server redacts them, and whether
/// old audit log entries are deleted, and after how many days.
///
/// A [SettingsGroupForm], which says how it takes new values from the server
/// and what a role that may not save sees. The patch [binding] gets is what
/// changed, against the settings the form last took: each setting only when it
/// changed.
///
/// Redaction off shows a warning under its switch, saved or picked: the
/// server then stores reports as they arrive. The audit days show only while
/// the audit switch is on, and are checked only then, so a count left
/// invalid doesn't hold up a save that turns the switch off. Off sends a
/// clear, which keeps entries indefinitely.
class RetentionSettingsForm extends StatelessWidget {
  const RetentionSettingsForm({
    required this.binding,
    super.key,
  });

  static const Key feedbackDaysFieldKey = Key(
    'retention_settings_form.feedbackDays',
  );
  static const Key redactionSwitchKey = Key(
    'retention_settings_form.redaction',
  );
  static const Key redactionWarningKey = Key(
    'retention_settings_form.redactionWarning',
  );
  static const Key auditSwitchKey = Key('retention_settings_form.audit');
  static const Key auditDaysFieldKey = Key('retention_settings_form.auditDays');
  static const Key saveKey = Key('retention_settings_form.save');
  static const Key savedKey = Key('retention_settings_form.saved');
  static const Key failureKey = Key('retention_settings_form.failure');

  static const String _feedbackDays = 'feedbackDays';
  static const String _redaction = 'redaction';
  static const String _audit = 'audit';
  static const String _auditDays = 'auditDays';

  final SettingsGroupBinding binding;

  /// Sets the days' error while the audit switch is on and they aren't a
  /// count in range, and clears it otherwise.
  ///
  /// A check on the group, not on the days: it runs whenever either control
  /// moves, at once, and when the group is made, where the days' own check
  /// would run before they have a group to read the switch from. Only the
  /// days' validity changes, so a move of the switch is still one value
  /// change.
  static Map<String, dynamic>? _checkAuditDays(
    AbstractControl<dynamic> group,
  ) {
    if (group is! FormGroup) return null;
    final days = group.control(_auditDays);
    if (group.control(_audit).value == true && dayCount(days.value) == null) {
      days.setErrors({DayCountErrors.days: true}, markAsDirty: false);
    } else {
      days.removeError(DayCountErrors.days);
    }
    return null;
  }

  // Not disabled while the switch is off: a disabled control drops out of
  // the form's value, by which the echo of new values is told apart.
  static FormGroup _buildForm(Map<String, Object?> values) => FormGroup(
    {
      _feedbackDays: FormControl<String>(
        value: values[_feedbackDays] as String?,
        validators: [Validators.delegate(validDayCount)],
      ),
      _redaction: FormControl<bool>(value: values[_redaction] as bool?),
      _audit: FormControl<bool>(value: values[_audit] as bool?),
      _auditDays: FormControl<String>(value: values[_auditDays] as String?),
    },
    validators: [Validators.delegate(_checkAuditDays)],
  );

  static Map<String, Object?> _valuesOf(SystemSettings settings) => {
    _feedbackDays: '${settings.feedbackReportRetentionDays}',
    _redaction: settings.feedbackReportServerRedactionEnabled,
    _audit: settings.auditLogRetentionDays != null,
    _auditDays: '${settings.auditLogRetentionDays ?? ''}',
  };

  static SystemSettingsPatch _patchOf(SystemSettings base, FormGroup form) {
    final feedbackDays = dayCount(form.control(_feedbackDays).value)!;
    final redaction = form.control(_redaction).value == true;
    return SystemSettingsPatch(
      feedbackReportRetentionDays:
          feedbackDays == base.feedbackReportRetentionDays
          ? null
          : feedbackDays,
      feedbackReportServerRedactionEnabled:
          redaction == base.feedbackReportServerRedactionEnabled
          ? null
          : redaction,
      auditLogRetentionDays: _auditPatch(base.auditLogRetentionDays, form),
    );
  }

  /// Off clears a stored count; on sets the count typed, unless it is the
  /// stored one.
  static SettingValue<int>? _auditPatch(int? stored, FormGroup form) {
    if (form.control(_audit).value != true) {
      return stored == null ? null : const SettingValue.clear();
    }
    final days = dayCount(form.control(_auditDays).value)!;
    return days == stored ? null : SettingValue.set(days);
  }

  /// The audit days while they show; the audit switch otherwise.
  static String _lastField(FormGroup form) =>
      form.control(_audit).value == true ? _auditDays : _audit;

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
        saveLabel: l10n.retentionSave,
        savingLabel: l10n.retentionSaving,
        savedKey: savedKey,
        savedMessage: l10n.retentionSaved,
        failureKey: failureKey,
        failureTitle: l10n.retentionNotSavedTitle,
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
        // Enter doesn't save from here: the switches follow it. Only the
        // audit days, the last field while they show, save on Enter.
        DayCountField(
          fieldKey: feedbackDaysFieldKey,
          formControlName: _feedbackDays,
          label: l10n.retentionFeedbackDaysLabel,
          helper: l10n.retentionFeedbackDaysHelper(
            SystemSettingsRemoteDataSource.minDays,
            SystemSettingsRemoteDataSource.maxDays,
          ),
          readOnly: readOnly,
        ),
        const BgeGap.md(),
        BgeSwitchField(
          formControlName: _redaction,
          label: l10n.retentionRedactionLabel,
          readOnly: readOnly,
          switchKey: redactionSwitchKey,
        ),
        ReactiveValueListenableBuilder<bool>(
          formControlName: _redaction,
          builder: (context, control, _) => control.value == true
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const BgeGap.sm(),
                    BgeInlineBanner(
                      key: redactionWarningKey,
                      tone: BgeBannerTone.warning,
                      message: l10n.retentionRedactionOffWarning,
                      // It answers the user's own toggle, beside the switch
                      // they are on, or stands as the saved state: heard,
                      // with nothing to scroll to.
                      reveal: false,
                    ),
                    const BgeGap.sm(),
                  ],
                ),
        ),
        BgeSwitchField(
          formControlName: _audit,
          label: l10n.retentionAuditLabel,
          subtitle: l10n.retentionAuditSubtitle,
          readOnly: readOnly,
          switchKey: auditSwitchKey,
        ),
        ReactiveValueListenableBuilder<bool>(
          formControlName: _audit,
          builder: (context, control, _) => control.value == true
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const BgeGap.md(),
                    DayCountField(
                      fieldKey: auditDaysFieldKey,
                      formControlName: _auditDays,
                      label: l10n.retentionAuditDaysLabel,
                      readOnly: readOnly,
                      onSubmitted: binding.maySave ? submit : null,
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
