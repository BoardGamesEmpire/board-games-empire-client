import 'dart:async';

import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/bloc/server_settings_state.dart';
import 'package:server_settings/src/widgets/settings_group_actions.dart';
import 'package:server_settings/src/widgets/settings_seed.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The Sign-in group of the server settings (#807): when the server links a
/// sign-in provider to an account that already exists.
///
/// Owns its [FormGroup], as `MailSettingsForm` does, and hands [onSave] the
/// patch of what changed against [settings] as the server last sent it: the
/// linking policy alone, and nothing when it is unchanged or one this app
/// doesn't know. Every edit calls [onEdited], so the caller can retire an
/// outcome that describes the value being replaced.
///
/// Under the menu, what the chosen policy means. Linking automatically
/// shows it as a warning: whoever controls a user's verified email at a
/// provider can then sign in as that user.
///
/// ## New values from the server
///
/// [revision] moves whenever the server's settings were read or a save of
/// either group landed. The form takes the new value when its own save just
/// landed ([saved]), or when it holds no unsaved change, so another group's
/// save never discards the user's pick here. Taking it is not an edit.
///
/// ## Access
///
/// When [maySave] is false the menu is read-only and there is no Save. Save
/// with keyboard focus hands it to the menu, the field just before it. While
/// [saving] the menu is read-only; the save button's label and spinner say
/// why. While [otherGroupSaving] Save is disabled, with the reason as its
/// hint.
class SignInSettingsForm extends StatefulWidget {
  const SignInSettingsForm({
    required this.settings,
    required this.revision,
    required this.maySave,
    required this.saving,
    required this.otherGroupSaving,
    required this.onSave,
    required this.onEdited,
    this.failure,
    this.saved = false,
    super.key,
  });

  static const Key policyFieldKey = Key('sign_in_settings_form.policy');
  static const Key warningKey = Key('sign_in_settings_form.warning');
  static const Key saveKey = Key('sign_in_settings_form.save');
  static const Key savedKey = Key('sign_in_settings_form.saved');
  static const Key failureKey = Key('sign_in_settings_form.failure');

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

  @override
  State<SignInSettingsForm> createState() => _SignInSettingsFormState();
}

class _SignInSettingsFormState extends State<SignInSettingsForm> {
  static const String _policy = 'policy';

  /// The value the form last took from the server.
  late final SettingsSeed<ProviderLinkingPolicy?> _seed;

  late final FormControl<ProviderLinkingPolicy> _control;
  late final FormGroup _form;
  StreamSubscription<ProviderLinkingPolicy?>? _edits;

  /// Around Save, which goes when [SignInSettingsForm.maySave] falls; the
  /// handle on its focus. It can't take focus itself.
  final FocusNode _actions = FocusNode(
    debugLabel: 'sign-in settings actions',
    canRequestFocus: false,
  );

  /// A policy this app doesn't know shows as the menu's hint, and a save
  /// leaves it alone unless another is picked.
  static ProviderLinkingPolicy? _valueOf(SystemSettings settings) =>
      settings.providerLinkingPolicy == ProviderLinkingPolicy.unknown
      ? null
      : settings.providerLinkingPolicy;

  @override
  void initState() {
    super.initState();
    _seed = SettingsSeed(_valueOf(widget.settings));
    _control = FormControl<ProviderLinkingPolicy>(value: _seed.values);
    _form = FormGroup({_policy: _control});
    _edits = _control.valueChanges.listen(_onValueChanged);
  }

  void _onValueChanged(ProviderLinkingPolicy? value) {
    if (!mounted || _seed.isEcho(value)) return;
    widget.onEdited();
  }

  @override
  void didUpdateWidget(SignInSettingsForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (SettingsSeed.takes(
      revision: widget.revision,
      previousRevision: oldWidget.revision,
      saved: widget.saved,
      unsaved: _unsavedAgainst(oldWidget.settings),
    )) {
      _takeSettings();
    }
    if (oldWidget.maySave && !widget.maySave) {
      // A role that may not save sees what the server holds, not a pick it
      // can no longer send.
      _takeSettings();
      _handOnFocus();
    }
  }

  void _takeSettings() {
    _seed.take(_valueOf(widget.settings));
    _form.reset(value: {_policy: _seed.values});
  }

  @override
  void dispose() {
    unawaited(_edits?.cancel());
    _form.dispose();
    _actions.dispose();
    super.dispose();
  }

  /// Whether the menu holds a pick that [settings] don't.
  bool _unsavedAgainst(SystemSettings settings) {
    final value = _control.value;
    return value != null && value != settings.providerLinkingPolicy;
  }

  /// Hands keyboard focus from Save, which this build takes away with
  /// [SignInSettingsForm.maySave], to the menu, as `MailSettingsForm` hands
  /// its own to its last field.
  ///
  /// Runs while building the frame that takes Save away, while it still has
  /// focus.
  void _handOnFocus() {
    if (!_actions.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _control.focusController?.focusNode.requestFocus();
    });
  }

  void _submit() {
    if (!settingsGroupMaySave(
      context,
      maySave: widget.maySave,
      saving: widget.saving,
      otherGroupSaving: widget.otherGroupSaving,
    )) {
      return;
    }
    final value = _control.value;
    widget.onSave(
      value == null || value == widget.settings.providerLinkingPolicy
          ? const SystemSettingsPatch()
          : SystemSettingsPatch(providerLinkingPolicy: value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ServerSettingsLocalizations.of(context);
    final readOnly = widget.saving || !widget.maySave;

    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          BgeDropdownField<ProviderLinkingPolicy>(
            key: SignInSettingsForm.policyFieldKey,
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
                    key: SignInSettingsForm.warningKey,
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
          SettingsGroupActions(
            maySave: widget.maySave,
            saving: widget.saving,
            otherGroupSaving: widget.otherGroupSaving,
            saved: widget.saved,
            failure: widget.failure,
            focusNode: _actions,
            onSave: _submit,
            saveKey: SignInSettingsForm.saveKey,
            saveLabel: l10n.signInSave,
            savingLabel: l10n.signInSaving,
            savedKey: SignInSettingsForm.savedKey,
            savedMessage: l10n.signInSaved,
            failureKey: SignInSettingsForm.failureKey,
            failureTitle: l10n.signInNotSavedTitle,
          ),
        ],
      ),
    );
  }
}
