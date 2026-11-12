import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/bloc/server_settings_state.dart';
import 'package:server_settings/src/mail/link_lifetime.dart';
import 'package:server_settings/src/mail/mail_patch.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The server's limits, as the remote states them.
typedef _Limits = SystemSettingsRemoteDataSource;

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
/// label and spinner say why. While [otherGroupSaving] Save is disabled: the
/// other group's save button says why.
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
  static const Key passwordFieldKey = Key('mail_settings_form.password');
  static const Key changePasswordKey = Key('mail_settings_form.change');
  static const Key removePasswordKey = Key('mail_settings_form.remove');
  static const Key keepPasswordKey = Key('mail_settings_form.keep');
  static const Key keepSavedPasswordKey = Key('mail_settings_form.keep_saved');
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
  static const String _portError = 'port';
  static const String _lifetimeError = 'lifetime';
  static const String _tooLongError = 'tooLong';
  static const String _emptyPasswordError = 'emptyPassword';
  static const String _passwordRequiredError = 'passwordRequired';

  /// Digits only. `int.tryParse` alone also takes a sign and a `0x` prefix,
  /// so "0x50" would pass and save port 80.
  static final RegExp _digits = RegExp(r'^[0-9]+$');

  late PasswordEdit _passwordEdit;

  /// The values the form last took from the server.
  late Map<String, Object?> _seed;

  /// The settings the form last took, which its edits are made against.
  ///
  /// A save, and what counts as unsaved, compare the form with these, not
  /// with [MailSettingsForm.settings]: while the form keeps unsaved edits
  /// out of newer values, the fields left alone still show these, and
  /// comparing them with the newer ones would send them back over a change
  /// made elsewhere.
  late SystemSettings _base;

  /// Whether the form's value changes may still be the echo of taking
  /// [_seed]. reactive_forms delivers them asynchronously, after the reset
  /// that caused them, so they are told apart by their value: a change to
  /// anything else is the user's, and ends the echo.
  bool _echoingSeed = false;

  late final FormGroup _form;
  late bool _hasUnsavedChanges;
  StreamSubscription<Object?>? _edits;

  /// Around Save and the test panel, which go when [MailSettingsForm.maySave]
  /// falls; the handle on their focus. It can't take focus itself.
  final FocusNode _actions = FocusNode(
    debugLabel: 'mail settings actions',
    canRequestFocus: false,
  );

  /// The same, around the password buttons.
  final FocusNode _passwordActions = FocusNode(
    debugLabel: 'mail password actions',
    canRequestFocus: false,
  );

  final FocusNode _change = FocusNode(debugLabel: 'Change password');
  final FocusNode _remove = FocusNode(debugLabel: 'Remove password');
  final FocusNode _keep = FocusNode(debugLabel: 'Keep password');
  final FocusNode _keepSaved = FocusNode(debugLabel: 'Keep saved password');

  static PasswordEdit _initialPasswordEdit(SystemSettings settings) =>
      settings.smtpPasswordSet ? PasswordEdit.keep : PasswordEdit.replace;

  static Map<String, Object?> _valuesOf(SystemSettings settings) => {
    'host': settings.smtpHost ?? '',
    'port': '${settings.smtpPort}',
    // A value this app doesn't know shows as the field's hint, and a save
    // leaves it alone unless another is picked.
    'security': settings.smtpSecurity == SmtpSecurity.unknown
        ? null
        : settings.smtpSecurity,
    'user': settings.smtpUser ?? '',
    'password': '',
    'from': settings.mailFromAddress ?? '',
    'allowPasswordResets': settings.allowPasswordResets,
    'lifetime': '${settings.passwordResetLinkLifetimeMinutes}',
  };

  static int? _wholeNumber(Object? value) {
    final text = value is String ? value.trim() : '';
    return _digits.hasMatch(text) ? int.tryParse(text) : null;
  }

  static Map<String, dynamic>? _validPort(AbstractControl<dynamic> control) {
    final port = _wholeNumber(control.value);
    return port == null || port < _Limits.minPort || port > _Limits.maxPort
        ? <String, dynamic>{_portError: true}
        : null;
  }

  static Map<String, dynamic>? _validLifetime(
    AbstractControl<dynamic> control,
  ) => _lifetime(control.value) == null
      ? <String, dynamic>{_lifetimeError: true}
      : null;

  static int? _lifetime(Object? value) {
    final minutes = _wholeNumber(value);
    return minutes == null ||
            minutes < _Limits.minLinkLifetimeMinutes ||
            minutes > _Limits.maxLinkLifetimeMinutes
        ? null
        : minutes;
  }

  /// At most the server's length, counted as the server counts it, once
  /// trimmed as the server trims it.
  static Map<String, dynamic>? _withinLength(
    AbstractControl<dynamic> control,
  ) {
    final value = control.value;
    final text = value is String ? value.trim() : '';
    return serverStringLength(text) > _Limits.maxMailSettingLength
        ? <String, dynamic>{_tooLongError: true}
        : null;
  }

  /// An email address once trimmed, or nothing.
  static Map<String, dynamic>? _validFrom(AbstractControl<dynamic> control) {
    final value = control.value;
    final text = value is String ? value.trim() : '';
    return text.isEmpty || EmailValidator.emailRegex.hasMatch(text)
        ? null
        : <String, dynamic>{ValidationMessage.email: true};
  }

  /// Checked only while a new password is being entered. It isn't trimmed:
  /// a password may start or end with a space.
  Map<String, dynamic>? _validPassword(AbstractControl<dynamic> control) {
    if (_passwordEdit != PasswordEdit.replace) return null;
    final value = control.value;
    final text = value is String ? value : '';
    if (text.isEmpty) {
      return widget.settings.smtpPasswordSet
          ? <String, dynamic>{_emptyPasswordError: true}
          : null;
    }
    return serverStringLength(text) > _Limits.maxMailSettingLength
        ? <String, dynamic>{_tooLongError: true}
        : null;
  }

  @override
  void initState() {
    super.initState();
    _base = widget.settings;
    _passwordEdit = _initialPasswordEdit(_base);
    _seed = _valuesOf(_base);
    _form = FormGroup({
      'host': FormControl<String>(
        value: _seed['host'] as String?,
        validators: [Validators.delegate(_withinLength)],
      ),
      'port': FormControl<String>(
        value: _seed['port'] as String?,
        validators: [Validators.delegate(_validPort)],
      ),
      'security': FormControl<SmtpSecurity>(
        value: _seed['security'] as SmtpSecurity?,
      ),
      'user': FormControl<String>(
        value: _seed['user'] as String?,
        validators: [Validators.delegate(_withinLength)],
      ),
      'password': FormControl<String>(
        value: _seed['password'] as String?,
        validators: [Validators.delegate(_validPassword)],
      ),
      'from': FormControl<String>(
        value: _seed['from'] as String?,
        validators: [
          Validators.delegate(_withinLength),
          Validators.delegate(_validFrom),
        ],
      ),
      'allowPasswordResets': FormControl<bool>(
        value: _seed['allowPasswordResets'] as bool?,
      ),
      'lifetime': FormControl<String>(
        value: _seed['lifetime'] as String?,
        validators: [Validators.delegate(_validLifetime)],
      ),
    });
    _hasUnsavedChanges = _unsavedAgainst(_base);
    _edits = _form.valueChanges.listen(_onValueChanged);
  }

  void _onValueChanged(Map<String, Object?>? value) {
    if (!mounted) return;
    _refreshUnsaved();
    if (_echoingSeed && mapEquals(value, _seed)) return;
    _echoingSeed = false;
    widget.onEdited();
  }

  @override
  void didUpdateWidget(MailSettingsForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision &&
        (widget.saved || !_unsavedAgainst(_base))) {
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
    _seed = _valuesOf(settings);
    _echoingSeed = true;
    _form.reset(value: _seed);
  }

  @override
  void dispose() {
    unawaited(_edits?.cancel());
    _form.dispose();
    for (final node in [
      _actions,
      _passwordActions,
      _change,
      _remove,
      _keep,
      _keepSaved,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  String _text(String name) => _form.control(name).value as String? ?? '';

  /// The form's values, with the numbers given: built only from numbers
  /// that parsed.
  MailFormValues _values({required int port, required int lifetime}) =>
      MailFormValues(
        host: _text('host'),
        port: port,
        security: _form.control('security').value as SmtpSecurity?,
        user: _text('user'),
        password: _text('password'),
        passwordEdit: _passwordEdit,
        from: _text('from'),
        allowPasswordResets: _form.control('allowPasswordResets').value == true,
        linkLifetimeMinutes: lifetime,
      );

  /// Whether the form holds anything [settings] don't: a number that doesn't
  /// parse counts, as one that differs does.
  bool _unsavedAgainst(SystemSettings settings) {
    final port = _wholeNumber(_form.control('port').value);
    final lifetime = _wholeNumber(_form.control('lifetime').value);
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
      to = 'lifetime';
    } else if (_passwordActions.hasFocus) {
      to = _passwordEdit == PasswordEdit.replace ? 'password' : 'user';
    } else {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusField(to);
    });
  }

  void _submit() {
    // Saving is a direct write (#49). Returning before the validity check
    // keeps an offline press from marking the form touched.
    if (widget.saving ||
        widget.otherGroupSaving ||
        !widget.maySave ||
        BgeConnectivityScope.offlineOf(context)) {
      return;
    }
    if (!_form.valid) {
      _form.rejectSubmit();
      return;
    }
    final port = _wholeNumber(_form.control('port').value)!;
    final lifetime = _wholeNumber(_form.control('lifetime').value)!;
    final patch = mailPatch(_base, _values(port: port, lifetime: lifetime));
    // Against the server's current settings: the rule is the server's, on
    // what it holds now.
    if (mailPasswordNeeded(widget.settings, patch, _passwordEdit)) {
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
      _form.control('password')
        ..setErrors({_passwordRequiredError: true})
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
    _form.control('password')
      ..reset(value: '')
      ..updateValueAndValidity();
    _refreshUnsaved();
    widget.onEdited();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (edit) {
        case PasswordEdit.replace:
          _focusField('password');
        case PasswordEdit.remove:
          _keep.requestFocus();
        case PasswordEdit.keep:
          _change.requestFocus();
      }
    });
  }

  BgeFormFailure? _failure(ServerSettingsLocalizations l10n) {
    final message = switch (widget.failure) {
      // The password field carries it.
      null || SettingsSaveFailure.passwordRequired => null,
      SettingsSaveFailure.nothingChanged => l10n.settingsNothingChanged,
      SettingsSaveFailure.refused => l10n.settingsRefused,
      SettingsSaveFailure.rejected => l10n.settingsRejected,
      SettingsSaveFailure.failed => l10n.settingsFailed,
    };
    return message == null
        ? null
        : BgeFormFailure(
            key: MailSettingsForm.failureKey,
            // Some of the messages state only a cause.
            title: l10n.mailNotSavedTitle,
            message: message,
          );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ServerSettingsLocalizations.of(context);
    final readOnly = widget.saving || !widget.maySave;
    final offline = BgeConnectivityScope.offlineOf(context);
    final testPanel = widget.testPanelBuilder;
    final failure = _failure(l10n);
    String tooLong(Object _) =>
        l10n.mailFieldTooLong(_Limits.maxMailSettingLength);

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
            formControlName: 'host',
            label: l10n.mailHostLabel,
            helper: l10n.mailHostHelper,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: readOnly,
            validationMessages: {_tooLongError: tooLong},
          ),
          const BgeGap.md(),
          BgeTextField(
            key: MailSettingsForm.portFieldKey,
            formControlName: 'port',
            label: l10n.mailPortLabel,
            keyboardType: TextInputType.number,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: readOnly,
            validationMessages: {_portError: (_) => l10n.mailPortInvalid},
          ),
          const BgeGap.md(),
          BgeDropdownField<SmtpSecurity>(
            key: MailSettingsForm.securityFieldKey,
            formControlName: 'security',
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
            formControlName: 'security',
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
            formControlName: 'user',
            label: l10n.mailUserLabel,
            helper: l10n.mailUserHelper,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: readOnly,
            validationMessages: {_tooLongError: tooLong},
          ),
          const BgeGap.md(),
          _password(context, l10n, readOnly, tooLong),
          const BgeGap.md(),
          BgeTextField(
            key: MailSettingsForm.fromFieldKey,
            formControlName: 'from',
            label: l10n.mailFromLabel,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: readOnly,
            validationMessages: {
              _tooLongError: tooLong,
              ValidationMessage.email: (_) => l10n.mailFromInvalid,
            },
          ),
          const BgeGap.md(),
          BgeSwitchField(
            formControlName: 'allowPasswordResets',
            label: l10n.mailPasswordResetsLabel,
            readOnly: readOnly,
            switchKey: MailSettingsForm.passwordResetsSwitchKey,
          ),
          const BgeGap.md(),
          ReactiveValueListenableBuilder<String>(
            formControlName: 'lifetime',
            builder: (context, control, _) {
              final minutes = _lifetime(control.value);
              return BgeTextField(
                key: MailSettingsForm.lifetimeFieldKey,
                formControlName: 'lifetime',
                label: l10n.mailLinkLifetimeLabel,
                helper: minutes == null
                    ? null
                    : l10n.mailLinkLifetimeHelper(
                        describeLinkLifetime(minutes, l10n),
                      ),
                keyboardType: TextInputType.number,
                autocorrect: false,
                enableSuggestions: false,
                readOnly: readOnly,
                textInputAction: TextInputAction.done,
                onSubmitted: widget.maySave ? _submit : null,
                validationMessages: {
                  _lifetimeError: (_) => l10n.mailLinkLifetimeInvalid,
                },
              );
            },
          ),
          if (widget.saved || widget.maySave || failure != null)
            const BgeGap.lg(),
          if (widget.saved) ...[
            BgeInlineBanner(
              key: MailSettingsForm.savedKey,
              tone: BgeBannerTone.success,
              message: l10n.mailSaved,
            ),
            const BgeGap.md(),
          ],
          if (widget.maySave)
            Focus(
              focusNode: _actions,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  BgeFormActions(
                    failure: failure,
                    action: BgeOnlineOnly(
                      // One note for the group, Save and the test alike.
                      showNote: false,
                      child: BgeSubmitButton(
                        key: MailSettingsForm.saveKey,
                        label: l10n.mailSave,
                        progressLabel: l10n.mailSaving,
                        submitting: widget.saving,
                        onPressed: offline || widget.otherGroupSaving
                            ? null
                            : _submit,
                      ),
                    ),
                  ),
                  // Only offline: online it would still take its gap.
                  if (offline) ...[
                    const BgeGap.sm(),
                    const BgeOnlineOnlyNote(),
                  ],
                  if (testPanel != null) ...[
                    const BgeGap.lg(),
                    testPanel(context, hasUnsavedChanges: _hasUnsavedChanges),
                  ],
                ],
              ),
            )
          // A refused save whose access check then takes maySave away must
          // not vanish unexplained, while the form puts back the saved
          // values. As BgeFormActions draws it, without the Save it sits on.
          else if (failure != null)
            BgeInlineBanner(
              key: failure.key,
              tone: BgeBannerTone.error,
              title: failure.title,
              message: failure.message,
            ),
        ],
      ),
    );
  }

  /// The password: a field while a new one is entered, or with none saved,
  /// with Keep saved password and Remove when one is saved; otherwise a line
  /// saying one is saved, or will be removed, and the buttons that change
  /// that.
  Widget _password(
    BuildContext context,
    ServerSettingsLocalizations l10n,
    bool readOnly,
    String Function(Object) tooLong,
  ) {
    final buttonsEnabled = !widget.saving;
    final saved = widget.settings.smtpPasswordSet;
    // Offered beside Change and beside Keep saved password, one at a time:
    // the field's error asks to enter the password again or remove it.
    final remove = TextButton(
      key: MailSettingsForm.removePasswordKey,
      focusNode: _remove,
      onPressed: buttonsEnabled
          ? () => _editPassword(PasswordEdit.remove)
          : null,
      child: Text(l10n.mailPasswordRemove),
    );

    if (_passwordEdit == PasswordEdit.replace) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          BgeTextField(
            key: MailSettingsForm.passwordFieldKey,
            formControlName: 'password',
            label: l10n.mailPasswordLabel,
            isPassword: true,
            revealLabel: l10n.mailPasswordShow,
            obscureLabel: l10n.mailPasswordHide,
            autocorrect: false,
            enableSuggestions: false,
            readOnly: readOnly,
            validationMessages: {
              _passwordRequiredError: (_) => l10n.mailPasswordRequired,
              _emptyPasswordError: (_) => l10n.mailPasswordEmpty,
              _tooLongError: tooLong,
            },
          ),
          if (saved && widget.maySave)
            Focus(
              focusNode: _passwordActions,
              child: Wrap(
                spacing: BgeTokens.of(context).spaceSm,
                children: [
                  TextButton(
                    key: MailSettingsForm.keepSavedPasswordKey,
                    focusNode: _keepSaved,
                    onPressed: buttonsEnabled
                        ? () => _editPassword(PasswordEdit.keep)
                        : null,
                    child: Text(l10n.mailPasswordKeepSaved),
                  ),
                  remove,
                ],
              ),
            ),
        ],
      );
    }

    final theme = Theme.of(context);
    final removing = _passwordEdit == PasswordEdit.remove;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.mailPasswordLabel,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const BgeGap.xs(),
        // A live region: Remove and Keep change only this line, and the
        // button that takes focus doesn't say it.
        Semantics(
          container: true,
          liveRegion: true,
          child: Text(
            removing ? l10n.mailPasswordRemoving : l10n.mailPasswordSaved,
          ),
        ),
        if (widget.maySave)
          Focus(
            focusNode: _passwordActions,
            child: Wrap(
              spacing: BgeTokens.of(context).spaceSm,
              children: removing
                  ? [
                      TextButton(
                        key: MailSettingsForm.keepPasswordKey,
                        focusNode: _keep,
                        onPressed: buttonsEnabled
                            ? () => _editPassword(PasswordEdit.keep)
                            : null,
                        child: Text(l10n.mailPasswordKeep),
                      ),
                    ]
                  : [
                      TextButton(
                        key: MailSettingsForm.changePasswordKey,
                        focusNode: _change,
                        onPressed: buttonsEnabled
                            ? () => _editPassword(PasswordEdit.replace)
                            : null,
                        child: Text(l10n.mailPasswordChange),
                      ),
                      remove,
                    ],
            ),
          ),
      ],
    );
  }
}
