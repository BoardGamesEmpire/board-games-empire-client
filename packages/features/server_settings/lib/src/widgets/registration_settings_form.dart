import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/registration/link_lifetime.dart';
import 'package:server_settings/src/registration/registration_controls.dart';
import 'package:server_settings/src/widgets/settings_group_binding.dart';
import 'package:server_settings/src/widgets/settings_group_form.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The Registration and sign-in group of the server settings (#807, #894):
/// whether people may create an account, change their username and reset a
/// forgotten password, how long a reset link works, and when the server
/// links a sign-in provider to an account that already exists.
///
/// A [SettingsGroupForm], which says how it takes new values from the server
/// and what a role that may not save sees. The patch [binding] gets is what
/// changed, against the settings the form last took: each setting only when it
/// changed, and the linking policy not at all while it is one this app doesn't
/// know and no other was picked.
///
/// The reset switch says reset links go out by email, through the Mail
/// group's settings. Under the linking menu, what the chosen policy means.
/// Linking automatically shows it as a warning: whoever controls a user's
/// verified email at a provider can then sign in as that user.
class RegistrationSettingsForm extends StatelessWidget {
  const RegistrationSettingsForm({
    required this.binding,
    super.key,
  });

  static const Key signUpsSwitchKey = Key(
    'registration_settings_form.sign_ups',
  );
  static const Key usernameChangeSwitchKey = Key(
    'registration_settings_form.username_change',
  );
  static const Key passwordResetsSwitchKey = Key(
    'registration_settings_form.password_resets',
  );
  static const Key lifetimeFieldKey = Key(
    'registration_settings_form.lifetime',
  );
  static const Key policyFieldKey = Key('registration_settings_form.policy');
  static const Key warningKey = Key('registration_settings_form.warning');
  static const Key saveKey = Key('registration_settings_form.save');
  static const Key savedKey = Key('registration_settings_form.saved');
  static const Key failureKey = Key('registration_settings_form.failure');

  static const String _signUps = 'signUps';
  static const String _usernameChange = 'usernameChange';
  static const String _passwordResets = 'passwordResets';
  static const String _lifetime = 'lifetime';
  static const String _policy = 'policy';

  final SettingsGroupBinding binding;

  static FormGroup _buildForm(Map<String, Object?> values) => FormGroup({
    _signUps: FormControl<bool>(value: values[_signUps] as bool?),
    _usernameChange: FormControl<bool>(
      value: values[_usernameChange] as bool?,
    ),
    _passwordResets: FormControl<bool>(
      value: values[_passwordResets] as bool?,
    ),
    _lifetime: FormControl<String>(
      value: values[_lifetime] as String?,
      validators: [Validators.delegate(validResetLinkLifetime)],
    ),
    _policy: FormControl<ProviderLinkingPolicy>(
      value: values[_policy] as ProviderLinkingPolicy?,
    ),
  });

  static Map<String, Object?> _valuesOf(SystemSettings settings) => {
    _signUps: settings.allowUserRegistration,
    _usernameChange: settings.allowUsernameChange,
    _passwordResets: settings.allowPasswordResets,
    _lifetime: '${settings.passwordResetLinkLifetimeMinutes}',
    // A policy this app doesn't know shows as the menu's hint, and a save
    // leaves it alone unless another is picked.
    _policy: settings.providerLinkingPolicy == ProviderLinkingPolicy.unknown
        ? null
        : settings.providerLinkingPolicy,
  };

  static SystemSettingsPatch _patchOf(SystemSettings base, FormGroup form) {
    /// A switch's value, or null while it holds [stored].
    bool? changed(String name, {required bool stored}) {
      final value = form.control(name).value == true;
      return value == stored ? null : value;
    }

    final lifetime = resetLinkLifetime(form.control(_lifetime).value)!;
    final policy = form.control(_policy).value as ProviderLinkingPolicy?;
    return SystemSettingsPatch(
      allowUserRegistration: changed(
        _signUps,
        stored: base.allowUserRegistration,
      ),
      allowUsernameChange: changed(
        _usernameChange,
        stored: base.allowUsernameChange,
      ),
      allowPasswordResets: changed(
        _passwordResets,
        stored: base.allowPasswordResets,
      ),
      passwordResetLinkLifetimeMinutes:
          lifetime == base.passwordResetLinkLifetimeMinutes ? null : lifetime,
      providerLinkingPolicy:
          policy == null || policy == base.providerLinkingPolicy
          ? null
          : policy,
    );
  }

