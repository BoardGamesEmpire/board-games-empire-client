import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/widgets/settings_group_binding.dart';
import 'package:server_settings/src/widgets/settings_group_form.dart';
import 'package:ui/ui.dart';

/// The General group of the server settings (#894): the name of the server.
///
/// A [SettingsGroupForm], which says how it takes new values from the server
/// and what a role that may not save sees. The patch [binding] gets is what
/// changed, against the settings the form last took: the name, trimmed as the
/// server trims it, only when it differs.
class GeneralSettingsForm extends StatelessWidget {
  const GeneralSettingsForm({
    required this.binding,
    super.key,
  });

  static const Key nameFieldKey = Key('general_settings_form.name');
  static const Key saveKey = Key('general_settings_form.save');
  static const Key savedKey = Key('general_settings_form.saved');
  static const Key failureKey = Key('general_settings_form.failure');

  static const String _name = 'name';
  static const String _empty = 'empty';
  static const String _tooLong = 'tooLong';

  final SettingsGroupBinding binding;

  static FormGroup _buildForm(Map<String, Object?> values) => FormGroup({
    _name: FormControl<String>(
      value: values[_name] as String?,
      validators: [Validators.delegate(_validName)],
    ),
  });

  /// The stored name as the server would store it now, trimmed: one stored
  /// with padding, as a server before it trimmed names could, isn't an edit.
  static String _storedName(SystemSettings settings) => settings.name.trim();

  static Map<String, Object?> _valuesOf(SystemSettings settings) => {
    _name: _storedName(settings),
  };

  /// Not blank, and no longer than the server takes, once trimmed as the
  /// server trims it.
  static Map<String, dynamic>? _validName(AbstractControl<dynamic> control) {
    final value = control.value;
    final text = value is String ? value.trim() : '';
    if (text.isEmpty) return <String, dynamic>{_empty: true};
    return serverStringLength(text) >
            SystemSettingsRemoteDataSource.maxNameLength
        ? <String, dynamic>{_tooLong: true}
        : null;
  }

  static SystemSettingsPatch _patchOf(SystemSettings base, FormGroup form) {
    final value = form.control(_name).value;
    final name = value is String ? value.trim() : '';
    return SystemSettingsPatch(
      name: name == _storedName(base) ? null : name,
    );
  }

  static String _lastField(FormGroup _) => _name;

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
        saveLabel: l10n.generalSave,
        savingLabel: l10n.generalSaving,
        savedKey: savedKey,
        savedMessage: l10n.generalSaved,
        failureKey: failureKey,
        failureTitle: l10n.generalNotSavedTitle,
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

    return BgeTextField(
      key: nameFieldKey,
      formControlName: _name,
      label: l10n.generalNameLabel,
      helper: l10n.generalNameHelper,
      // A server name is not prose; autocorrect would rewrite it.
      autocorrect: false,
      readOnly: readOnly,
      textInputAction: TextInputAction.done,
      onSubmitted: binding.maySave ? submit : null,
      validationMessages: {
        _empty: (_) => l10n.generalNameEmpty,
        _tooLong: (_) => l10n.generalNameTooLong(
          SystemSettingsRemoteDataSource.maxNameLength,
        ),
      },
    );
  }
}
