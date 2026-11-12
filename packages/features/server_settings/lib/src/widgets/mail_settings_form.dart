import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/bloc/server_settings_state.dart';
import 'package:server_settings/src/mail/link_lifetime.dart';
import 'package:server_settings/src/mail/mail_controls.dart';
import 'package:server_settings/src/mail/mail_patch.dart';
import 'package:server_settings/src/widgets/mail_password_section.dart';
import 'package:server_settings/src/widgets/settings_group_actions.dart';
import 'package:server_settings/src/widgets/settings_seed.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The Mail group of the server settings (#807): the SMTP connection, the
/// From address, the password reset switch and the reset link lifetime.
///
/// Owns its [FormGroup], like `DataGatewayForm`, and hands [onSave] the
/// patch of what changed, against [settings] as the server last sent it.
/// Every edit calls [onEdited], so the caller can retire an outcome that
/// describes the values being replaced.
///
/// ## The saved password
///
/// The server never returns it. With one saved the form says so and offers
/// Change and Remove; Change opens a field for a new one, with Keep saved
/// password and Remove beside it, and Remove marks the password to be
/// cleared by the save. A change of host, port or security that would keep
/// it is refused by the server, so that the password never goes to a server
/// it wasn't saved for: the form asks for the password before sending such a
/// save, on the password field, and puts the server's own refusal there too.
///
/// ## New values from the server
///
/// [revision] moves whenever the server's settings were read or a save of
/// either group landed. The form takes the new values when its own save just
/// landed ([saved]), or when it holds no unsaved changes, so another group's
/// save never discards the user's edits here. Taking them is not an edit.
///
/// ## Access
///
/// When [maySave] is false the fields are read-only, and there is no Save,
/// no password buttons and no test panel. A control with keyboard focus that
/// goes with them hands it to the field just before it. While [saving] the
/// fields are read-only and the password buttons disabled; the save button's
/// label and spinner say why. While [otherGroupSaving] Save is disabled,
/// with the reason as its hint.
class MailSettingsForm extends StatefulWidget {
  const MailSettingsForm({
    required this.settings,
    required this.revision,
    required this.maySave,
    required this.saving,
    required this.otherGroupSaving,
    required this.onSave,
    required this.onEdited,
    this.failure,
    this.saved = false,
    this.testPanelBuilder,
    super.key,
  });

  static const Key hostFieldKey = Key('mail_settings_form.host');
  static const Key portFieldKey = Key('mail_settings_form.port');
  static const Key securityFieldKey = Key('mail_settings_form.security');
  static const Key userFieldKey = Key('mail_settings_form.user');
  static const Key passwordFieldKey = MailPasswordSection.fieldKey;
  static const Key changePasswordKey = MailPasswordSection.changeKey;
  static const Key removePasswordKey = MailPasswordSection.removeKey;
  static const Key keepPasswordKey = MailPasswordSection.keepKey;
  static const Key keepSavedPasswordKey = MailPasswordSection.keepSavedKey;
  static const Key fromFieldKey = Key('mail_settings_form.from');
  static const Key passwordResetsSwitchKey = Key(
    'mail_settings_form.password_resets',
  );
  static const Key lifetimeFieldKey = Key('mail_settings_form.lifetime');
  static const Key saveKey = Key('mail_settings_form.save');
  static const Key savedKey = Key('mail_settings_form.saved');
  static const Key failureKey = Key('mail_settings_form.failure');

  /// The settings as the server last sent them.
  final SystemSettings settings;

  /// Moves when [settings] were read again or a save landed.
  final int revision;

  /// Whether the caller may change the settings.
  final bool maySave;

  /// Whether this group's save is in flight.
  final bool saving;

  /// Whether the other group's save is in flight. One save at a time.
  final bool otherGroupSaving;

  /// Why this group's last save didn't land, until the group is edited.
  final SettingsSaveFailure? failure;

  /// Whether this group's last save landed, until the group is edited.
  final bool saved;

  final void Function(SystemSettingsPatch patch) onSave;

