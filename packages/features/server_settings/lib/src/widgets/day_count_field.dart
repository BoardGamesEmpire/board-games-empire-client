import 'package:flutter/material.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/whole_number.dart';
import 'package:ui/ui.dart';

/// The errors a [DayCountField]'s check sets (#894).
abstract final class DayCountErrors {
  /// On a number of days that isn't a whole number in the server's range.
  static const days = 'days';
}

/// A control's value as a number of days in the server's range, or null.
int? dayCount(Object? value) => wholeNumberIn(
  value,
  min: SystemSettingsRemoteDataSource.minDays,
  max: SystemSettingsRemoteDataSource.maxDays,
);

Map<String, dynamic>? validDayCount(AbstractControl<dynamic> control) =>
    dayCount(control.value) == null
    ? <String, dynamic>{DayCountErrors.days: true}
    : null;

/// A text field for a number of days, checked by [validDayCount]: the
/// control it names holds the text typed. The limits show as its helper
/// unless [helper] says otherwise.
class DayCountField extends StatelessWidget {
  const DayCountField({
    required this.fieldKey,
    required this.formControlName,
    required this.label,
    required this.readOnly,
    this.helper,
    this.onSubmitted,
    super.key,
  });

  /// The key of the text field.
  final Key fieldKey;
  final String formControlName;
  final String label;
  final bool readOnly;

  /// Under the field; the limits when null.
  final String? helper;

  /// Called on the keyboard's done action.
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final l10n = ServerSettingsLocalizations.of(context);
    const min = SystemSettingsRemoteDataSource.minDays;
    const max = SystemSettingsRemoteDataSource.maxDays;

    return BgeTextField(
      key: fieldKey,
      formControlName: formControlName,
      label: label,
      helper: helper ?? l10n.settingsDaysHelper(min, max),
      keyboardType: TextInputType.number,
      autocorrect: false,
      enableSuggestions: false,
      readOnly: readOnly,
      textInputAction: TextInputAction.done,
      onSubmitted: onSubmitted,
      validationMessages: {
        DayCountErrors.days: (_) => l10n.settingsDaysInvalid(min, max),
      },
    );
  }
}
