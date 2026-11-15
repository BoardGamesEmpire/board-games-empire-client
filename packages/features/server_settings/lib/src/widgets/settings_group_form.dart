import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/src/widgets/settings_group_actions.dart';
import 'package:server_settings/src/widgets/settings_group_binding.dart';
import 'package:server_settings/src/widgets/settings_seed.dart';
import 'package:ui/ui.dart';

/// The words and keys of a group's [SettingsGroupActions].
final class SettingsGroupLabels {
  const SettingsGroupLabels({
    required this.saveKey,
    required this.saveLabel,
    required this.savingLabel,
    required this.savedKey,
    required this.savedMessage,
    required this.failureKey,
    required this.failureTitle,
  });

  final Key saveKey;
  final String saveLabel;
  final String savingLabel;
  final Key savedKey;
  final String savedMessage;
  final Key failureKey;
  final String failureTitle;
}

/// The form of a settings group that is saved on its own (#807, #894). The
/// group gives its controls ([buildForm]), their values ([valuesOf]), its
/// patch ([patchOf]) and its fields ([fields]); the form keeps the rest the
/// same for every group.
///
/// Owns the [FormGroup], and hands the [binding]'s `onSave` the patch of
/// what changed. Every edit calls its `onEdited`.
///
/// ## New values from the server
///
/// The binding's `revision` moves whenever the server's settings were read
/// or a save of any group landed. The form takes the new values when its own
/// save just landed (`saved`), or when it holds no unsaved changes, so
/// another group's save never discards the user's edits here. Taking them is
/// not an edit.
///
/// A form holds unsaved changes when it is invalid, or when its patch isn't
/// empty. An invalid form has changed: the server's values pass this app's
/// checks, and one that doesn't, such as a count from a server with a wider
/// range, is kept and shown as the field's error on Save.
///
/// ## Access
///
/// When `maySave` is false the fields are read-only and there is no Save,
/// and the form puts back the values the server holds. Save with keyboard
/// focus hands it to the field just before it ([lastField]). While `saving`
/// the fields are read-only; the save button's label and spinner say why.
/// While `otherGroupSaving` Save is disabled, with the reason as its hint.
class SettingsGroupForm extends StatefulWidget {
  const SettingsGroupForm({
    required this.binding,
    required this.buildForm,
    required this.valuesOf,
    required this.patchOf,
    required this.lastField,
    required this.labels,
    required this.fields,
    super.key,
  });

  /// The settings, where the group's save stands, and where its saves and
  /// edits go.
  final SettingsGroupBinding binding;

  /// Makes the group's controls, holding `values`, which come from
  /// [valuesOf]. Called once; the form disposes of what it makes.
  final FormGroup Function(Map<String, Object?> values) buildForm;

  /// The values of the group's controls for `settings`, by control name.
  ///
  /// The form takes them again whenever it takes new settings, and tells
  /// their echo from an edit by comparing them with the form's value, so
  /// every control is named, and none is disabled: a disabled control drops
  /// out of the form's value.
  final Map<String, Object?> Function(SystemSettings settings) valuesOf;

  /// What `form` changes against `base`, the settings the form last took,
  /// with each value equal to the stored one left out.
  ///
  /// Asked only of a valid form. Made against `base`, not the binding's
  /// `settings`: while the form keeps unsaved edits out of newer values, the
  /// fields left alone still show the values it took, and comparing them
  /// with the newer ones would send them back over a change made elsewhere.
  final SystemSettingsPatch Function(SystemSettings base, FormGroup form)
  patchOf;

  /// The name of the control in `form`, the group [buildForm] made, that
  /// focus goes to when Save leaves with it: the group's last field.
  ///
  /// Asked after the frame that takes Save away, which has built the fields
  /// for the values just put back, so the answer may turn on `form`'s
  /// values. The control's field must register a reactive_forms
  /// `FocusController`, as `BgeTextField` and `BgeDropdownField` do;
  /// `BgeSwitchField` registers none, so focus would be lost with it.
  final String Function(FormGroup form) lastField;

  /// The words and keys of the group's Save and of what its save came to.
  final SettingsGroupLabels labels;