  /// Called on every edit by the user.
  final VoidCallback onEdited;

  /// Builds the test email panel under Save, told whether the group has
  /// unsaved changes. The screen supplies it, so the form knows no bloc.
  final Widget Function(
    BuildContext context, {
    required bool hasUnsavedChanges,
  })?
  testPanelBuilder;

  @override
  State<MailSettingsForm> createState() => _MailSettingsFormState();
}

class _MailSettingsFormState extends State<MailSettingsForm> {
  late PasswordEdit _passwordEdit;

  /// The values the form last took from the server.
  late final SettingsSeed<Map<String, Object?>?> _seed;

  /// The settings the form last took, which its edits are made against.
  ///
  /// A save, and what counts as unsaved, compare the form with these, not
  /// with [MailSettingsForm.settings]: while the form keeps unsaved edits
  /// out of newer values, the fields left alone still show these, and
  /// comparing them with the newer ones would send them back over a change
  /// made elsewhere.
  late SystemSettings _base;

  late final FormGroup _form;
  late bool _hasUnsavedChanges;
  StreamSubscription<Object?>? _edits;

  /// Around Save and the test panel, which go when [MailSettingsForm.maySave]
  /// falls; the handle on their focus. It can't take focus itself.
  final FocusNode _actions = FocusNode(
    debugLabel: 'mail settings actions',
    canRequestFocus: false,
  );

  final MailPasswordFocus _passwordFocus = MailPasswordFocus();

  static PasswordEdit _initialPasswordEdit(SystemSettings settings) =>
      settings.smtpPasswordSet ? PasswordEdit.keep : PasswordEdit.replace;

  static Map<String, Object?> _valuesOf(SystemSettings settings) => {
    MailControls.host: settings.smtpHost ?? '',
    MailControls.port: '${settings.smtpPort}',
    // A value this app doesn't know shows as the field's hint, and a save
    // leaves it alone unless another is picked.
    MailControls.security: settings.smtpSecurity == SmtpSecurity.unknown
        ? null
        : settings.smtpSecurity,
    MailControls.user: settings.smtpUser ?? '',
    MailControls.password: '',
    MailControls.from: settings.mailFromAddress ?? '',
    MailControls.allowPasswordResets: settings.allowPasswordResets,
    MailControls.lifetime: '${settings.passwordResetLinkLifetimeMinutes}',
  };

  /// The password's check reads the edit and the saved password as they
  /// are when it runs.
  Map<String, dynamic>? _validPassword(AbstractControl<dynamic> control) =>
      checkMailPassword(
        control.value,
        edit: _passwordEdit,
        passwordSaved: widget.settings.smtpPasswordSet,
      );

  @override
  void initState() {
    super.initState();
    _base = widget.settings;
    _passwordEdit = _initialPasswordEdit(_base);
    final seed = _valuesOf(_base);
    _seed = SettingsSeed(seed, equals: mapEquals);
    FormControl<T> control<T>(
      String name, [
      List<ValidatorFunction> checks = const [],
    ]) => FormControl<T>(
      value: seed[name] as T?,
      validators: [for (final check in checks) Validators.delegate(check)],
    );
    _form = FormGroup({
      MailControls.host: control<String>(MailControls.host, [mailWithinLength]),
      MailControls.port: control<String>(MailControls.port, [validMailPort]),
      MailControls.security: control<SmtpSecurity>(MailControls.security),
      MailControls.user: control<String>(MailControls.user, [mailWithinLength]),
      MailControls.password: control<String>(MailControls.password, [
        _validPassword,
      ]),
      MailControls.from: control<String>(MailControls.from, [
        mailWithinLength,
        validMailFrom,
      ]),
      MailControls.allowPasswordResets: control<bool>(
        MailControls.allowPasswordResets,
      ),
      MailControls.lifetime: control<String>(MailControls.lifetime, [
        validMailLinkLifetime,
      ]),
    });
    _hasUnsavedChanges = _unsavedAgainst(_base);
    _edits = _form.valueChanges.listen(_onValueChanged);
  }