  static String _lastField(FormGroup _) => _policy;

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
        saveLabel: l10n.registrationSave,
        savingLabel: l10n.registrationSaving,
        savedKey: savedKey,
        savedMessage: l10n.registrationSaved,
        failureKey: failureKey,
        failureTitle: l10n.registrationNotSavedTitle,
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
          formControlName: _signUps,
          label: l10n.registrationSignUpsLabel,
          readOnly: readOnly,
          switchKey: signUpsSwitchKey,
        ),
        BgeSwitchField(
          formControlName: _usernameChange,
          label: l10n.registrationUsernameChangeLabel,
          readOnly: readOnly,
          switchKey: usernameChangeSwitchKey,
        ),
        BgeSwitchField(
          formControlName: _passwordResets,
          label: l10n.registrationPasswordResetsLabel,
          subtitle: l10n.registrationPasswordResetsSubtitle,
          readOnly: readOnly,
          switchKey: passwordResetsSwitchKey,
        ),
        const BgeGap.md(),
        ReactiveValueListenableBuilder<String>(
          formControlName: _lifetime,
          builder: (context, control, _) {
            final minutes = resetLinkLifetime(control.value);
            final min = describeLinkLifetime(
              SystemSettingsRemoteDataSource.minLinkLifetimeMinutes,
              l10n,
            );
            final max = describeLinkLifetime(
              SystemSettingsRemoteDataSource.maxLinkLifetimeMinutes,
              l10n,
            );
            return BgeTextField(
              key: lifetimeFieldKey,
              formControlName: _lifetime,
              label: l10n.registrationLinkLifetimeLabel,
              // The limits always show (#807), so the line doesn't come and
              // go as the value is typed.
              helper: minutes == null
                  ? l10n.registrationLinkLifetimeRange(min, max)
                  : l10n.registrationLinkLifetimeHelper(
                      describeLinkLifetime(minutes, l10n),
                      min,
                      max,
                    ),
              keyboardType: TextInputType.number,
              autocorrect: false,
              enableSuggestions: false,
              readOnly: readOnly,
              textInputAction: TextInputAction.done,
              onSubmitted: binding.maySave ? submit : null,
              validationMessages: {
                RegistrationErrors.lifetime: (_) =>
                    l10n.registrationLinkLifetimeInvalid(
                      SystemSettingsRemoteDataSource.minLinkLifetimeMinutes,
                      SystemSettingsRemoteDataSource.maxLinkLifetimeMinutes,
                      max,
                    ),
              },
            );
          },
        ),
        const BgeGap.md(),
        BgeDropdownField<ProviderLinkingPolicy>(
          key: policyFieldKey,
          formControlName: _policy,
          label: l10n.signInLinkingLabel,
          hint: l10n.signInLinkingUnknown,
          readOnly: readOnly,
          items: [
            BgeDropdownItem(
              value: ProviderLinkingPolicy.signedIn,
              label: l10n.signInLinkingSignedIn,
            ),
            BgeDropdownItem(
              value: ProviderLinkingPolicy.automaticWhenVerified,
              label: l10n.signInLinkingAutomatic,
            ),
          ],
        ),
        ReactiveValueListenableBuilder<ProviderLinkingPolicy>(
          formControlName: _policy,
          builder: (context, control, _) => switch (control.value) {
            ProviderLinkingPolicy.signedIn => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const BgeGap.sm(),
                // A live region: a pick changes only this line, and the
                // menu that takes focus back doesn't say it.
                Semantics(
                  container: true,
                  liveRegion: true,
                  child: Text(l10n.signInLinkingSignedInDescription),
                ),
              ],
            ),
            ProviderLinkingPolicy.automaticWhenVerified => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const BgeGap.sm(),
                BgeInlineBanner(
                  key: warningKey,
                  tone: BgeBannerTone.warning,
                  message: l10n.signInLinkingAutomaticWarning,
                  // It answers the user's own pick, beside the field they
                  // are on: heard, with nothing to scroll to.
                  reveal: false,
                ),
              ],
            ),
            // Nothing to describe: the menu's hint says the app doesn't
            // know the value.
            ProviderLinkingPolicy.unknown || null => const SizedBox.shrink(),
          },
        ),
      ],
    );
  }
}