  /// Builds the group's fields, above its Save.
  ///
  /// `readOnly` while the group saves or the role may not save. `submit` is
  /// the form's own, for a field that submits, such as with Enter: it holds
  /// to the rule Save does.
  final Widget Function(
    BuildContext context, {
    required bool readOnly,
    required VoidCallback submit,
  })
  fields;

  @override
  State<SettingsGroupForm> createState() => _SettingsGroupFormState();
}

class _SettingsGroupFormState extends State<SettingsGroupForm> {
  /// The values the form last took from the server.
  late final SettingsSeed<Map<String, Object?>> _seed;

  /// The settings the form last took, which its edits are made against: see
  /// [SettingsGroupForm.patchOf].
  late SystemSettings _base;

  late final FormGroup _form;
  StreamSubscription<Object?>? _edits;

  /// Around Save, which goes when the binding's `maySave` falls; the handle
  /// on its focus. It can't take focus itself.
  final FocusNode _actions = FocusNode(
    debugLabel: 'settings group actions',
    canRequestFocus: false,
  );

  @override
  void initState() {
    super.initState();
    _base = widget.binding.settings;
    _seed = SettingsSeed(widget.valuesOf(_base), equals: mapEquals);
    _form = widget.buildForm(_seed.values);
    _edits = _form.valueChanges.listen(_onValueChanged);
  }

  void _onValueChanged(Object? _) {
    if (!mounted || _seed.isEcho(_form.value)) return;
    widget.binding.onEdited();
  }

  @override
  void didUpdateWidget(SettingsGroupForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (SettingsSeed.takes(
      revision: widget.binding.revision,
      previousRevision: oldWidget.binding.revision,
      saved: widget.binding.saved,
      unsaved: _unsaved,
    )) {
      _takeSettings();
    }
    if (oldWidget.binding.maySave && !widget.binding.maySave) {
      // A role that may not save sees what the server holds, not edits it
      // can no longer send. Taken first, so focus goes to what is left.
      _takeSettings();
      _handOnFocus();
    }
  }

  /// Whether the form holds anything the settings it last took don't. Only a
  /// valid form makes a patch.
  bool get _unsaved => !_form.valid || !widget.patchOf(_base, _form).isEmpty;

  void _takeSettings() {
    final settings = _base = widget.binding.settings;
    _seed.take(widget.valuesOf(settings));
    _form.reset(value: _seed.values);
  }

  @override
  void dispose() {
    unawaited(_edits?.cancel());
    _form.dispose();
    _actions.dispose();
    super.dispose();
  }

  /// Hands keyboard focus from Save, which this build takes away with the
  /// binding's `maySave`, to [SettingsGroupForm.lastField].
  ///
  /// Runs while building the frame that takes Save away, while it still has
  /// focus.
  void _handOnFocus() {
    if (!_actions.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (_form.control(widget.lastField(_form)) as FormControl<Object?>)
          .focusController
          ?.focusNode
          .requestFocus();
    });
  }

  void _submit() {
    final binding = widget.binding;
    // Returning before the validity check keeps an offline press from
    // marking the form touched.
    if (!settingsGroupMaySave(
      context,
      maySave: binding.maySave,
      saving: binding.saving,
      otherGroupSaving: binding.otherGroupSaving,
    )) {
      return;
    }
    if (!_form.valid) {
      _form.rejectSubmit();
      return;
    }
    binding.onSave(widget.patchOf(_base, _form));
  }

  @override
  Widget build(BuildContext context) {
    final binding = widget.binding;
    final labels = widget.labels;

    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          widget.fields(
            context,
            readOnly: binding.saving || !binding.maySave,
            submit: _submit,
          ),
          SettingsGroupActions(
            maySave: binding.maySave,
            saving: binding.saving,
            otherGroupSaving: binding.otherGroupSaving,
            saved: binding.saved,
            failure: binding.failure,
            focusNode: _actions,
            onSave: _submit,
            saveKey: labels.saveKey,
            saveLabel: labels.saveLabel,
            savingLabel: labels.savingLabel,
            savedKey: labels.savedKey,
            savedMessage: labels.savedMessage,
            failureKey: labels.failureKey,
            failureTitle: labels.failureTitle,
          ),
        ],
      ),
    );
  }
}