  void _onValueChanged(Map<String, Object?>? value) {
    if (!mounted) return;
    _refreshUnsaved();
    if (_seed.isEcho(value)) return;
    widget.onEdited();
  }

  @override
  void didUpdateWidget(MailSettingsForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (SettingsSeed.takes(
      revision: widget.revision,
      previousRevision: oldWidget.revision,
      saved: widget.saved,
      unsaved: _unsavedAgainst(_base),
    )) {
      _takeSettings();
    }
    if (widget.failure == SettingsSaveFailure.passwordRequired &&
        oldWidget.failure != SettingsSaveFailure.passwordRequired) {
      _askForPassword();
    }
    if (oldWidget.maySave && !widget.maySave) {
      // A role that may not save sees what the server holds, not edits it
      // can no longer send. Taken first, so focus goes to what is left.
      _takeSettings();
      _handOnFocus();
    }
    _hasUnsavedChanges = _unsavedAgainst(_base);
  }

  /// Takes the values of [MailSettingsForm.settings], and the password back
  /// to its starting state.
  void _takeSettings() {
    final settings = _base = widget.settings;
    _passwordEdit = _initialPasswordEdit(settings);
    _seed.take(_valuesOf(settings));
    _form.reset(value: _seed.values);
  }

  @override
  void dispose() {
    unawaited(_edits?.cancel());
    _form.dispose();
    _actions.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  String _text(String name) => _form.control(name).value as String? ?? '';

  /// The form's values, with the numbers given: built only from numbers
  /// that parsed.
  MailFormValues _values({required int port, required int lifetime}) =>
      MailFormValues(
        host: _text(MailControls.host),
        port: port,
        security: _form.control(MailControls.security).value as SmtpSecurity?,
        user: _text(MailControls.user),
        password: _text(MailControls.password),
        passwordEdit: _passwordEdit,
        from: _text(MailControls.from),
        allowPasswordResets:
            _form.control(MailControls.allowPasswordResets).value == true,
        linkLifetimeMinutes: lifetime,
      );

  /// Whether the form holds anything [settings] don't: a number that doesn't
  /// parse counts, as one that differs does.
  bool _unsavedAgainst(SystemSettings settings) {
    final port = mailWholeNumber(_form.control(MailControls.port).value);
    final lifetime = mailWholeNumber(
      _form.control(MailControls.lifetime).value,
    );
    if (port == null || lifetime == null) return true;
    return _passwordEdit != _initialPasswordEdit(settings) ||
        !mailPatch(settings, _values(port: port, lifetime: lifetime)).isEmpty;
  }

  void _refreshUnsaved() {
    final unsaved = _unsavedAgainst(_base);
    if (unsaved != _hasUnsavedChanges) {
      setState(() => _hasUnsavedChanges = unsaved);
    }
  }

  void _focusField(String name) => (_form.control(name) as FormControl<Object?>)
      .focusController
      ?.focusNode
      .requestFocus();

  /// Hands keyboard focus from a control this build takes away with
  /// [MailSettingsForm.maySave] to the field just before it, as
  /// `DataGatewayForm` does: Save and the test panel to the lifetime, the
  /// last field, and a password button to the password field, or with none
  /// shown, to the user name.
  ///
  /// Runs while building the frame that takes the controls away, while they
  /// still have focus.
  void _handOnFocus() {
    final String to;
    if (_actions.hasFocus) {
      to = MailControls.lifetime;
    } else if (_passwordFocus.actions.hasFocus) {
      to = _passwordEdit == PasswordEdit.replace
          ? MailControls.password
          : MailControls.user;
    } else {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusField(to);
    });
  }

  void _submit() {
    // Returning before the validity check keeps an offline press from
    // marking the form touched.
    if (!settingsGroupMaySave(
      context,
      maySave: widget.maySave,
      saving: widget.saving,
      otherGroupSaving: widget.otherGroupSaving,
    )) {
      return;
    }
    if (!_form.valid) {
      _form.rejectSubmit();
      return;
    }
    final port = mailWholeNumber(_form.control(MailControls.port).value)!;
    final lifetime = mailWholeNumber(
      _form.control(MailControls.lifetime).value,
    )!;
    final patch = mailPatch(_base, _values(port: port, lifetime: lifetime));
    // Against the server's current settings: the rule is the server's, on
    // what it holds now.
    if (mailPasswordNeeded(widget.settings, patch)) {
      setState(_askForPassword);
      _refreshUnsaved();
      return;
    }
    widget.onSave(patch);
  }

  /// Opens the password field with the reason the server gives on it, and
  /// puts the user there: the change would keep a saved password for a new
  /// server.
  ///
  /// The field is built by the next frame, so the error and the focus wait
  /// for it: `rejectSubmit` passes over a control with no field.
  void _askForPassword() {
    _passwordEdit = PasswordEdit.replace;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _form.control(MailControls.password)
        ..setErrors({MailErrors.passwordRequired: true})
        ..markAsTouched();
      _form.rejectSubmit();
    });
  }

  /// Moves the password to [edit] at the user's press of a button that this
  /// build takes away.
  ///
  /// Focus goes to the control in the pressed button's place, after the
  /// frame that replaces it: Change to the new field, Remove to Keep
  /// password, either Keep to Change password. Always, not only when the
  /// button had focus: a tap, a click and a screen reader's double tap move
  /// no focus, and the user's place would go with the button. A control
  /// removed with focus leaves none, and a request made after that frame
  /// wins over the fallback. A pointer's press hides the focus ring until
  /// the next key press, so a tap draws none.
  void _editPassword(PasswordEdit edit) {
    setState(() => _passwordEdit = edit);
    // What was typed goes with the field it was typed in, and the field's
    // check depends on the state.
    _form.control(MailControls.password)
      ..reset(value: '')
      ..updateValueAndValidity();
    _refreshUnsaved();
    widget.onEdited();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (edit) {
        case PasswordEdit.replace:
          _focusField(MailControls.password);
        case PasswordEdit.remove:
          _passwordFocus.keep.requestFocus();
        case PasswordEdit.keep:
          _passwordFocus.change.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ServerSettingsLocalizations.of(context);
    final readOnly = widget.saving || !widget.maySave;
    final testPanel = widget.testPanelBuilder;
    String tooLong(Object _) => mailTooLongMessage(l10n);

    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.mailGroupIntro),
          const BgeGap.md(),
          BgeTextField(
            key: MailSettingsForm.hostFieldKey,
            formControlName: MailControls.host,
            label: l10n.mailHostLabel,
            helper: l10n.mailHostHelper,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: readOnly,
            validationMessages: {MailErrors.tooLong: tooLong},
          ),
          const BgeGap.md(),
          BgeTextField(
            key: MailSettingsForm.portFieldKey,
            formControlName: MailControls.port,
            label: l10n.mailPortLabel,
            keyboardType: TextInputType.number,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: readOnly,
            validationMessages: {
              MailErrors.port: (_) => l10n.mailPortInvalid,
            },
          ),
          const BgeGap.md(),
          BgeDropdownField<SmtpSecurity>(
            key: MailSettingsForm.securityFieldKey,
            formControlName: MailControls.security,
            label: l10n.mailSecurityLabel,
            hint: l10n.mailSecurityUnknown,
            readOnly: readOnly,
            items: [
              BgeDropdownItem(
                value: SmtpSecurity.startTls,
                label: l10n.mailSecurityStartTls,
              ),
              BgeDropdownItem(
                value: SmtpSecurity.implicitTls,
                label: l10n.mailSecurityImplicitTls,
              ),
              BgeDropdownItem(
                value: SmtpSecurity.none,
                label: l10n.mailSecurityNone,
              ),
            ],
          ),
          ReactiveValueListenableBuilder<SmtpSecurity>(
            formControlName: MailControls.security,
            builder: (context, control, _) => control.value == SmtpSecurity.none
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const BgeGap.sm(),
                      BgeInlineBanner(
                        tone: BgeBannerTone.warning,
                        message: l10n.mailSecurityNoneWarning,
                        // It answers the user's own pick, beside the field
                        // they are on: heard, with nothing to scroll to.
                        reveal: false,
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          const BgeGap.md(),
          BgeTextField(
            key: MailSettingsForm.userFieldKey,
            formControlName: MailControls.user,
            label: l10n.mailUserLabel,
            helper: l10n.mailUserHelper,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: readOnly,
            validationMessages: {MailErrors.tooLong: tooLong},
          ),
          const BgeGap.md(),
          MailPasswordSection(
            edit: _passwordEdit,
            passwordSaved: widget.settings.smtpPasswordSet,
            maySave: widget.maySave,
            readOnly: readOnly,
            buttonsEnabled: !widget.saving,
            focus: _passwordFocus,
            onEdit: _editPassword,
          ),
          const BgeGap.md(),
          BgeTextField(
            key: MailSettingsForm.fromFieldKey,
            formControlName: MailControls.from,
            label: l10n.mailFromLabel,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: readOnly,
            validationMessages: {
              MailErrors.tooLong: tooLong,
              ValidationMessage.email: (_) => l10n.mailFromInvalid,
            },
          ),
          const BgeGap.md(),
          BgeSwitchField(
            formControlName: MailControls.allowPasswordResets,
            label: l10n.mailPasswordResetsLabel,
            readOnly: readOnly,
            switchKey: MailSettingsForm.passwordResetsSwitchKey,
          ),
          const BgeGap.md(),
          ReactiveValueListenableBuilder<String>(
            formControlName: MailControls.lifetime,
            builder: (context, control, _) {
              final minutes = mailLinkLifetime(control.value);
              final min = describeLinkLifetime(
                SystemSettingsRemoteDataSource.minLinkLifetimeMinutes,
                l10n,
              );
              final max = describeLinkLifetime(
                SystemSettingsRemoteDataSource.maxLinkLifetimeMinutes,
                l10n,
              );
              return BgeTextField(
                key: MailSettingsForm.lifetimeFieldKey,
                formControlName: MailControls.lifetime,
                label: l10n.mailLinkLifetimeLabel,
                // The limits always show (#807), so the line doesn't come
                // and go as the value is typed.
                helper: minutes == null
                    ? l10n.mailLinkLifetimeRange(min, max)
                    : l10n.mailLinkLifetimeHelper(
                        describeLinkLifetime(minutes, l10n),
                        min,
                        max,
                      ),
                keyboardType: TextInputType.number,
                autocorrect: false,
                enableSuggestions: false,
                readOnly: readOnly,
                textInputAction: TextInputAction.done,
                onSubmitted: widget.maySave ? _submit : null,
                validationMessages: {
                  MailErrors.lifetime: (_) => l10n.mailLinkLifetimeInvalid(
                    SystemSettingsRemoteDataSource.minLinkLifetimeMinutes,
                    SystemSettingsRemoteDataSource.maxLinkLifetimeMinutes,
                    max,
                  ),
                },
              );
            },
          ),
          SettingsGroupActions(
            maySave: widget.maySave,
            saving: widget.saving,
            otherGroupSaving: widget.otherGroupSaving,
            saved: widget.saved,
            // The password field carries it.
            failure: widget.failure == SettingsSaveFailure.passwordRequired
                ? null
                : widget.failure,
            focusNode: _actions,
            onSave: _submit,
            saveKey: MailSettingsForm.saveKey,
            saveLabel: l10n.mailSave,
            savingLabel: l10n.mailSaving,
            savedKey: MailSettingsForm.savedKey,
            savedMessage: l10n.mailSaved,
            failureKey: MailSettingsForm.failureKey,
            failureTitle: l10n.mailNotSavedTitle,
            trailing: widget.maySave && testPanel != null
                ? testPanel(context, hasUnsavedChanges: _hasUnsavedChanges)
                : null,
          ),
        ],
      ),
    );
  }
}
